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
# The NetworkPolicies below are the actual isolation mechanism. Every pod in a
# sandbox namespace starts from a namespace-wide default deny, so a pod without
# the controller's sandbox-name-hash label gets no traffic at all. Labeled
# sandbox pods may reach only the in-cluster targets in
# var.sandbox_egress_allow and the Envoy data plane on :10080 — no DNS, no
# public internet, no VPC, no IMDS, no API server. DNS is withheld because
# CoreDNS recurses to the internet, so query names alone would be an exfil
# channel; Envoy resolves the real upstream hosts. Envoy is the only door to the
# outside: each host in var.sandbox_egress_allowlist gets an HTTPRoute
# (plain-HTTP forward-proxy request in, TLS out to the real host), anything
# else is a 404, and Envoy's JSON access log is the per-request audit trail.
# The Envoy data plane may only originate connections to public IPs
# (local.pi_sandbox_blocked_cidrs excluded) so an allowlisted name resolving
# to a VPC/IMDS address is still dropped; the control plane only excludes
# IMDS since it needs the API server. The public EKS endpoint is a public IP
# and is NOT covered by the blocked list; var.enable_agent_sandbox's
# validation requires it to be off or CIDR-restricted.
#
# Sandbox pods must set HTTP_PROXY/HTTPS_PROXY to output.pi_egress_proxy_url,
# which uses the proxy Service's pinned ClusterIP since sandboxes cannot
# resolve names, and in-cluster targets must likewise be addressed by
# ClusterIP. SandboxTemplates must set networkPolicyManagement: Unmanaged
# (enforced by Kyverno): the upstream Managed default makes the controller
# add its own policy allowing all public egress, and policies are additive.

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

  # Every namespace the controller may create pods in, minus its own.
  pi_sandbox_namespaces = setsubtract(var.agent_sandbox_write_namespaces, ["agent-sandbox-system"])

  # Offset 200 sits in the service CIDR's static band, which the API server
  # skips for dynamic allocation while it has room elsewhere, so it does not
  # collide with kube-dns (.10) or the kubernetes Service (.1).
  pi_egress_proxy_cluster_ip = coalesce(var.pi_egress_proxy_cluster_ip, cidrhost(module.eks.cluster_service_cidr, 200))

  pi_dns_egress = {
    to = [{
      namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }
    }]
    ports = [
      { protocol = "UDP", port = 53 },
      { protocol = "TCP", port = 53 },
    ]
  }

  # IPv4 ranges the Envoy data plane must never reach on the sandbox's behalf.
  # Derived from the cluster's own addressing (VPC and service CIDR; subnets
  # and the pod CIDR are carved from the VPC in vpc.tf) rather than assuming
  # RFC1918, so a non-RFC1918 VPC or EKS custom networking (100.64.0.0/10 pod
  # CIDR) does not leak pods/VPC through the proxy. Overlapping entries are
  # harmless. IPv6 is denied outright: no egress rule here matches an IPv6
  # ipBlock.
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

  # Envoy Gateway runs the proxy Deployment in the controller namespace; the
  # Gateway's :80 listener is container port 10080.
  pi_sandbox_envoy_egress = {
    to    = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = var.pi_egress_controller_namespace } } }]
    ports = [{ protocol = "TCP", port = 10080 }]
  }

  # Upstreams the Envoy data plane may open on behalf of sandbox pods: public
  # IPv4 only, on the allowlisted ports.
  pi_envoy_upstream_egress = {
    to = [{
      ipBlock = {
        cidr   = "0.0.0.0/0"
        except = local.pi_sandbox_blocked_cidrs
      }
    }]
    ports = [for p in distinct([for a in var.sandbox_egress_allowlist : a.port]) : { protocol = "TCP", port = p }]
  }

  # The trusted Envoy control plane needs the (private) API server; only IMDS
  # itself is excluded.
  pi_internet_https_egress = {
    to    = [{ ipBlock = { cidr = "0.0.0.0/0", except = ["169.254.169.254/32"] } }]
    ports = [{ protocol = "TCP", port = 443 }]
  }

  pi_egress_allowlist = { for a in var.sandbox_egress_allowlist : a.host => a }

  # In-cluster services the sandbox is allowed to call (e.g. the Reducto API or
  # an inference endpoint). Namespace + port scoped, never an ipBlock, so it can
  # only ever name cluster workloads.
  pi_sandbox_allowed_egress = [
    for a in var.sandbox_egress_allow : {
      to    = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = a.namespace } } }]
      ports = [{ protocol = a.protocol, port = a.port }]
    }
  ]

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
# real namespace to allow from. In a real deployment
# pi_sandbox_client_namespace is the Reducto app's own namespace and
# create_pi_sandbox_client_namespace = false leaves it (and its egress) alone.
resource "kubectl_manifest" "pi_sandbox_client_namespace" {
  count = var.enable_agent_sandbox && var.create_pi_sandbox_client_namespace ? 1 : 0

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
      config = {
        envoyGateway = {
          extensionApis = { enableBackend = true }
        }
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
            patch = {
              value = { spec = { clusterIP = local.pi_egress_proxy_cluster_ip } }
            }
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

# --- Egress allowlist -------------------------------------------------------

# One Backend + BackendTLSPolicy + HTTPRoute per allowlisted host. The sandbox
# sends `GET http://api.example.com/...` to the proxy; the HTTPRoute matches on
# :authority, the Backend points at the FQDN, and the BackendTLSPolicy makes
# Envoy originate TLS with SNI/SAN = host against system CAs.
resource "kubectl_manifest" "pi_egress_backend" {
  for_each = var.enable_agent_sandbox ? local.pi_egress_allowlist : {}

  yaml_body = yamlencode({
    apiVersion = "gateway.envoyproxy.io/v1alpha1"
    kind       = "Backend"
    metadata = {
      name      = each.key
      namespace = var.pi_egress_namespace
      labels    = local.pi_labels
    }
    spec = {
      endpoints = [{ fqdn = { hostname = each.value.host, port = each.value.port } }]
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.pi_gateway]
}

resource "kubectl_manifest" "pi_egress_backend_tls" {
  for_each = var.enable_agent_sandbox ? local.pi_egress_allowlist : {}

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "BackendTLSPolicy"
    metadata = {
      name      = each.key
      namespace = var.pi_egress_namespace
      labels    = local.pi_labels
    }
    spec = {
      targetRefs = [{ group = "gateway.envoyproxy.io", kind = "Backend", name = each.key }]
      validation = {
        wellKnownCACertificates = "System"
        hostname                = each.value.host
      }
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.pi_egress_backend]
}

resource "kubectl_manifest" "pi_egress_route" {
  for_each = var.enable_agent_sandbox ? local.pi_egress_allowlist : {}

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = each.key
      namespace = var.pi_egress_namespace
      labels    = local.pi_labels
    }
    spec = {
      parentRefs = [{ name = "reducto-pi-egress", sectionName = "http" }]
      hostnames  = [each.value.host]
      rules = [{
        backendRefs = [{ group = "gateway.envoyproxy.io", kind = "Backend", name = each.key }]
      }]
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.pi_egress_backend_tls]
}

# --- Network isolation ------------------------------------------------------

# Baseline for every pod in a sandbox namespace, labeled or not. The labeled
# sandbox policy below adds the only allowed paths on top of it.
resource "kubectl_manifest" "sandbox_namespace_default_deny" {
  for_each = var.enable_agent_sandbox ? local.pi_sandbox_namespaces : toset([])

  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata = {
      name      = "default-deny-all"
      namespace = each.value
      labels    = local.pi_labels
    }
    spec = {
      podSelector = {}
      policyTypes = ["Ingress", "Egress"]
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.agent_sandbox_write_namespace]
}

# Sandbox egress: in-cluster allow list and the Envoy proxy. See header.
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
      egress = concat(
        [local.pi_sandbox_envoy_egress],
        local.pi_sandbox_allowed_egress,
      )
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
  count = var.enable_agent_sandbox && var.create_pi_sandbox_client_namespace ? 1 : 0

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
      egress = concat(
        [local.pi_dns_egress, local.pi_xds_egress],
        length(var.sandbox_egress_allowlist) > 0 ? [local.pi_envoy_upstream_egress] : [],
      )
    }
  })

  server_side_apply = true

  depends_on = [kubectl_manifest.pi_egress_controller_namespace]
}
