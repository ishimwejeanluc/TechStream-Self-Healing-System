# Resolve the hosted Prometheus datasource UID by name, rather than pasting a
# UID that changes if the stack is recreated.
data "grafana_data_source" "prometheus" {
  name = var.prometheus_datasource_name
}

locals {
  # Reused verbatim from monitoring/grafana/dashboards/golden-signals.json and
  # monitoring/prometheus/rules/alerts.yml, with ONE deliberate difference,
  # explained below.
  #
  # The shared expression returns empty, not zero, when no 5xx series exists.
  # Measured on a healthy app:
  #
  #   without or vector(0)  ->  empty, no series at all
  #   with    or vector(0)  ->  0
  #
  # For the alert rule, empty is correct and the rule is left alone. For a
  # forecasting model it is fatal: you cannot train on a series that does not
  # exist most of the time, and the model would see a handful of disconnected
  # spikes rather than a continuous baseline of zero.
  #
  # This is the only place the project does not reuse the expression byte for
  # byte, and this comment is the reason why.
  error_ratio_expr = "(100 * sum(rate(http_requests_total{status=~\"5..\"}[1m])) / clamp_min(sum(rate(http_requests_total[1m])), 1)) or vector(0)"

  # Verbatim from the Container CPU panel. No change needed: remote_write only
  # ships techstream-* containers, so name!="" already means "ours".
  container_cpu_expr = "sum(rate(container_cpu_usage_seconds_total{name!=\"\"}[1m])) by (name)"
}

# Forecast on the error ratio. The model learns the normal shape of this signal
# and the anomaly score rises when reality departs from the forecast.
#
# This replaces the static 5 percent threshold as the DETECTION mechanism for
# insight purposes. It does not replace the alert rule, which still drives
# remediation. The value here is that a learned band adapts, where a fixed
# number cannot tell 5 percent at 3am from 5 percent at peak.
#
# No hyper_params are set. daily_seasonality and weekly_seasonality only mean
# something with days or weeks of history, and a lab that has been running for
# minutes has neither. Provider defaults apply. Add them once the stack has been
# collecting for a week or more.
resource "grafana_machine_learning_job" "error_ratio" {
  name            = "${var.project} error ratio forecast"
  metric          = "${var.project}_error_ratio"
  datasource_type = "prometheus"
  datasource_uid  = data.grafana_data_source.prometheus.uid

  query_params = {
    expr = local.error_ratio_expr
  }

  custom_labels = {
    project = var.project
    signal  = "errors"
    source  = "terraform"
  }
}

# DBSCAN outlier detection across per-container CPU. Clusters the containers by
# behaviour and flags any that stop resembling the others.
#
# This is the check a static threshold cannot express: "this container is
# behaving unlike its peers" has no fixed number attached to it.
resource "grafana_machine_learning_outlier_detector" "container_cpu" {
  name        = "${var.project} container CPU outliers"
  description = "Flags a container whose CPU stops resembling its peers. Grouped by the cAdvisor name label."

  metric          = "${var.project}_container_cpu_outliers"
  datasource_type = "prometheus"
  datasource_uid  = data.grafana_data_source.prometheus.uid

  query_params = {
    expr = local.container_cpu_expr
  }

  interval = var.outlier_interval_seconds

  algorithm {
    name        = "dbscan"
    sensitivity = var.dbscan_sensitivity

    config {
      epsilon = var.dbscan_epsilon
    }
  }
}

# Alerts on the ML results. Insight only, never remediation.
#
# Deliberately NOT routed to the remediation Lambda. The working trigger stays
# the Prometheus rule, so a mistrained model cannot start restarting the app.
resource "grafana_machine_learning_alert" "error_ratio_anomaly" {
  count = var.enable_ml_alerts ? 1 : 0

  job_id            = grafana_machine_learning_job.error_ratio.id
  title             = "${var.project} error ratio anomalous"
  anomaly_condition = "any"
  threshold         = var.anomaly_threshold
  window            = var.anomaly_window
  no_data_state     = "OK"

  labels = {
    project     = var.project
    remediation = "none"
    source      = "grafana-ml"
  }

  annotations = {
    summary = "The error ratio has departed from its forecast band."
    note    = "Insight only. Remediation is still triggered by the Prometheus HighErrorRate rule."
  }
}

resource "grafana_machine_learning_alert" "container_cpu_outlier" {
  count = var.enable_ml_alerts ? 1 : 0

  outlier_id = grafana_machine_learning_outlier_detector.container_cpu.id
  title      = "${var.project} container CPU outlier detected"
  window     = var.outlier_window

  labels = {
    project     = var.project
    remediation = "none"
    source      = "grafana-ml"
  }

  annotations = {
    summary = "A container's CPU stopped resembling its peers."
    note    = "Insight only. A restart does not fix genuine saturation, see the runbook."
  }
}
