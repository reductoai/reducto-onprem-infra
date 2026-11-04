# Example root: install the agent-service sandbox prerequisites into an
# existing AKS cluster. PREVIEW, not yet qualified (FDE-18).
# See docs/install/aks-agent-sandbox.md.

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.78.0, < 6.0.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0.0, < 3.0.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "1.19.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

data "azurerm_kubernetes_cluster" "this" {
  name                = var.cluster_name
  resource_group_name = var.cluster_resource_group_name
}

# Entra ID (AAD) integrated clusters: kubelogin exchanges the Azure CLI login
# for a cluster token (server ID 6dae42f8-... is the AKS AAD server app, the
# same for every cluster). Clusters with local accounts can instead use
# kube_admin_config[0] client_certificate / client_key.
provider "kubectl" {
  host                   = data.azurerm_kubernetes_cluster.this.kube_config[0].host
  cluster_ca_certificate = base64decode(data.azurerm_kubernetes_cluster.this.kube_config[0].cluster_ca_certificate)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "kubelogin"
    args        = ["get-token", "--login", "azurecli", "--server-id", "6dae42f8-4368-4678-94ff-3960e28e3630"]
  }
}

module "agent_sandbox" {
  source = "../../modules/agent-sandbox-aks"

  cluster_name                = var.cluster_name
  cluster_resource_group_name = var.cluster_resource_group_name

  node_vm_size        = var.node_vm_size
  node_min_count      = var.node_min_count
  node_max_count      = var.node_max_count
  node_vnet_subnet_id = var.node_vnet_subnet_id
  node_zones          = var.node_zones

  sandbox_namespace = var.sandbox_namespace

  workload_identity_service_accounts = var.workload_identity_service_accounts
  storage_account_id                 = var.storage_account_id
  storage_container_names            = var.storage_container_names

  tags = var.tags
}
