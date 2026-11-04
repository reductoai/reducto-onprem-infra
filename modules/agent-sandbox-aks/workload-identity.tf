# Azure Workload Identity for the Reducto worker -> customer Blob container.
#
# The agent service stages session files through SAS URLs that the Reducto
# worker signs with a USER DELEGATION KEY. A user delegation SAS can grant at
# most what the signing identity holds, so the identity needs:
#   - Storage Blob Delegator on the storage account (getUserDelegationKey is an
#     account-level operation), and
#   - Storage Blob Data Contributor on each container (read, write, delete,
#     list), so both the worker's own I/O and the SAS it signs for the agent
#     service can read, write, and delete.
# (Microsoft Learn, "Create a user delegation SAS",
# https://learn.microsoft.com/rest/api/storageservices/create-user-delegation-sas.)
#
# Credential precedence in the Reducto worker is unchanged (reductoai/api
# docs/onprem/azure_blob_storage.mdx): an account key (AccountKey in the
# connection string or AZURE_STORAGE_ACCOUNT_KEY) wins over workload identity.
# To sign with this identity, remove both. Setting any of AZURE_CLIENT_ID /
# AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE opts in, and then all three
# must be set.
#
# The agent-service ServiceAccount needs no cloud identity (it receives SAS
# URLs). An Azure OpenAI model provider with Entra auth would; out of scope.

locals {
  identity_name = coalesce(var.identity_name, "${var.cluster_name}-reducto-storage")

  # The chart's worker KSA: <release>-reducto in the release namespace.
  worker_subject = "system:serviceaccount:${var.reducto_namespace}:${var.worker_service_account_name}"

  # ARM scope of a container: <account id>/blobServices/default/containers/<name>.
  storage_container_scopes = var.enable_worker_workload_identity ? {
    for c in var.storage_container_names : c => "${var.storage_account_id}/blobServices/default/containers/${c}"
  } : {}
}

resource "azurerm_user_assigned_identity" "reducto_storage" {
  count = var.enable_worker_workload_identity ? 1 : 0

  name                = local.identity_name
  resource_group_name = coalesce(var.identity_resource_group_name, var.cluster_resource_group_name)
  location            = data.azurerm_kubernetes_cluster.this.location
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = var.storage_account_id != null && length(var.storage_container_names) > 0
      error_message = "enable_worker_workload_identity needs storage_account_id and at least one storage_container_names entry."
    }
    precondition {
      condition     = var.storage_account_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.Storage/storageAccounts/[^/]+$", var.storage_account_id))
      error_message = "storage_account_id must be the ARM ID of a storage account (/subscriptions/.../providers/Microsoft.Storage/storageAccounts/<name>)."
    }
  }
}

resource "azurerm_federated_identity_credential" "reducto_storage" {
  count = var.enable_worker_workload_identity ? 1 : 0

  name                      = "${var.reducto_namespace}-${var.worker_service_account_name}"
  user_assigned_identity_id = azurerm_user_assigned_identity.reducto_storage[0].id
  issuer                    = data.azapi_resource.cluster.output.oidc_issuer_url
  subject                   = local.worker_subject
  audience                  = [var.workload_identity_audience]
}

resource "azurerm_role_assignment" "blob_delegator" {
  count = var.enable_worker_workload_identity ? 1 : 0

  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Delegator"
  principal_id         = azurerm_user_assigned_identity.reducto_storage[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Reducto worker (${var.cluster_name}): user delegation keys for SAS signing."
}

resource "azurerm_role_assignment" "blob_data_contributor" {
  for_each = local.storage_container_scopes

  scope                = each.value
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.reducto_storage[0].principal_id
  principal_type       = "ServicePrincipal"
  description          = "Reducto worker (${var.cluster_name}): read/write/delete in ${each.key}, the bound of the SAS it signs."
}
