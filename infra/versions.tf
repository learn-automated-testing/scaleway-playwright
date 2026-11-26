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
