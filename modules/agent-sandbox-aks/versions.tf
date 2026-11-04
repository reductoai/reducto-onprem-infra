terraform {
  # optional() object attributes need 1.3.
  required_version = ">= 1.3.0"

  required_providers {
    # 4.78.0 is the first release that accepts workload_runtime = "KataVmIsolation"
    # (hashicorp/terraform-provider-azurerm#32579). 5.x removed
    # azurerm_federated_identity_credential.parent_id; this module uses
    # user_assigned_identity_id, which both majors accept.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.78.0, < 6.0.0"
    }
    # Reads the managedCluster ARM body for the fields the azurerm data source
    # does not export (securityProfile.workloadIdentity, networkDataplane).
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0.0, < 3.0.0"
    }
    # Same provider and pattern as the AWS root module and the hosted
    # aws-eks-addons stack (kubectl_manifest + kubectl_file_documents).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19.0"
    }
  }
}
