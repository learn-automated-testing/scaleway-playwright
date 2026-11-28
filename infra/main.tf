# Playwright E2E on Scaleway - everything in one dedicated project.
#
#   GitHub App webhook -> controller (Function) -> Serverless Job          (runner = "job")
#                                               -> Queue -> Container        (runner = "container")
#                                               -> Queue -> KEDA -> k8s Job  (runner = "keda", keda.tf)
#   Results -> GitHub check run, HTML report -> Object Storage
#
# 'tofu apply'   creates everything, builds/pushes the image, points the GitHub App webhook here.
# 'tofu destroy' removes everything (the project is deleted with all its resources).

locals {
  repo_root = abspath("${path.module}/..")
  suffix    = random_id.suffix.hex

  # The image only contains Node, Chromium, npm packages and scripts/ - tests are fetched per commit.
  # Its tag is a hash of exactly those files, so it is rebuilt only when they change.
  image_files = concat(
    ["${local.repo_root}/Dockerfile", "${local.repo_root}/package.json", "${local.repo_root}/package-lock.json"],
    ["${local.repo_root}/controller/sqs.js", "${local.repo_root}/controller/package.json"],
    [for f in sort(fileset("${local.repo_root}/scripts", "*")) : "${local.repo_root}/scripts/${f}"],
  )
  image_tag = "deps-${substr(sha256(join("", [for f in local.image_files : filesha256(f)])), 0, 12)}"
  image     = "${scaleway_registry_namespace.this.endpoint}/playwright-e2e:${local.image_tag}"

  sqs_endpoint = "https://sqs.mnq.${var.region}.scaleway.com"
}

resource "random_id" "suffix" {
  byte_length = 3
}

# ======================================================================
# Project
# ======================================================================
resource "scaleway_account_project" "this" {
  name                  = var.project_name
  description           = "Playwright E2E tests triggered by a GitHub App (managed by OpenTofu)"
  delete_with_resources = true # safety net: destroy also removes anything left inside
}

# ======================================================================
# IAM: two least-privilege API keys, scoped to this project only
# ======================================================================
resource "scaleway_iam_application" "reports" {
  name        = "${var.project_name}-reports"
  description = "Uploads Playwright HTML reports to Object Storage"
}

resource "scaleway_iam_policy" "reports" {
  name           = "${var.project_name}-reports"
  application_id = scaleway_iam_application.reports.id
  rule {
    project_ids          = [scaleway_account_project.this.id]
    permission_set_names = ["ObjectStorageFullAccess"]
  }
}

resource "scaleway_iam_api_key" "reports" {
  application_id     = scaleway_iam_application.reports.id
  default_project_id = scaleway_account_project.this.id # S3 resolves buckets in this project
  description        = "Playwright report uploads"

  lifecycle {
    ignore_changes = [expires_at] # Scaleway sets a default 1-year expiry
  }
}

resource "scaleway_iam_application" "controller" {
  name        = "${var.project_name}-controller"
  description = "Webhook controller: starts Serverless Job runs"
}

resource "scaleway_iam_policy" "controller" {
  name           = "${var.project_name}-controller"
  application_id = scaleway_iam_application.controller.id
  rule {
    project_ids          = [scaleway_account_project.this.id]
    permission_set_names = ["ServerlessJobsFullAccess"]
  }
}

resource "scaleway_iam_api_key" "controller" {
  application_id     = scaleway_iam_application.controller.id
  default_project_id = scaleway_account_project.this.id
  description        = "Playwright controller"

  lifecycle {
    ignore_changes = [expires_at]
  }
}

# ======================================================================
# Secrets generated here (demo: they live in the local state file)
# ======================================================================
resource "random_password" "webhook_secret" {
  length  = 48
  special = false
}

resource "random_password" "run_secret" {
  length  = 48
  special = false
}

# ======================================================================
# Report bucket: private bucket, reports public-read under random paths, auto-expire
# ======================================================================
resource "scaleway_object_bucket" "reports" {
  name          = "pw-reports-${local.suffix}"
  project_id    = scaleway_account_project.this.id
  force_destroy = true # destroy also deletes the reports inside

  lifecycle_rule {
    id                                     = "expire-playwright-reports"
    enabled                                = true
    prefix                                 = "reports/"
    abort_incomplete_multipart_upload_days = 1
    expiration {
      days = var.report_retention_days
    }
  }
}

# ======================================================================
# Registry + image (built and pushed from this machine with docker)
# ======================================================================
resource "scaleway_registry_namespace" "this" {
  name       = "pw-e2e-${local.suffix}"
  project_id = scaleway_account_project.this.id
  is_public  = false
}

resource "terraform_data" "image" {
  input            = local.image
  triggers_replace = [local.image]

  provisioner "local-exec" {
    working_dir = local.repo_root
    command     = <<-EOT
      set -e
      scw registry login region=${var.region} >/dev/null
      docker build --platform linux/amd64 -t ${local.image} .
      docker push ${local.image}
    EOT
  }
}

# ======================================================================
# Runner 1: Serverless Job
# ======================================================================
resource "scaleway_job_definition" "e2e" {
  name                   = "playwright-e2e"
  project_id             = scaleway_account_project.this.id
  image_uri              = terraform_data.image.output
  cpu_limit              = var.cpu
  memory_limit           = var.memory_mb
  local_storage_capacity = 5000
  timeout                = "20m"
  description            = "Playwright E2E tests (started by the webhook controller)"
}

# ======================================================================
# Runner 2: Serverless Container fed by Scaleway Queues
# ======================================================================
resource "scaleway_mnq_sqs" "this" {
  project_id = scaleway_account_project.this.id
}

resource "scaleway_mnq_sqs_credentials" "send" {
  project_id = scaleway_mnq_sqs.this.project_id
  name       = "controller-send"
  permissions {
    can_publish = true
    can_receive = false
    can_manage  = true # needed to create/delete the queue
  }
}

resource "scaleway_mnq_sqs_credentials" "receive" {
  project_id = scaleway_mnq_sqs.this.project_id
  name       = "trigger-receive"
  permissions {
    can_publish = false
    can_receive = true
    can_manage  = false
  }
}

resource "scaleway_mnq_sqs_queue" "runs" {
  project_id                 = scaleway_mnq_sqs.this.project_id
  name                       = "playwright-runs"
  sqs_endpoint               = scaleway_mnq_sqs.this.endpoint
  access_key                 = scaleway_mnq_sqs_credentials.send.access_key
  secret_key                 = scaleway_mnq_sqs_credentials.send.secret_key
  visibility_timeout_seconds = 900  # a run may take up to the container timeout
  message_max_age            = 3600 # runs older than an hour are pointless
}

resource "scaleway_container_namespace" "this" {
  name       = "playwright-runner"
  project_id = scaleway_account_project.this.id
}

resource "scaleway_container" "runner" {
  name         = "playwright-runner"
  namespace_id = scaleway_container_namespace.this.id
  image        = terraform_data.image.output
  cpu_limit    = var.cpu
  memory_limit = var.memory_mb
  timeout      = 900
  privacy      = "private"
  min_scale    = 0
  max_scale    = 3
  port         = 8080

  scaling_option {
    concurrent_requests_threshold = 1 # one test run per instance
  }

  environment_variables = {
    RUNNER_MODE   = "server"
    REPORT_BUCKET = scaleway_object_bucket.reports.name
    REPORT_REGION = var.region
  }
  secret_environment_variables = {
    REPORT_ACCESS_KEY = scaleway_iam_api_key.reports.access_key
    REPORT_SECRET_KEY = scaleway_iam_api_key.reports.secret_key
    RUN_SECRET        = random_password.run_secret.result
  }
}

resource "scaleway_container_trigger" "runs" {
  name         = "playwright-runs"
  container_id = scaleway_container.runner.id

  destination_config {
    http_path   = "/run"
    http_method = "post"
  }

  sqs {
    endpoint   = scaleway_mnq_sqs.this.endpoint
    queue_url  = scaleway_mnq_sqs_queue.runs.url
    access_key = scaleway_mnq_sqs_credentials.receive.access_key
    secret_key = scaleway_mnq_sqs_credentials.receive.secret_key
  }
}

# ======================================================================
# Controller: Serverless Function receiving the GitHub App webhook
# ======================================================================
data "archive_file" "controller" {
  type        = "zip"
  source_dir  = "${local.repo_root}/controller"
  output_path = "${path.module}/.build/controller.zip"
}

resource "scaleway_function_namespace" "this" {
  name       = "playwright-ci"
  project_id = scaleway_account_project.this.id
}

resource "scaleway_function" "webhook" {
  name         = "github-webhook"
  namespace_id = scaleway_function_namespace.this.id
  runtime      = "node22"
  handler      = "handler.handle"
  privacy      = "public" # GitHub must reach it; every request is HMAC-verified
  min_scale    = 0
  memory_limit = 256
  timeout      = 30
  zip_file     = data.archive_file.controller.output_path
  zip_hash     = data.archive_file.controller.output_sha256
  deploy       = true

  lifecycle {
    precondition {
      condition     = var.runner != "keda" || var.enable_keda
      error_message = "runner = \"keda\" needs enable_keda = true."
    }
  }

  environment_variables = {
    GITHUB_APP_ID     = var.github_app_id
    ALLOWED_REPOS     = join(",", var.allowed_repos)
    BRANCHES          = join(",", var.branches)
    BASE_URL          = var.base_url
    RUNNER            = var.runner
    JOBS_REGION       = var.region
    JOB_DEFINITION_ID = element(split("/", scaleway_job_definition.e2e.id), 1) # strip "fr-par/"
    REPORT_BUCKET     = scaleway_object_bucket.reports.name
    SQS_QUEUE_URL     = var.runner == "keda" ? one(scaleway_mnq_sqs_queue.keda[*].url) : scaleway_mnq_sqs_queue.runs.url
  }
  secret_environment_variables = {
    GITHUB_APP_PRIVATE_KEY_B64 = base64encode(file(var.github_app_private_key_path))
    GITHUB_WEBHOOK_SECRET      = random_password.webhook_secret.result
    JOBS_SECRET_KEY            = scaleway_iam_api_key.controller.secret_key
    REPORT_ACCESS_KEY          = scaleway_iam_api_key.reports.access_key
    REPORT_SECRET_KEY          = scaleway_iam_api_key.reports.secret_key
    SQS_ACCESS_KEY             = scaleway_mnq_sqs_credentials.send.access_key
    SQS_SECRET_KEY             = scaleway_mnq_sqs_credentials.send.secret_key
    RUN_SECRET                 = random_password.run_secret.result
  }
}

# Marks job runs that died without reporting (timeout, OOM) as failed in GitHub.
resource "scaleway_function_cron" "sweep" {
  name        = "sweep"
  function_id = scaleway_function.webhook.id
  schedule    = "*/15 * * * *"
  args        = jsonencode({ action = "sweep" })
}

# ======================================================================
# Point the GitHub App webhook at this controller (URL + secret)
# ======================================================================
resource "terraform_data" "github_webhook" {
  triggers_replace = [scaleway_function.webhook.domain_name, random_password.webhook_secret.result]

  provisioner "local-exec" {
    command = "node ${path.module}/scripts/github-app-webhook.mjs"
    environment = {
      GITHUB_APP_ID               = var.github_app_id
      GITHUB_APP_PRIVATE_KEY_PATH = var.github_app_private_key_path
      WEBHOOK_URL                 = "https://${scaleway_function.webhook.domain_name}"
      WEBHOOK_SECRET              = random_password.webhook_secret.result
    }
  }
}
