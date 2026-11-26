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
  description = "Where tests run: 'job' (Serverless Job) or 'container' (Serverless Container via Queues)"
  type        = string
  default     = "container"
  validation {
    condition     = contains(["job", "container"], var.runner)
    error_message = "runner must be 'job' or 'container'."
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
