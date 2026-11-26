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
