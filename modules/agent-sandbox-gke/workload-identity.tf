# Workload Identity for the Reducto worker: the worker stages agent-service
# inputs and outputs in the customer's GCS bucket and hands the agent service
# signed URLs (GET for inputs, PUT for outputs). It therefore needs object
# read/write/delete on the bucket and the right to sign as itself: with
# Workload Identity there is no private key, so V4 signing goes through
# iam.serviceAccounts.signBlob on the worker's own GSA
# (https://cloud.google.com/storage/docs/access-control/signing-urls-with-helpers).
#
# The agent-service KSA needs no Google identity (it moves bytes through the
# signed URLs); that changes only if the model provider is Vertex AI, which is
# out of scope here. The sandbox pods have no identity and no egress.
#
# Binding: the chart's worker KSA (<release>-reducto in the release namespace)
# impersonates the GSA. Set the KSA annotation from the
# `worker_service_account_annotations` output in the chart values
# (serviceAccount.annotations). The worker's node pool must run the GKE
# metadata server (workload_metadata_config.mode = GKE_METADATA).

resource "google_service_account" "worker" {
  count = var.enable_worker_workload_identity ? 1 : 0

  project      = var.project_id
  account_id   = var.worker_gsa_account_id
  display_name = "Reducto worker (${var.cluster_name})"
  description  = "Reducto worker KSA ${var.reducto_namespace}/${var.worker_service_account_name} via Workload Identity: GCS staging bucket + signed URLs."
}

# storage.objectUser: get/list/create/update/delete objects (no bucket IAM or
# bucket settings).
resource "google_storage_bucket_iam_member" "worker_objects" {
  count = var.enable_worker_workload_identity ? 1 : 0

  bucket = var.bucket_name
  role   = "roles/storage.objectUser"
  member = google_service_account.worker[0].member

  lifecycle {
    precondition {
      condition     = var.bucket_name != null && var.bucket_name != ""
      error_message = "bucket_name is required when enable_worker_workload_identity = true."
    }
  }
}

# signBlob on ITSELF only (resource-level grant on the GSA, not project-wide
# Token Creator, which would let it impersonate every SA in the project).
resource "google_service_account_iam_member" "worker_sign_self" {
  count = var.enable_worker_workload_identity ? 1 : 0

  service_account_id = google_service_account.worker[0].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_service_account.worker[0].member
}

resource "google_service_account_iam_member" "worker_workload_identity" {
  count = var.enable_worker_workload_identity ? 1 : 0

  service_account_id = google_service_account.worker[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.workload_pool}[${var.reducto_namespace}/${var.worker_service_account_name}]"
}
