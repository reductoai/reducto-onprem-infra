# VPC backstop for the sandbox pods' zero egress.
#
# The primary control is the namespace deny-all NetworkPolicy (namespace.tf),
# enforced by Dataplane V2. This rule is independent of Kubernetes: it denies
# every connection whose source is the sandbox pool's dedicated pod range to
# every VM in the cluster network — the other nodes' kubelets (10250), NodePorts,
# sshd, the pods on other nodes (alias IPs of those VMs), and any other VM in the
# VPC. VPC firewall rules are stateful, so replies to connections the sandbox
# pods accept (agent-service -> sandboxd 8080/9090, kubelet probes) still pass.
#
# Caveats (docs/install/gke-agent-sandbox.md, "Pod to its own node"):
#   - It does not see traffic from a pod to its OWN node: that never leaves the
#     VM. That path is closed by the NetworkPolicy alone (Dataplane V2 enforces
#     egress to the host); the install doc's own-node probe is the check.
#   - It matches only while pod traffic keeps the pod source IP inside the VPC
#     (the GKE default for RFC 1918 destinations). An ip-masq-agent / egress NAT
#     config that SNATs pod traffic to the node IP for in-VPC destinations
#     defeats it.
#   - Google-managed endpoints that are not VMs in this network (the control
#     plane endpoint, Cloud SQL / Memorystore private IPs over peering or PSC)
#     are outside this rule; the NetworkPolicy covers them.

resource "google_compute_firewall" "sandbox_pods_deny" {
  count = var.sandbox_pod_range == null ? 0 : 1

  project = var.project_id
  # <= 63 chars; the hash keeps two clusters in one network apart.
  name        = "${substr(var.node_pool_name, 0, 35)}-pods-deny-${substr(sha1("${var.project_id}/${var.cluster_location}/${var.cluster_name}"), 0, 8)}"
  network     = data.google_container_cluster.this.network
  description = "Deny all traffic from the Reducto agent-sandbox pod range (${var.sandbox_pod_range.name}) to any VM in the network. Managed by Terraform (agent-sandbox-gke)."

  direction     = "INGRESS"
  priority      = var.vpc_firewall_priority
  source_ranges = [var.sandbox_pod_range.cidr]
  # No target_tags / target_service_accounts: applies to every VM in the network.

  deny {
    protocol = "all"
  }

  dynamic "log_config" {
    for_each = var.vpc_firewall_logging ? [1] : []
    content {
      metadata = "INCLUDE_ALL_METADATA"
    }
  }

  lifecycle {
    precondition {
      condition     = can(cidrhost(var.sandbox_pod_range.cidr, 0))
      error_message = "sandbox_pod_range.cidr must be a CIDR block (e.g. 10.96.0.0/16)."
    }
    precondition {
      condition     = var.vpc_firewall_priority < 1000
      error_message = "vpc_firewall_priority must be below 1000 so it beats the GKE-managed allow rules for the pod ranges."
    }
  }
}
