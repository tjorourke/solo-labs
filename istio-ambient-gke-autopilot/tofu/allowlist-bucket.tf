# The allowlist bucket, and the one IAM grant people miss.
#
# Standing up the Autopilot cluster itself is out of scope for this lab, so this
# is only the storage side: a bucket to hold the WorkloadAllowlist files, and the
# grant that lets the AllowlistSynchronizer read them.
#
# The synchroniser reads the bucket as the GKE SERVICE AGENT, not as the caller
# who uploaded the files. Without this grant the synchroniser reports an error
# that reads like an org policy problem, and you will spend an afternoon on the
# wrong thing. Google's own how-to asks for roles/storage.admin here.
#
# Works with OpenTofu or Terraform, google provider >= 5.0.

variable "project_id" { type = string }
variable "project_number" { type = string }
variable "region" {
  type        = string
  description = "Bucket location. Single-region only on sovereign universes, where it is also mandatory (there is no default)."
}
variable "bucket_name" {
  type    = string
  default = "istio-allowlists"
}

# On public GKE the GKE service agent is:
#   service-PROJECT_NUMBER@container-engine-robot.iam.gserviceaccount.com
#
# On a sovereign or distributed universe the domain carries a universe prefix,
# e.g. container-engine-robot.eu0-system.iam.gserviceaccount.com. Confirm yours
# with:
#   gcloud projects get-iam-policy PROJECT_ID \
#     --flatten=bindings --filter='bindings.role:container.serviceAgent' \
#     --format='value(bindings.members)'
variable "gke_service_agent_domain" {
  type    = string
  default = "container-engine-robot.iam.gserviceaccount.com"
}

locals {
  gke_service_agent = "service-${var.project_number}@${var.gke_service_agent_domain}"
}

resource "google_storage_bucket" "allowlist" {
  project  = var.project_id
  name     = var.bucket_name
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # The allowlist that admitted your data plane is worth being able to recover.
  versioning {
    enabled = true
  }
}

# The grant the synchroniser actually runs as.
resource "google_storage_bucket_iam_member" "gke_service_agent" {
  bucket = google_storage_bucket.allowlist.name
  role   = "roles/storage.admin"
  member = "serviceAccount:${local.gke_service_agent}"
}

output "allowlist_bucket" {
  value = google_storage_bucket.allowlist.name
}

output "gke_service_agent" {
  description = "The identity the AllowlistSynchronizer reads the bucket as."
  value       = local.gke_service_agent
}
