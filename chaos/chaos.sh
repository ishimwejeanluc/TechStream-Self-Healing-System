#!/usr/bin/env bash
#
# TechStream chaos injector.
#
# Injects a realistic incident, records the window to incident.json, and keeps
# traffic flowing afterwards so the self-healing loop can be observed end to end.
#
#   ./chaos/chaos.sh errors 120
#   ./chaos/chaos.sh cpu 90 --cpus 3
#   ./chaos/chaos.sh errors 120 --rate 0.4 --rps 15 --recovery 240
#
# Two behaviours are deliberate and worth understanding before you change them.
#
# 1. Errors mode does NOT reset the error rate when injection ends.
#    The injected rate lives in the app's memory, so only a container restart
#    clears it. If this script reset it, the error ratio would fall because
#    chaos stopped rather than because remediation worked, and the runbook
#    could not tell the two apart. Use --reset-on-exit when you only want a
#    traffic test with no remediation involved.
#
# 2. Traffic keeps flowing during a recovery phase after injection ends.
#    The alert expression is a rate over a 1 minute window. If traffic stopped
#    at the end of injection, that rate would fall to zero and the alert would
#    resolve for lack of traffic rather than lack of errors. The recovery phase
#    keeps load on the app so the ratio genuinely drops after the restart.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Defaults
MODE=""
DURATION=""
ERROR_RATE="0.4"
CPUS="2"
RPS="12"
# 240s, sized from the real loop timing. From the moment the ratio crosses 5
# percent: the rule waits 1m before firing, Alertmanager and the Lambda add a
# few seconds, SSM delivery and the container restart take another 10 to 30s,
# then the 1m rate window has to drain before the ratio reads below threshold,
# and Alertmanager sends the resolved notification after that. Measured at about
# 210s end to end, so a shorter recovery phase risks traffic stopping mid loop.
# If that happens the rate expression returns no data and the alert resolves
# because traffic vanished rather than because the app recovered.
RECOVERY="240"
APP_URL="${APP_URL:-http://localhost:8080}"
OUT_FILE="${REPO_ROOT}/chaos/incident.json"
RESET_ON_EXIT="false"

usage() {
  cat <<'EOF'
Usage: chaos.sh <mode> <duration_seconds> [options]

Modes:
  errors    Set the app error rate and drive steady traffic, pushing the error
            ratio above the 5 percent alert threshold.
  cpu       Saturate CPU cores with stress-ng while keeping light traffic
            flowing, so the latency effect is measurable.

Options:
  --rate <0..1>       Error rate for errors mode. Default 0.4
  --cpus <n>          Cores to saturate in cpu mode. Default 2
  --rps <n>           Requests per second to drive. Default 12
  --recovery <sec>    Seconds to keep traffic flowing after injection ends,
                      so remediation and alert resolution are observable.
                      Default 240. Use 0 to skip.
                      Do not shorten this below about 180 for a full loop run.
                      If traffic stops before the alert resolves, the rate
                      expression returns no data and the alert resolves because
                      traffic vanished, not because the app recovered.
  --url <url>         App base URL. Default http://localhost:8080
                      Can also be set with the APP_URL environment variable.
  --out <path>        Incident file to write. Default chaos/incident.json
  --reset-on-exit     Clear the injected error rate when finishing. Off by
                      default, because leaving it set is what proves the
                      automated restart is the thing that fixed the app.
  -h, --help          This message

Examples:
  ./chaos/chaos.sh errors 120
  ./chaos/chaos.sh errors 120 --rate 0.5 --rps 20 --recovery 300
  ./chaos/chaos.sh cpu 90 --cpus 3
  ./chaos/chaos.sh errors 60 --reset-on-exit      # traffic test, no remediation
EOF
}

# ---------------------------------------------------------------- arg parsing

if [ $# -lt 1 ]; then
  usage >&2
  exit 2
fi

case "${1}" in
  -h|--help) usage; exit 0 ;;
esac

MODE="${1}"
shift

if [ "${MODE}" != "errors" ] && [ "${MODE}" != "cpu" ]; then
  echo "error: mode must be 'errors' or 'cpu', got '${MODE}'" >&2
  usage >&2
  exit 2
fi

if [ $# -lt 1 ]; then
  echo "error: duration in seconds is required" >&2
  usage >&2
  exit 2
fi

DURATION="${1}"
shift

if ! printf '%s' "${DURATION}" | grep -Eq '^[0-9]+$' || [ "${DURATION}" -lt 1 ]; then
  echo "error: duration must be a positive integer number of seconds" >&2
  exit 2
fi

while [ $# -gt 0 ]; do
  case "${1}" in
    --rate)           ERROR_RATE="${2:?--rate needs a value}"; shift 2 ;;
    --cpus)           CPUS="${2:?--cpus needs a value}"; shift 2 ;;
    --rps)            RPS="${2:?--rps needs a value}"; shift 2 ;;
    --recovery)       RECOVERY="${2:?--recovery needs a value}"; shift 2 ;;
    --url)            APP_URL="${2:?--url needs a value}"; shift 2 ;;
    --out)            OUT_FILE="${2:?--out needs a value}"; shift 2 ;;
    --reset-on-exit)  RESET_ON_EXIT="true"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "error: unknown option '${1}'" >&2; usage >&2; exit 2 ;;
  esac
done

# Indirect expansion and tr, not ${n,,}, because macOS ships bash 3.2 where the
# lowercase expansion is a syntax error. This script has to run on both the Mac
# and the Ubuntu instance.
for n in RPS CPUS RECOVERY; do
  v="$(eval printf '%s' "\"\${${n}}\"")"
  if ! printf '%s' "${v}" | grep -Eq '^[0-9]+$'; then
    flag="$(printf '%s' "${n}" | tr '[:upper:]' '[:lower:]')"
    echo "error: --${flag} must be a non-negative integer, got '${v}'" >&2
    exit 2
  fi
done

command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }

# ------------------------------------------------------------------- helpers

iso() { date -u -r "${1}" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@${1}" +"%Y-%m-%dT%H:%M:%SZ"; }

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# Reads app_start_time_seconds from /metrics. Comparing this before and after
# the run is direct evidence of whether the container was restarted, which is
# exactly what the remediation Lambda is supposed to cause.
app_start_time() {
  curl -s --max-time 5 "${APP_URL}/metrics" 2>/dev/null \
    | awk '/^app_start_time_seconds /{print $2; exit}' || true
}

STATUS_LOG="$(mktemp -t techstream-chaos)"
APP_START_LOG="$(mktemp -t techstream-appstart)"

# Sampled repeatedly during the run, not just at the start and end. A restart
# that happens near the end of the run, or while the app is still coming back
# up, is invisible to a two point comparison: the final sample can race the
# restart and read the old process. Counting distinct values across the whole
# run catches every restart regardless of when it lands.
sample_app_start() {
  local v
  v="$(app_start_time)"
  if [ -n "${v}" ]; then
    printf '%s\n' "${v}" >>"${APP_START_LOG}"
  fi
}

one_request() {
  local path="/"
  [ $(( RANDOM % 2 )) -eq 0 ] || path="/work"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${APP_URL}${path}" 2>/dev/null || echo 000)"
  printf '%s\n' "${code}" >>"${STATUS_LOG}"
}

# Drives roughly ${2} requests per second for ${1} seconds. Each batch is fired
# concurrently then paced to about one second, so the real rate is reported at
# the end rather than assumed.
drive_traffic() {
  local seconds="${1}" rps="${2}" label="${3}"
  local deadline=$(( $(date +%s) + seconds ))
  local batch_start
  local batch=0

  while [ "$(date +%s)" -lt "${deadline}" ]; do
    batch_start="$(date +%s)"
    local i=0
    while [ "${i}" -lt "${rps}" ]; do
      one_request &
      i=$(( i + 1 ))
    done
    wait

    # Check for a restart every fifth batch, roughly every 5 seconds. /metrics
    # is excluded from the app's own request counters, so this does not pollute
    # the error ratio.
    batch=$(( batch + 1 ))
    if [ $(( batch % 5 )) -eq 0 ]; then
      sample_app_start
    fi

    if [ "$(( $(date +%s) - batch_start ))" -lt 1 ]; then
      sleep 1
    fi
  done
  log "${label} phase finished"
}

count_status() {
  local pattern="${1}"
  local n
  # grep -c prints 0 AND exits 1 when nothing matches, so "|| echo 0" would
  # emit a second zero and produce "0\n0", which is invalid JSON. Assigning
  # first and only then handling the exit status keeps it to a single value.
  n="$(grep -cE "${pattern}" "${STATUS_LOG}" 2>/dev/null)" || n=0
  printf '%s' "${n:-0}"
}

# ----------------------------------------------------------------- preflight

if ! curl -sf --max-time 5 "${APP_URL}/healthz" >/dev/null 2>&1; then
  echo "error: the app is not reachable at ${APP_URL}" >&2
  echo "       start the stack first: docker compose up -d" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUT_FILE}")"

START_EPOCH="$(date +%s)"
START_ISO="$(iso "${START_EPOCH}")"
APP_START_BEFORE="$(app_start_time)"

INJECT_END_EPOCH=""
END_EPOCH=""

# ------------------------------------------------------- incident.json writer

write_incident() {
  local inject_end="${INJECT_END_EPOCH:-$(date +%s)}"
  local end="${END_EPOCH:-$(date +%s)}"

  # One last sample, then count distinct process start times seen across the
  # whole run. Each distinct value after the first is one restart.
  sample_app_start
  local distinct restart_count app_start_last
  # Same grep -c trap as count_status. Assign first, then handle the exit code.
  distinct="$(sort -u "${APP_START_LOG}" 2>/dev/null | grep -c .)" || distinct=0
  distinct="$(printf '%s' "${distinct:-0}" | tr -d ' \n')"
  app_start_last="$(tail -n 1 "${APP_START_LOG}" 2>/dev/null || true)"

  if [ "${distinct}" -gt 0 ]; then
    restart_count=$(( distinct - 1 ))
  else
    restart_count=0
  fi

  local restarted="false"
  [ "${restart_count}" -gt 0 ] && restarted="true"

  local total ok errs
  total="$(wc -l <"${STATUS_LOG}" | tr -d ' ')"
  ok="$(count_status '^2[0-9][0-9]$')"
  errs="$(count_status '^5[0-9][0-9]$')"

  local elapsed=$(( end - START_EPOCH ))
  [ "${elapsed}" -gt 0 ] || elapsed=1
  local actual_rps=$(( total / elapsed ))

  # The query window is padded either side of the incident. The RCA needs a
  # quiet baseline before injection to know what normal looks like, and time
  # after the end to see recovery.
  local q_start=$(( START_EPOCH - 300 ))
  local q_end=$(( end + 60 ))

  local rate_field="null"
  local cpus_field="null"
  if [ "${MODE}" = "errors" ]; then
    rate_field="${ERROR_RATE}"
  else
    cpus_field="${CPUS}"
  fi

  # Written to a temp file then moved into place. A direct redirect truncates
  # the target immediately, so any failure part way through would destroy the
  # previous incident record and leave invalid JSON for the RCA to choke on.
  local tmp="${OUT_FILE}.tmp.$$"

  cat >"${tmp}" <<EOF
{
  "mode": "${MODE}",
  "target": "${APP_URL}",
  "note": "Lab-generated load from chaos.sh. These are simulated requests, not real user traffic.",
  "parameters": {
    "error_rate": ${rate_field},
    "cpus": ${cpus_field},
    "requested_rps": ${RPS},
    "injection_seconds": ${DURATION},
    "recovery_seconds": ${RECOVERY},
    "reset_on_exit": ${RESET_ON_EXIT}
  },
  "started_at": "$(iso "${START_EPOCH}")",
  "started_epoch": ${START_EPOCH},
  "injection_ended_at": "$(iso "${inject_end}")",
  "injection_ended_epoch": ${inject_end},
  "ended_at": "$(iso "${end}")",
  "ended_epoch": ${end},
  "duration_seconds": ${elapsed},
  "windows": {
    "baseline": { "start_epoch": ${q_start}, "end_epoch": ${START_EPOCH} },
    "injection": { "start_epoch": ${START_EPOCH}, "end_epoch": ${inject_end} },
    "recovery": { "start_epoch": ${inject_end}, "end_epoch": ${end} },
    "query": { "start_epoch": ${q_start}, "end_epoch": ${q_end} }
  },
  "requests": {
    "sent": ${total},
    "http_2xx": ${ok},
    "http_5xx": ${errs},
    "observed_rps": ${actual_rps}
  },
  "app_start_time_seconds_first": ${APP_START_BEFORE:-null},
  "app_start_time_seconds_last": ${app_start_last:-null},
  "distinct_app_processes_seen": ${distinct},
  "app_restart_count": ${restart_count},
  "app_restarted_during_run": ${restarted}
}
EOF

  mv -f "${tmp}" "${OUT_FILE}"
  log "incident window written to ${OUT_FILE}"
}

cleanup() {
  local rc=$?
  if [ "${RESET_ON_EXIT}" = "true" ] && [ "${MODE}" = "errors" ]; then
    curl -s -X POST "${APP_URL}/chaos/errors?rate=0" >/dev/null 2>&1 || true
    log "error rate reset to 0 because --reset-on-exit was given"
  fi
  write_incident
  rm -f "${STATUS_LOG}" "${APP_START_LOG}" "${OUT_FILE}.tmp.$$"
  exit "${rc}"
}
# Writes incident.json even on Ctrl-C, so an aborted run still leaves the RCA
# something to read.
trap cleanup EXIT INT TERM

# ----------------------------------------------------------------------- run

echo
echo "======================================================================"
echo " TechStream chaos run"
echo "======================================================================"
printf ' mode                %s\n' "${MODE}"
printf ' target              %s\n' "${APP_URL}"
printf ' injection           %ss\n' "${DURATION}"
printf ' recovery            %ss\n' "${RECOVERY}"
printf ' traffic             ~%s req/s\n' "${RPS}"
if [ "${MODE}" = "errors" ]; then
  printf ' error rate          %s\n' "${ERROR_RATE}"
else
  printf ' cores to saturate   %s\n' "${CPUS}"
fi
printf ' INCIDENT START      %s\n' "${START_ISO}"
echo "======================================================================"
echo

if [ "${MODE}" = "errors" ]; then
  log "setting error rate to ${ERROR_RATE}"
  curl -s -X POST "${APP_URL}/chaos/errors?rate=${ERROR_RATE}" >/dev/null
  log "driving traffic for ${DURATION}s"
  drive_traffic "${DURATION}" "${RPS}" "injection"
else
  log "starting stress-ng on ${CPUS} core(s) for ${DURATION}s"
  curl -s -X POST "${APP_URL}/chaos/cpu?seconds=${DURATION}&cpus=${CPUS}" >/dev/null
  log "keeping light traffic flowing for ${DURATION}s so latency is measurable"
  drive_traffic "${DURATION}" "${RPS}" "injection"
fi

INJECT_END_EPOCH="$(date +%s)"
log "injection ended at $(iso "${INJECT_END_EPOCH}")"

if [ "${RECOVERY}" -gt 0 ]; then
  echo
  if [ "${MODE}" = "errors" ]; then
    log "recovery phase: ${RECOVERY}s of traffic with the error rate STILL SET."
    log "only a container restart clears it, so this is where remediation shows up."
  else
    log "recovery phase: ${RECOVERY}s of traffic while CPU load drains."
  fi
  drive_traffic "${RECOVERY}" "${RPS}" "recovery"
fi

END_EPOCH="$(date +%s)"

echo
echo "======================================================================"
printf ' INCIDENT END        %s\n' "$(iso "${END_EPOCH}")"
printf ' duration            %ss\n' "$(( END_EPOCH - START_EPOCH ))"
printf ' requests sent       %s\n' "$(wc -l <"${STATUS_LOG}" | tr -d ' ')"
printf ' 2xx / 5xx           %s / %s\n' "$(count_status '^2[0-9][0-9]$')" "$(count_status '^5[0-9][0-9]$')"
echo "======================================================================"
echo
echo "Next:"
echo "  docker compose logs app | tail          # see the restart, if one happened"
echo "  python3 rca/rca.py                      # correlate the incident"
echo
