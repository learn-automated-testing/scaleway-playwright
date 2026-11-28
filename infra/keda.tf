# Runner 3 (comparison): Kapsule cluster + KEDA, only when enable_keda = true.
#
#   controller -> Scaleway Queue "playwright-runs-keda" -> KEDA (aws-sqs-queue scaler)
#              -> Kubernetes Job (same image, RUNNER_MODE=worker) on a node that scales from 0
#
# Two node pools:
#   system  - 1 small node, always on, runs KEDA and the cluster add-ons   (billed 24/7)
#   runners - 0..N test nodes, tainted so only test pods land there        (billed while tests run)

locals {
  keda = var.enable_keda ? 1 : 0
}

# ---------- Queue + credentials ----------
resource "scaleway_mnq_sqs_queue" "keda" {
  count                      = local.keda
  project_id                 = scaleway_mnq_sqs.this.project_id
  name                       = "playwright-runs-keda"
  sqs_endpoint               = scaleway_mnq_sqs.this.endpoint
  access_key                 = scaleway_mnq_sqs_credentials.send.access_key
  secret_key                 = scaleway_mnq_sqs_credentials.send.secret_key
  visibility_timeout_seconds = 900
  message_max_age            = 3600
}

# Used by KEDA (queue length) and by the worker pods (receive + delete).
resource "scaleway_mnq_sqs_credentials" "keda" {
  count      = local.keda
  project_id = scaleway_mnq_sqs.this.project_id
  name       = "keda-worker"
  permissions {
    can_publish = false
    can_receive = true
    can_manage  = false
  }
}

# ---------- Registry pull key (the registry is private) ----------
resource "scaleway_iam_application" "registry_pull" {
  count       = local.keda
  name        = "${var.project_name}-registry-pull"
  description = "Kapsule pulls the Playwright image"
}

resource "scaleway_iam_policy" "registry_pull" {
  count          = local.keda
  name           = "${var.project_name}-registry-pull"
  application_id = scaleway_iam_application.registry_pull[0].id
  rule {
    project_ids          = [scaleway_account_project.this.id]
    permission_set_names = ["ContainerRegistryReadOnly"]
  }
}

resource "scaleway_iam_api_key" "registry_pull" {
  count              = local.keda
  application_id     = scaleway_iam_application.registry_pull[0].id
  default_project_id = scaleway_account_project.this.id
  description        = "Kapsule image pulls"

  lifecycle {
    ignore_changes = [expires_at]
  }
}

# ---------- Cluster ----------
resource "scaleway_vpc_private_network" "keda" {
  count      = local.keda
  name       = "playwright-keda"
  project_id = scaleway_account_project.this.id
}

data "scaleway_k8s_version" "latest" {
  count = local.keda
  name  = "latest"
}

resource "scaleway_k8s_cluster" "keda" {
  count                       = local.keda
  name                        = "playwright-keda"
  project_id                  = scaleway_account_project.this.id
  type                        = "kapsule" # shared control plane: free
  version                     = data.scaleway_k8s_version.latest[0].name
  cni                         = "cilium"
  private_network_id          = scaleway_vpc_private_network.keda[0].id
  delete_additional_resources = true # destroy also removes volumes/LBs the cluster created

  autoscaler_config {
    # Remove idle runner nodes quickly: they are the expensive part.
    scale_down_delay_after_add    = "2m"
    scale_down_unneeded_time      = "2m"
    ignore_daemonsets_utilization = true
  }

  lifecycle {
    ignore_changes = [version] # upgrade deliberately, not on every apply
  }
}

resource "scaleway_k8s_pool" "system" {
  count               = local.keda
  cluster_id          = scaleway_k8s_cluster.keda[0].id
  name                = "system"
  node_type           = var.keda_system_node_type
  size                = 1
  autoscaling         = false
  autohealing         = true
  wait_for_pool_ready = true
}

resource "scaleway_k8s_pool" "runners" {
  count       = local.keda
  cluster_id  = scaleway_k8s_cluster.keda[0].id
  name        = "runners"
  node_type   = var.keda_runner_node_type
  size        = 0
  min_size    = 0
  max_size    = var.keda_runner_max_nodes
  autoscaling = true
  autohealing = true
  # Kapsule turns "taint=" tags into node taints: only pods that tolerate it (the test Jobs) land here,
  # so nothing else keeps a runner node alive.
  tags                = ["taint=dedicated=playwright:NoSchedule"]
  wait_for_pool_ready = true

  lifecycle {
    ignore_changes = [size] # owned by the autoscaler
  }
}

# ---------- KEDA ----------
resource "helm_release" "keda" {
  count            = local.keda
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.21.1"
  namespace        = "keda"
  create_namespace = true
  wait             = true

  depends_on = [scaleway_k8s_pool.system]
}

# ScaledJob, its trigger auth and secrets (local chart in infra/charts/playwright-keda).
resource "helm_release" "runner" {
  count            = local.keda
  name             = "playwright"
  chart            = "${path.module}/charts/playwright-keda"
  namespace        = "playwright"
  create_namespace = true

  values = [yamlencode({
    image       = terraform_data.image.output
    registry    = split("/", terraform_data.image.output)[0]
    pullSecret  = scaleway_iam_api_key.registry_pull[0].secret_key
    pool        = scaleway_k8s_pool.runners[0].name
    maxReplicas = var.keda_runner_max_nodes
    sqs = {
      endpoint  = scaleway_mnq_sqs.this.endpoint
      queueUrl  = scaleway_mnq_sqs_queue.keda[0].url
      region    = var.region
      accessKey = scaleway_mnq_sqs_credentials.keda[0].access_key
      secretKey = scaleway_mnq_sqs_credentials.keda[0].secret_key
    }
    report = {
      bucket    = scaleway_object_bucket.reports.name
      region    = var.region
      accessKey = scaleway_iam_api_key.reports.access_key
      secretKey = scaleway_iam_api_key.reports.secret_key
    }
    runSecret = random_password.run_secret.result
    # Leave headroom for kubelet/system pods on a 4 vCPU / 8 GB node.
    resources = {
      requests = { cpu = "3500m", memory = "6Gi" }
      limits   = { memory = "7Gi" }
    }
  })]

  depends_on = [helm_release.keda]
}
