# TechStream self-healing lab.
#
# Every target runs from the repo root, where docker-compose.yml lives.
#   make help

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

APP_URL ?= http://localhost:8080
PROM_URL ?= http://localhost:9090
ALERTMANAGER_URL ?= http://localhost:9093
GRAFANA_URL ?= http://localhost:3000

WEBHOOK_URL_FILE := monitoring/alertmanager/webhook_url

# Chaos defaults, override on the command line:
#   make chaos-errors DURATION=180 RATE=0.5 RPS=25
DURATION ?= 120
RECOVERY ?= 240
RPS ?= 20
RATE ?= 0.4
CPUS ?= 4

.PHONY: help
help: ## Show this help
	@echo "TechStream self-healing lab"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables: DURATION=$(DURATION) RECOVERY=$(RECOVERY) RPS=$(RPS) RATE=$(RATE) CPUS=$(CPUS)"

# ------------------------------------------------------------------ stack

.PHONY: up
up: .env ## Build and start the stack, then wait for it to be ready
	docker compose up -d --build
	@echo "waiting for the app and Prometheus..."
	@until curl -sf $(APP_URL)/healthz >/dev/null 2>&1; do sleep 2; done
	@until curl -sf $(PROM_URL)/-/ready >/dev/null 2>&1; do sleep 2; done
	@echo
	@$(MAKE) --no-print-directory status

.PHONY: down
down: ## Stop the stack and remove its volumes
	docker compose --profile local-remediation down -v

.PHONY: restart-app
restart-app: ## Restart just the app, the same action remediation performs
	docker compose restart app

.PHONY: status
status: ## Show service status and Prometheus scrape target health
	@docker compose ps --format 'table {{.Service}}\t{{.Status}}'
	@echo
	@echo "scrape targets:"
	@curl -s '$(PROM_URL)/api/v1/targets?state=active' 2>/dev/null \
		| python3 -c "import json,sys; \
[print(f\"  {t['labels']['job']:16} {t['health']:8} {t.get('lastError','')}\") \
for t in sorted(json.load(sys.stdin)['data']['activeTargets'], key=lambda x: x['labels']['job'])]" \
		|| echo "  Prometheus not reachable"
	@echo
	@echo "  app          $(APP_URL)"
	@echo "  grafana      $(GRAFANA_URL)/d/techstream-golden-signals"
	@echo "  prometheus   $(PROM_URL)"
	@echo "  alertmanager $(ALERTMANAGER_URL)"

.PHONY: logs
logs: ## Follow logs for all services
	docker compose logs -f

.env: ## Create .env from the example if it does not exist
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "created .env from .env.example"; \
		echo "SET GF_SECURITY_ADMIN_PASSWORD AND REMEDIATION_WEBHOOK_TOKEN IN .env, THEN RE-RUN"; \
		exit 1; \
	fi

# ------------------------------------------------------------ remediation

.PHONY: configure
configure: ## Point Alertmanager at the remediation webhook. Usage: make configure URL='https://...?token=...'
ifndef URL
	@echo "error: URL is required." >&2
	@echo >&2
	@echo "  deployed:  make configure URL=\"\$$(terraform -chdir=infra/stack output -raw lambda_function_url)?token=\$$TOKEN\"" >&2
	@echo "  local:     make configure-local" >&2
	@exit 2
endif
	@mkdir -p $(dir $(WEBHOOK_URL_FILE))
	@printf '%s\n' '$(URL)' > $(WEBHOOK_URL_FILE)
	@echo "wrote $(WEBHOOK_URL_FILE) (gitignored, contains the token)"
	@docker compose kill -s SIGHUP alertmanager >/dev/null 2>&1 \
		|| docker compose restart alertmanager >/dev/null 2>&1 || true
	@echo "alertmanager reloaded"

.PHONY: configure-local
configure-local: ## Point Alertmanager at the local remediator stand-in
	@test -f .env || { echo "error: .env missing, run make up first" >&2; exit 1; }
	@TOKEN="$$(grep '^REMEDIATION_WEBHOOK_TOKEN=' .env | cut -d= -f2)"; \
	if [ -z "$$TOKEN" ]; then \
		echo "error: set REMEDIATION_WEBHOOK_TOKEN in .env first" >&2; \
		echo "       generate one with: openssl rand -hex 32" >&2; exit 1; \
	fi; \
	$(MAKE) --no-print-directory configure URL="http://remediator:8000/?token=$$TOKEN"

.PHONY: cloud-token
cloud-token: ## Write the Grafana Cloud remote_write token. Usage: make cloud-token TOKEN=glc_...
ifndef TOKEN
	@echo "error: TOKEN is required." >&2
	@echo "       Get it from the Grafana Cloud Portal: Access Policies," >&2
	@echo "       scope metrics:write, then Add token." >&2
	@echo "       Usage: make cloud-token TOKEN=glc_..." >&2
	@exit 2
endif
	@printf '%s' '$(TOKEN)' > monitoring/prometheus/grafana_cloud_token
	@chmod 600 monitoring/prometheus/grafana_cloud_token
	@echo "wrote monitoring/prometheus/grafana_cloud_token (gitignored)"
	@curl -sf -X POST $(PROM_URL)/-/reload >/dev/null 2>&1 \
		&& echo "prometheus reloaded" \
		|| docker compose restart prometheus >/dev/null 2>&1
	@echo "give it 30s, then check: make cloud-status"

.PHONY: cloud-status
cloud-status: ## Show whether remote_write to Grafana Cloud is succeeding
	@echo "remote_write health:"
	@for m in prometheus_remote_storage_samples_total \
	          prometheus_remote_storage_samples_failed_total \
	          prometheus_remote_storage_samples_pending \
	          prometheus_remote_storage_shards; do \
		printf '  %-52s ' "$$m"; \
		curl -s --get $(PROM_URL)/api/v1/query --data-urlencode "query=sum($$m)" 2>/dev/null \
			| python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'no data')" 2>/dev/null \
			|| echo "unavailable"; \
	done
	@echo
	@echo "series that WOULD ship (allowlist applied):"
	@curl -s --get $(PROM_URL)/api/v1/query --data-urlencode 'query=count(http_requests_total or http_request_duration_seconds_bucket or node_cpu_seconds_total or container_cpu_usage_seconds_total{name=~"techstream-.*"} or up)' 2>/dev/null \
		| python3 -c "import json,sys; r=json.load(sys.stdin)['data']['result']; print('  ', r[0]['value'][1] if r else 'n/a')"
	@echo
	@echo "recent remote_write errors (empty is good):"
	@docker compose logs prometheus --since 3m 2>&1 | grep -i 'remote_write\|remote storage' | tail -5 || echo "  none"

.PHONY: remediator-up
remediator-up: ## Start the LOCAL remediation stand-in. Mounts the Docker socket, never use on EC2.
	@echo "WARNING: this mounts the Docker socket, which is root equivalent on the host."
	@echo "         Local verification only. On EC2 the Lambda plus SSM path does this job."
	docker compose --profile local-remediation up -d --build remediator
	@$(MAKE) --no-print-directory configure-local

.PHONY: remediator-logs
remediator-logs: ## Follow the remediator log, where restarts are recorded
	docker compose logs -f remediator

.PHONY: alerts
alerts: ## Show alert rule states and anything currently firing
	@echo "rules:"
	@curl -s $(PROM_URL)/api/v1/rules 2>/dev/null \
		| python3 -c "import json,sys; \
[print(f\"  {r['name']:20} {r.get('state','?'):9} remediation={r['labels'].get('remediation')}\") \
for g in json.load(sys.stdin)['data']['groups'] for r in g['rules']]" \
		|| echo "  Prometheus not reachable"
	@echo
	@echo "firing in alertmanager:"
	@curl -s '$(ALERTMANAGER_URL)/api/v2/alerts?active=true' 2>/dev/null \
		| python3 -c "import json,sys; \
d=json.load(sys.stdin); \
print('\n'.join(f\"  {a['labels']['alertname']} ratio={a['annotations'].get('ratio')}\" for a in d) or '  none')" \
		|| echo "  Alertmanager not reachable"

# ------------------------------------------------------------------ chaos

.PHONY: traffic
traffic: ## Drive normal traffic with no fault injected. Usage: make traffic DURATION=60 RPS=20
	@echo "driving ~$(RPS) req/s for $(DURATION)s with no fault injected"
	@END=$$(( $$(date +%s) + $(DURATION) )); \
	while [ "$$(date +%s)" -lt "$$END" ]; do \
		for _ in $$(seq 1 $(RPS)); do curl -s -o /dev/null $(APP_URL)/work & done; \
		wait; sleep 1; \
	done; \
	echo "done"

.PHONY: chaos-errors
chaos-errors: ## Inject a 5xx incident. Usage: make chaos-errors DURATION=120 RATE=0.4 RPS=20
	./chaos/chaos.sh errors $(DURATION) --rate $(RATE) --rps $(RPS) --recovery $(RECOVERY) --url $(APP_URL)

.PHONY: chaos-cpu
chaos-cpu: ## Saturate CPU with stress-ng. Usage: make chaos-cpu DURATION=150 CPUS=4 RPS=30
	./chaos/chaos.sh cpu $(DURATION) --cpus $(CPUS) --rps $(RPS) --recovery $(RECOVERY) --url $(APP_URL)

.PHONY: rca
rca: ## Correlate the last incident and write rca/rca_report.{json,md}
	python3 rca/rca.py --prometheus $(PROM_URL)
	@echo
	@echo "read it with: less rca/rca_report.md"

.PHONY: loop
loop: ## Full demo: inject errors, let remediation fix it, then produce the RCA
	@echo "Leaving a 5 minute idle gap first, so the RCA gets a clean baseline."
	@echo "Without it the baseline overlaps the previous run and comparisons are unreliable."
	@sleep 300
	@$(MAKE) --no-print-directory chaos-errors
	@echo "waiting 90s so the whole query window is in the past"
	@sleep 90
	@$(MAKE) --no-print-directory rca

# -------------------------------------------------------------- terraform

.PHONY: tf-bootstrap
tf-bootstrap: ## One time: create the S3 remote state backend
	terraform -chdir=infra/bootstrap init
	terraform -chdir=infra/bootstrap apply

.PHONY: tf-plan
tf-plan: ## Plan the main stack
	terraform -chdir=infra/stack init
	terraform -chdir=infra/stack plan

.PHONY: tf-apply
tf-apply: ## Apply the main stack
	terraform -chdir=infra/stack init
	terraform -chdir=infra/stack apply

.PHONY: tf-output
tf-output: ## Show stack outputs, including the Lambda Function URL
	terraform -chdir=infra/stack output

.PHONY: tf-destroy
tf-destroy: ## Destroy the main stack. Bootstrap is destroyed separately and last.
	terraform -chdir=infra/stack destroy
	@echo
	@echo "The state bucket in infra/bootstrap still exists, and holds this state."
	@echo "It carries prevent_destroy. To remove it, delete that lifecycle block in"
	@echo "infra/bootstrap/main.tf first, then run:"
	@echo "  terraform -chdir=infra/bootstrap destroy"

# ------------------------------------------------------------------ checks

.PHONY: validate
validate: ## Validate all config: terraform, promtool, amtool, compose, python
	terraform fmt -recursive -check infra/
	terraform -chdir=infra/bootstrap validate
	terraform -chdir=infra/stack validate
	docker compose config --quiet && echo "compose config OK"
	docker compose exec -T prometheus promtool check config /etc/prometheus/prometheus.yml
	docker compose exec -T alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
	python3 -m py_compile app/app.py rca/rca.py remediator/app.py \
		infra/modules/remediation/lambda/handler.py && echo "python OK"
	bash -n chaos/chaos.sh && echo "chaos.sh OK"
	@find . -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true

.PHONY: routes
routes: ## Show which receiver each alertname routes to
	@for a in HighErrorRate AppDown HighLatencyP95 HostCpuSaturation; do \
		printf '  %-20s -> ' "$$a"; \
		docker compose exec -T alertmanager amtool config routes test \
			--config.file=/etc/alertmanager/alertmanager.yml alertname=$$a 2>/dev/null; \
	done
