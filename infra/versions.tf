terraform {
  required_version = ">= 1.8"

  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.93"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
  }

  # Demo setup: state is kept locally in infra/terraform.tfstate (git-ignored).
  # It contains secrets. For a team, move it to a remote backend (e.g. Scaleway Object Storage).
}

# Credentials come from your scw CLI profile (~/.config/scw/config.yaml) or SCW_* env vars.
# Every resource sets project_id explicitly, so your CLI's default project is never touched.
provider "scaleway" {
  region = var.region
  zone   = "${var.region}-1"
}

# Only used when enable_keda = true: talks to the Kapsule cluster created in keda.tf.
# The cluster token stays in memory/state; no kubeconfig file is written.
provider "helm" {
  kubernetes = {
    host                   = try(scaleway_k8s_cluster.keda[0].kubeconfig[0].host, "")
    token                  = try(scaleway_k8s_cluster.keda[0].kubeconfig[0].token, "")
    cluster_ca_certificate = try(base64decode(scaleway_k8s_cluster.keda[0].kubeconfig[0].cluster_ca_certificate), "")
  }
}
