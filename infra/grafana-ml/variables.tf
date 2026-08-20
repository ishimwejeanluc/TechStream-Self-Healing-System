variable "grafana_url" {
  description = <<-EOT
    Grafana Cloud stack URL, for example https://largedingo3143.grafana.net
    Not the Prometheus query endpoint, the Grafana UI URL.
  EOT
  type        = string

  validation {
    condition     = can(regex("^https://", var.grafana_url))
    error_message = "grafana_url must start with https://"
  }
}

variable "grafana_auth" {
  description = <<-EOT
    Grafana service account token, created inside the Grafana instance under
    Administration, Users and access, Service accounts. Starts with glsa_.

    This is NOT the Cloud Portal access policy token used by remote_write, which
    starts with glc_ and cannot create ML jobs.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = startswith(var.grafana_auth, "glsa_")
    error_message = "Expected a service account token starting with glsa_. A glc_ token is a Cloud Portal token and cannot create ML jobs."
  }
}

variable "prometheus_datasource_name" {
  description = <<-EOT
    Name of the hosted Prometheus datasource inside the Grafana stack. Grafana
    Cloud creates this automatically and names it grafanacloud-<stack>-prom.
    Find it under Connections, Data sources.
  EOT
  type        = string
  default     = "grafanacloud-largedingo3143-prom"
}

variable "project" {
  description = "Name prefix, matching the rest of the project."
  type        = string
  default     = "techstream"
}

variable "enable_ml_alerts" {
  description = <<-EOT
    Create Grafana-managed alerts on the ML results.

    These are for insight only. They do NOT drive remediation. The Prometheus
    HighErrorRate rule plus Alertmanager plus Lambda remains the remediation
    trigger, unchanged. See docs/grafana-ml-setup.md for how to route an ML
    alert to the Lambda later if you want that.
  EOT
  type        = bool
  default     = true
}

variable "anomaly_threshold" {
  description = "Fire the forecast alert when the anomaly score exceeds this."
  type        = string
  default     = ">0.8"
}

variable "anomaly_window" {
  description = "Evaluation window for the forecast alert."
  type        = string
  default     = "15m"
}

variable "outlier_window" {
  description = "Evaluation window for the outlier alert."
  type        = string
  default     = "15m"
}

variable "outlier_interval_seconds" {
  description = "How often the outlier detector runs, in seconds."
  type        = number
  default     = 300
}

variable "dbscan_sensitivity" {
  description = "DBSCAN sensitivity, 0 to 1. Higher flags more points as outliers."
  type        = number
  default     = 0.5

  validation {
    condition     = var.dbscan_sensitivity > 0 && var.dbscan_sensitivity <= 1
    error_message = "dbscan_sensitivity must be between 0 and 1."
  }
}

variable "dbscan_epsilon" {
  description = "DBSCAN epsilon, the neighbourhood radius used for clustering."
  type        = number
  default     = 1.0
}

variable "training_interval_seconds" {
  description = <<-EOT
    Bucket size for training data, in seconds. The provider default is 300, which
    means a 5 minute resolution: an hour of history gives Prophet only 12 points.
    60 gives five times more points for the same elapsed time, which matters a lot
    while the lab has hours rather than weeks of data.
  EOT
  type        = number
  default     = 60
}

variable "training_window_seconds" {
  description = <<-EOT
    How far back training looks. The provider default is 7776000, 90 days, which
    is honest for a long-lived service and misleading for a lab that has been
    collecting for hours. 7 days is closer to reality here and costs less to query.
    Raise it once the stack has genuinely been running for weeks.
  EOT
  type        = number
  default     = 604800
}
