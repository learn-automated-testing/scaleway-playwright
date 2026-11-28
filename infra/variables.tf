variable "region" {
  description = "Scaleway region"
  type        = string
  default     = "fr-par"
}

variable "project_name" {
  description = "Dedicated Scaleway project; 'tofu destroy' removes it with everything inside"
  type        = string
  default     = "playwright-e2e"
}

# ---------- GitHub App (create it once by hand, see README) ----------
variable "github_app_id" {
  description = "GitHub App ID (App settings -> About)"
  type        = string
}

variable "github_app_private_key_path" {
  description = "Path to the GitHub App private key (.pem)"
  type        = string
}

variable "allowed_repos" {
  description = "Repos (owner/name) allowed to start runs; everything else is refused"
  type        = list(string)
}

variable "branches" {
  description = "Branches that trigger tests; empty = all branches"
  type        = list(string)
  default     = []
}

# ---------- Tests ----------
variable "base_url" {
  description = "Site under test"
  type        = string
  default     = "https://www.practiceautomatedtesting.com"
}

variable "runner" {
  description = "Where tests run: 'job' (Serverless Job), 'container' (Serverless Container via Queues) or 'keda' (Kapsule + KEDA, needs enable_keda)"
  type        = string
  default     = "container"
  validation {
    condition     = contains(["job", "container", "keda"], var.runner)
    error_message = "runner must be 'job', 'container' or 'keda'."
  }
}

variable "cpu" {
  description = "mvCPU for the job and the container (4000 = 4 vCPU, one Playwright worker per vCPU)"
  type        = number
  default     = 4000
}

variable "memory_mb" {
  description = "Memory in MiB for the job and the container"
  type        = number
  default     = 8192
}

variable "report_retention_days" {
  description = "HTML reports in Object Storage are deleted after this many days"
  type        = number
  default     = 14
}

# ---------- Kapsule + KEDA (comparison runner, keda.tf) ----------
# Costs money while it exists, even idle: the system node runs 24/7 (~EUR 15/month for DEV1-M).
# Runner nodes scale from 0 and are only billed while tests run.
variable "enable_keda" {
  description = "Create a Kapsule cluster with KEDA as a third runner"
  type        = bool
  default     = false
}

variable "keda_system_node_type" {
  description = "Always-on node for KEDA and system pods"
  type        = string
  default     = "DEV1-M" # 3 vCPU / 4 GB, ~EUR 0.020/h
}

variable "keda_runner_node_type" {
  description = "Node type for test runs (scaled from 0 by the cluster autoscaler)"
  type        = string
  default     = "PLAY2-MICRO" # 4 vCPU / 8 GB, ~EUR 0.055/h - same size as the job/container
}

variable "keda_runner_max_nodes" {
  description = "Maximum runner nodes (one test run per node)"
  type        = number
  default     = 2
}
