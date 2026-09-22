# Envoy Gateway egress stack for agent-sandbox traffic ("Pi egress"). Ported
# (simplified: no Datadog/Doppler/backend-route wiring, no dedicated node
# pool for the control/data plane) from the kubernetes-inference-edge module
# and its pi-sandbox-network policies.
#
# Namespaces:
#   reducto-pi-egress-system — Envoy Gateway control plane (baseline PSS)
#   reducto-pi-egress        — Envoy data plane + Gateway/GatewayClass (baseline PSS)
#   reducto-pi-sandbox       — sandbox runtime pods (restricted PSS; namespace
#                              itself is created by agent-sandbox.tf since
#                              it's in var.agent_sandbox_write_namespaces)
#
# The NetworkPolicies below are the actual K8s-API/IMDS isolation mechanism:
# sandbox pods get public DNS/HTTPS with local.pi_sandbox_blocked_cidrs
# excluded (blocks IMDS *and* any private network, including the EKS API
# server's private endpoint), while the trusted Envoy control/data-plane pods
# only exclude the single IMDS address (169.254.169.254/32) since they
# legitimately need VPC access. The public EKS endpoint is a public IP and is
# NOT covered by this list; var.enable_agent_sandbox's validation requires it
# to be off or CIDR-restricted.

locals {
  pi_labels = {
    "app.kubernetes.io/name"    = "reducto-pi-egress"
    "app.kubernetes.io/part-of" = "reducto-pi-egress"
  }

  pi_namespace_labels = {
    "app.kubernetes.io/part-of"          = "reducto-pi-egress"
    "pod-security.kubernetes.io/enforce" = "baseline"
    "pod-security.kubernetes.io/audit"   = "restricted"
    "pod-security.kubernetes.io/warn"    = "restricted"
  }

  # Namespaces allowed to scrape Envoy's :19001 metrics port. "monitoring" is
  # always created by monitoring.tf; there's no "datadog" namespace on this
  # sandbox cluster.
  pi_metrics_namespaces = ["monitoring"]

  pi_dns_egress = {
    to = [{
      namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }
    }]
    ports = [
      { protocol = "UDP", port = 53 },
      { protocol = "TCP", port = 53 },
    ]
  }

  # IPv4 ranges sandbox pods must never reach. Derived from the cluster's own
  # addressing (VPC and service CIDR; subnets and the pod CIDR are carved from
  # the VPC in vpc.tf) rather than assuming RFC1918, so a
  # non-RFC1918 VPC or EKS custom networking (100.64.0.0/10 pod CIDR) does not
  # leak pods/VPC to the sandbox. Overlapping entries are harmless. IPv6 is
  # denied outright: no egress rule here matches an IPv6 ipBlock.
  pi_sandbox_blocked_cidrs = distinct(concat(
    [
      "10.0.0.0/8",
      "172.16.0.0/12",
      "192.168.0.0/16",
      "100.64.0.0/10",
      "169.254.0.0/16",
    ],
    [var.vpc_cidr, module.eks.cluster_service_cidr],
    var.sandbox_blocked_egress_cidrs,
  ))

  # agent-sandbox uses dnsPolicy=None with public resolvers, so its DNS
  # queries do not traverse the cluster CoreDNS Service.
  pi_public_dns_egress = {
    to = [{
      ipBlock = {
        cidr   = "0.0.0.0/0"
        except = local.pi_sandbox_blocked_cidrs
      }
    }]
    ports = [
      { protocol = "UDP", port = 53 },
      { protocol = "TCP", port = 53 },
    ]
  }

  # The sandbox is untrusted and must not reach cluster, VPC, or metadata
  # endpoints via "public" HTTPS. This is what makes the EKS API server and
  # IMDS unreachable from sandbox pods.
  pi_sandbox_public_https_egress = {
    to = [{
      ipBlock = {
        cidr   = "0.0.0.0/0"
        except = local.pi_sandbox_blocked_cidrs
      }
    }]
    ports = [{ protocol = "TCP", port = 443 }]
  }

  # Trusted Envoy control/data-plane pods still need private VPC/API-server
  # destinations; only IMDS itself is excluded.
  pi_internet_https_egress = {
    to    = [{ ipBlock = { cidr = "0.0.0.0/0", except = ["169.254.169.254/32"] } }]
    ports = [{ protocol = "TCP", port = 443 }]
  }

  pi_xds_egress = {
    to = [{
      namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pi_egress_controller_namespace } }
    }]
    ports = [{ protocol = "TCP", port = 18000 }]
  }

  pi_access_log_json_format = {
    ":authority"              = "%REQ(:AUTHORITY)%"
    bytes_received            = "%BYTES_RECEIVED%"
    bytes_sent                = "%BYTES_SENT%"
    downstream_remote_address = "%DOWNSTREAM_REMOTE_ADDRESS%"
    duration                  = "%DURATION%"
    method                    = "%REQ(:METHOD)%"
    response_code             = "%RESPONSE_CODE%"
    response_flags            = "%RESPONSE_FLAGS%"
    route_name                = "%ROUTE_NAME%"
    start_time                = "%START_TIME%"
    upstream_cluster          = "%UPSTREAM_CLUSTER%"
    upstream_host             = "%UPSTREAM_HOST%"
    "x-forwarded-for"         = "%REQ(X-FORWARDED-FOR)%"
    "x-request-id"            = "%REQ(X-REQUEST-ID)%"
  }
}

resource "kubectl_manifest" "pi_egress_controller_namespace" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = var.pi_egress_controller_namespace
      labels = local.pi_namespace_labels
    }
  })

  server_side_apply = true
  wait              = true
}

resource "kubectl_manifest" "pi_egress_namespace" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = var.pi_egress_namespace
      labels = local.pi_namespace_labels
    }
  })

  server_side_apply = true
  wait              = true
}

# Synthetic "client" namespace so the sandbox-ingress NetworkPolicy has a
# real namespace to allow from. In a real deployment this would be the
# Reducto app's own namespace; on this verification-only cluster
# (enable_reducto = false) nothing runs here yet.
resource "kubectl_manifest" "pi_sandbox_client_namespace" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = var.pi_sandbox_client_namespace }
  })

  server_side_apply = true
  wait              = true
}

resource "helm_release" "envoy_gateway" {
  count = var.enable_agent_sandbox ? 1 : 0

  name       = "envoy-gateway"
  repository = "oci://docker.io/envoyproxy"
  chart      = "gateway-helm"
  version    = var.envoy_gateway_chart_version
  namespace  = var.pi_egress_controller_namespace
  atomic     = true
  timeout    = 1800

  values = [
    yamlencode({
      deployment = {
        replicas = 2
      }
      podDisruptionBudget = {
        minAvailable = 1
      }
      service = {
        type = "ClusterIP"
      }
    })
  ]

  depends_on = [kubectl_manifest.pi_egress_controller_namespace]
}

resource "kubectl_manifest" "pi_envoy_proxy" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.envoyproxy.io/v1alpha1"
    kind       = "EnvoyProxy"
    metadata = {
      name      = "reducto-pi-egress"
      namespace = var.pi_egress_namespace
      labels    = local.pi_labels
    }
    spec = {
      provider = {
        type = "Kubernetes"
        kubernetes = {
          envoyDeployment = {
            name     = "reducto-pi-egress"
            replicas = 2
            container = {
              resources = {
                limits   = { memory = "1Gi" }
                requests = { cpu = "250m", memory = "256Mi" }
              }
            }
          }
          envoyPDB = {
            name         = "reducto-pi-egress"
            minAvailable = 1
          }
          envoyService = {
            name = "reducto-pi-egress"
            type = "ClusterIP"
          }
        }
      }
      shutdown = {
        drainTimeout     = "300s"
        minDrainDuration = "10s"
      }
      telemetry = {
        accessLog = {
          settings = [{
            format = { type = "JSON", json = local.pi_access_log_json_format }
            sinks  = [{ type = "File", file = { path = "/dev/stdout" } }]
          }]
        }
      }
    }
  })

  server_side_apply = true

  depends_on = [helm_release.envoy_gateway]
}

resource "kubectl_manifest" "pi_gateway_class" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name   = "reducto-pi-egress"
      labels = { "app.kubernetes.io/part-of" = "reducto-pi-egress" }
    }
    spec = {
      controllerName = "gateway.envoyproxy.io/gatewayclass-controller"
      parametersRef = {
        group     = "gateway.envoyproxy.io"
        kind      = "EnvoyProxy"
        name      = "reducto-pi-egress"
        namespace = var.pi_egress_namespace
      }
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.pi_envoy_proxy]
}

resource "kubectl_manifest" "pi_gateway" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "reducto-pi-egress"
      namespace = var.pi_egress_namespace
      labels    = local.pi_labels
    }
    spec = {
      gatewayClassName = "reducto-pi-egress"
      listeners = [{
        name          = "http"
        port          = 80
        protocol      = "HTTP"
        allowedRoutes = { namespaces = { from = "Same" } }
      }]
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.pi_gateway_class]
}

# --- Network isolation ------------------------------------------------------

# This is intentionally a transitional policy: sandbox pods still need
# general internet access for URL-input downloads / agent commands. It
# blocks all private-network and metadata-service destinations while
# allowing public internet + the egress proxy path.
resource "kubectl_manifest" "sandbox_network_policy" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "reducto-pi-sandbox-network"
      namespace = var.pi_sandbox_namespace
      labels    = local.pi_labels
    }
    spec = {
      podSelector = {
        matchExpressions = [{ key = "agents.x-k8s.io/sandbox-name-hash", operator = "Exists" }]
      }
      policyTypes = ["Ingress", "Egress"]
      ingress = [{
        from  = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pi_sandbox_client_namespace } } }]
        ports = [{ protocol = "TCP", port = 8888 }]
      }]
      egress = [
        local.pi_dns_egress,
        local.pi_public_dns_egress,
        local.pi_sandbox_public_https_egress,
        {
          to    = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pi_egress_controller_namespace } } }]
          ports = [{ protocol = "TCP", port = 80 }, { protocol = "TCP", port = 10080 }]
        },
      ]
    }
  })

  server_side_apply = true

  depends_on = [
    kubectl_manifest.agent_sandbox_write_namespace,
    kubectl_manifest.pi_sandbox_client_namespace,
    kubectl_manifest.pi_egress_controller_namespace,
  ]
}

resource "kubectl_manifest" "staging_to_sandbox_network_policy" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "allow-reducto-pi-sandbox-runtime"
      namespace = var.pi_sandbox_client_namespace
      labels    = local.pi_labels
    }
    spec = {
      podSelector = {}
      policyTypes = ["Egress"]
      egress = [{
        to    = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pi_sandbox_namespace } } }]
        ports = [{ protocol = "TCP", port = 8888 }]
      }]
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.pi_sandbox_client_namespace]
}

resource "kubectl_manifest" "envoy_controller_network_policy" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "reducto-pi-egress-controller-network"
      namespace = var.pi_egress_controller_namespace
      labels    = local.pi_labels
    }
    spec = {
      podSelector = {
        matchLabels = { "app.kubernetes.io/name" = "gateway-helm", "control-plane" = "envoy-gateway" }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress = [
        { ports = [{ protocol = "TCP", port = 9443 }] },
        {
          from = [
            { namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pi_egress_controller_namespace } } },
            { namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pi_egress_namespace } } },
          ]
          ports = [{ protocol = "TCP", port = 18000 }]
        },
        {
          from  = [{ namespaceSelector = { matchExpressions = [{ key = "kubernetes.io/metadata.name", operator = "In", values = local.pi_metrics_namespaces }] } }]
          ports = [{ protocol = "TCP", port = 19001 }]
        },
      ]
      egress = [local.pi_dns_egress, local.pi_internet_https_egress]
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.pi_egress_controller_namespace]
}

resource "kubectl_manifest" "envoy_data_plane_network_policy" {
  count = var.enable_agent_sandbox ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "reducto-pi-egress-data-plane-network"
      namespace = var.pi_egress_controller_namespace
      labels    = local.pi_labels
    }
    spec = {
      podSelector = {
        matchLabels = {
          "app.kubernetes.io/component"                    = "proxy"
          "app.kubernetes.io/name"                         = "envoy"
          "gateway.envoyproxy.io/owning-gateway-name"      = "reducto-pi-egress"
          "gateway.envoyproxy.io/owning-gateway-namespace" = var.pi_egress_namespace
        }
      }
      policyTypes = ["Ingress", "Egress"]
      ingress = [
        {
          from  = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pi_sandbox_namespace } } }]
          ports = [{ protocol = "TCP", port = 10080 }]
        },
        {
          from  = [{ namespaceSelector = { matchExpressions = [{ key = "kubernetes.io/metadata.name", operator = "In", values = local.pi_metrics_namespaces }] } }]
          ports = [{ protocol = "TCP", port = 19001 }]
        },
      ]
      egress = [local.pi_dns_egress, local.pi_xds_egress, local.pi_internet_https_egress]
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.pi_egress_controller_namespace]
}
