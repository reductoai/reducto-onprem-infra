# Dedicated GKE Sandbox (gVisor) node pool for the agent-sandbox pods.
#
# GKE Sandbox (https://cloud.google.com/kubernetes-engine/docs/how-to/sandbox-pods):
#   - needs the Container-Optimized OS containerd image;
#   - labels each node sandbox.gke.io/runtime=gvisor and taints it
#     sandbox.gke.io/runtime=gvisor:NoSchedule;
#   - provides the `gvisor` RuntimeClass (no RuntimeClass object to create here);
#   - needs at least one non-sandbox pool in the cluster for GKE system workloads;
#   - cannot be turned off on a pool: delete the pool instead.
#
# On top of that, this pool carries its own label + taint (node-type /
# reducto.ai/sandbox, the same as hosted EKS) so the Reducto warm pool lands only
# on this pool and no other gVisor workload of the customer lands here.

locals {
  sandbox_node_labels = { "node-type" = "reducto-sandbox" }
  sandbox_node_taint  = { key = "reducto.ai/sandbox", value = "true", effect = "NoSchedule" }

  # Applied by GKE Sandbox itself.
  gke_sandbox_label = { "sandbox.gke.io/runtime" = "gvisor" }
  gke_sandbox_taint = { key = "sandbox.gke.io/runtime", value = "gvisor", effect = "NoSchedule" }

  # The GKE default node scopes (`gcloud --scopes=gke-default`): image pulls
  # from GCR/Artifact Registry, logging, monitoring. IAM on the dedicated
  # service account below is what actually bounds the node.
  sandbox_node_oauth_scopes = [
    "https://www.googleapis.com/auth/devstorage.read_only",
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/monitoring",
    "https://www.googleapis.com/auth/service.management.readonly",
    "https://www.googleapis.com/auth/servicecontrol",
    "https://www.googleapis.com/auth/trace.append",
  ]
}

# Least-privilege node identity, not the Compute Engine default SA (which has
# project Editor in many projects).
resource "google_service_account" "sandbox_node" {
  project      = var.project_id
  account_id   = "${substr(var.node_pool_name, 0, 24)}-node"
  display_name = "GKE ${var.cluster_name} ${var.node_pool_name} nodes"
}

resource "google_project_iam_member" "sandbox_node" {
  for_each = toset(concat(["roles/container.defaultNodeServiceAccount"], var.node_service_account_extra_roles))

  project = var.project_id
  role    = each.value
  member  = google_service_account.sandbox_node.member
}

resource "google_container_node_pool" "sandbox" {
  project  = var.project_id
  cluster  = data.google_container_cluster.this.name
  location = var.cluster_location
  name     = var.node_pool_name

  node_locations    = length(var.node_locations) > 0 ? var.node_locations : null
  max_pods_per_node = var.max_pods_per_node

  initial_node_count = var.node_min_count
  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Surge one node, never take one away first: an upgrade still drains the old
  # nodes and ends the sessions on them (see the doc's caveats), but capacity
  # does not drop below the pool while it does.
  upgrade_settings {
    strategy        = "SURGE"
    max_surge       = 1
    max_unavailable = 0
  }

  dynamic "network_config" {
    for_each = var.sandbox_pod_range == null ? [] : [var.sandbox_pod_range]
    content {
      create_pod_range    = network_config.value.create
      pod_range           = network_config.value.name
      pod_ipv4_cidr_block = network_config.value.create ? network_config.value.cidr : null
    }
  }

  node_config {
    machine_type = var.node_machine_type
    image_type   = "COS_CONTAINERD"
    disk_size_gb = var.node_disk_size_gb
    disk_type    = var.node_disk_type

    service_account = google_service_account.sandbox_node.email
    oauth_scopes    = local.sandbox_node_oauth_scopes

    sandbox_config {
      type = "GVISOR"
    }

    labels          = local.sandbox_node_labels
    resource_labels = var.node_resource_labels

    taint {
      key    = local.sandbox_node_taint.key
      value  = local.sandbox_node_taint.value
      effect = "NO_SCHEDULE"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # GKE metadata server: pods see only Workload Identity, never the node's
    # credentials or the instance attributes (kube-env). The sandbox namespace
    # denies all egress, so sandbox pods do not reach it at all.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    metadata = {
      "disable-legacy-endpoints" = "true"
    }

    kubelet_config {
      # No unauthenticated kubelet read-only port (10255) on these nodes.
      insecure_kubelet_readonly_port_enabled = "FALSE"
    }
  }

  lifecycle {
    # The autoscaler owns the node count after creation.
    ignore_changes = [initial_node_count]

    precondition {
      condition     = var.sandbox_pod_range != null || var.accept_no_vpc_firewall
      error_message = "Set sandbox_pod_range (a dedicated pod range, so the VPC firewall can deny sandbox pods), or set accept_no_vpc_firewall = true to rely on NetworkPolicy alone."
    }

    precondition {
      condition     = var.node_max_count >= var.node_min_count
      error_message = "node_max_count must be >= node_min_count."
    }
  }

  depends_on = [google_project_iam_member.sandbox_node]
}
