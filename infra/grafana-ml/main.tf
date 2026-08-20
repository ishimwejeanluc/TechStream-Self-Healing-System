# Resolve the hosted Prometheus datasource UID by name, rather than pasting a
# UID that changes if the stack is recreated.
data "grafana_data_source" "prometheus" {
  name = var.prometheus_datasource_name
}

locals {
  # Reused from monitoring/grafana/dashboards/golden-signals.json and
  # monitoring/prometheus/rules/alerts.yml, with two deliberate differences on
  # the error ratio only. Both were forced by how Prophet trains.
  #
  # 1. "or vector(0)"
  #    The shared expression returns empty, not zero, when no 5xx series exists.
  #    Training on it failed with "No series to train" because there was nothing
  #    to read. Appending the fallback makes the series continuous.
  #
  # 2. "label_replace(...)"
  #    vector(0) produces a series with NO labels, which the trainer reported as
  #    "Ignoring series with only a single value: {}". Giving it a stable label
  #    set makes it an identifiable series rather than an anonymous one.
  #
  # A third problem is NOT solvable in the query: a perfectly flat line cannot be
  # forecast. With a healthy app the error ratio is constant 0, and Prophet
  # rejects it. The baseline therefore has to carry a small realistic error rate,
  # which is what `make ml-baseline` injects. See docs/grafana-ml-setup.md.
  error_ratio_expr = "label_replace((100 * sum(rate(http_requests_total{status=~\"5..\"}[1m])) / clamp_min(sum(rate(http_requests_total[1m])), 1)) or vector(0), \"service\", \"techstream-web\", \"\", \"\")"

  # Verbatim from the Total Request Rate panel. Traffic varies naturally, so this
  # trains without any special handling, and it is the signal most useful for
  # capacity forecasting.
  traffic_expr = "sum(rate(http_requests_total[1m]))"

  # Verbatim from the Request Latency panel, p95 series.
  latency_p95_expr = "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[1m])) by (le))"

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

  interval        = var.training_interval_seconds
  training_window = var.training_window_seconds

  query_params = {
    expr = local.error_ratio_expr
  }

  custom_labels = {
    project = var.project
    signal  = "errors"
    source  = "terraform"
  }
}

# Forecast on request rate.
#
# Added because the error ratio alone is a poor training target: a healthy app
# holds it at exactly 0, and a flat line cannot be forecast. Traffic varies on its
# own, so this job trains immediately and gives the ML path something meaningful
# to show regardless of whether errors are present.
#
# It is also the honest capacity-planning use case for forecasting, as opposed to
# anomaly detection.
resource "grafana_machine_learning_job" "traffic" {
  name            = "${var.project} request rate forecast"
  metric          = "${var.project}_request_rate"
  datasource_type = "prometheus"
  datasource_uid  = data.grafana_data_source.prometheus.uid

  interval        = var.training_interval_seconds
  training_window = var.training_window_seconds

  query_params = {
    expr = local.traffic_expr
  }

  custom_labels = {
    project = var.project
    signal  = "traffic"
    source  = "terraform"
  }
}

# Forecast on p95 latency. Also varies naturally, and degrades under CPU
# saturation, so an anomaly here corroborates the saturation story the RCA tells.
resource "grafana_machine_learning_job" "latency_p95" {
  name            = "${var.project} p95 latency forecast"
  metric          = "${var.project}_latency_p95"
  datasource_type = "prometheus"
  datasource_uid  = data.grafana_data_source.prometheus.uid

  interval        = var.training_interval_seconds
  training_window = var.training_window_seconds

  query_params = {
    expr = local.latency_p95_expr
  }

  custom_labels = {
    project = var.project
    signal  = "latency"
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
