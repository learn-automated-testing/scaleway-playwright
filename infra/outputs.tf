output "project_id" {
  value = scaleway_account_project.this.id
}

output "webhook_url" {
  description = "Set automatically on the GitHub App"
  value       = "https://${scaleway_function.webhook.domain_name}"
}

output "runner" {
  value = var.runner
}

output "image" {
  value = terraform_data.image.output
}

output "report_bucket" {
  value = scaleway_object_bucket.reports.name
}

output "job_definition_id" {
  value = scaleway_job_definition.e2e.id
}

output "container_id" {
  value = scaleway_container.runner.id
}

output "queue_url" {
  value = scaleway_mnq_sqs_queue.runs.url
}

output "keda_cluster_id" {
  value = one(scaleway_k8s_cluster.keda[*].id)
}

output "keda_queue_url" {
  value = one(scaleway_mnq_sqs_queue.keda[*].url)
}

output "keda_kubeconfig_command" {
  description = "Get a kubeconfig to watch runs (kubectl get scaledjobs,jobs,pods,nodes)"
  value       = var.enable_keda ? "scw k8s kubeconfig get ${element(split("/", scaleway_k8s_cluster.keda[0].id), 1)} region=${var.region} > ~/.kube/playwright-keda && export KUBECONFIG=~/.kube/playwright-keda" : null
}
