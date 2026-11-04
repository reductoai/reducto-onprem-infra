locals {
  reducto_managed_values = yamlencode(merge(
    {
      ingress = {
        host = var.reducto_host
      }
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.reducto.arn
        }
      }
      env = merge(
        {
          DATABASE_URL = local.pooled_database_url
          BUCKET       = aws_s3_bucket.reducto_storage.bucket
        },
        var.enable_elasticache ? {
          REDIS_URL       = local.elasticache_url
          ELASTICACHE_URL = local.elasticache_url
        } : {},
      )
    },
    var.enable_elasticache ? {
      redis = {
        enabled = false
      }
    } : {},
    # Cluster-derived settings of the agent service's in-cluster sandbox
    # provider (docs/install/deep-extract-agent-sandbox.md). Turning it on
    # (agentService.enabled, k8sAgentSandbox.enabled, warmPools, providerKeys,
    # profiles) stays in the customer's values file. Only set with
    # enable_agent_sandbox, so older charts without agentService never see it.
    var.enable_agent_sandbox ? {
      agentService = {
        sandboxProviders = {
          k8sAgentSandbox = {
            namespace        = local.agent_sandbox_chart_namespace
            runtimeClassName = "gvisor"
            # Terraform owns the namespace deny-all (agent-sandbox.tf).
            networkPolicy = { createDenyAll = false }
          }
        }
        # The service fetches inputs and uploads outputs only on these hosts:
        # the job bucket's virtual-hosted S3 host, which the worker signs.
        # us-east-1 also gets the legacy global host, which boto3 can sign
        # there.
        tuning = {
          io = {
            url_hosts = concat(
              ["${aws_s3_bucket.reducto_storage.bucket}.s3.${var.region}.amazonaws.com"],
              var.region == "us-east-1" ? ["${aws_s3_bucket.reducto_storage.bucket}.s3.amazonaws.com"] : [],
            )
          }
        }
      }
    } : {},
  ))

  # reducto-agent-sandbox when it is a sandbox namespace (the default),
  # otherwise the first one.
  agent_sandbox_chart_namespace = contains(tolist(local.agent_sandbox_namespaces), "reducto-agent-sandbox") ? "reducto-agent-sandbox" : try(sort(local.agent_sandbox_namespaces)[0], null)
}

resource "helm_release" "reducto" {
  count            = var.enable_reducto ? 1 : 0
  namespace        = "reducto"
  name             = "reducto"
  create_namespace = true

  repository_username = var.reducto_helm_repo_username
  repository_password = var.reducto_helm_repo_password

  chart   = var.reducto_helm_chart
  version = var.reducto_helm_chart_version
  wait    = false
  timeout = var.helm_release_timeout

  values = concat(
    [
      file("values/reducto.yaml"),
      var.datadog_api_key != "" ? yamlencode(local.otel_env_vars) : "",
      local.reducto_managed_values,
    ],
    [for values_path in var.reducto_extra_values_files : file(values_path)],
  )

  depends_on = [
    module.eks,
    module.rds,
    aws_s3_bucket.reducto_storage,
    aws_iam_role.reducto,
    helm_release.ingress_nginx,
    helm_release.karpenter,
    helm_release.keda,
    helm_release.cert_manager,
    aws_elasticache_replication_group.reducto,
    # With the agent sandbox on, a live render of the chart checks the CRDs,
    # the RuntimeClass and the sandbox namespace, and the agent-service start
    # check needs the deny-all and a running controller.
    kubectl_manifest.agent_sandbox_ext,
    kubectl_manifest.agent_sandbox_controller_workloads_binding,
    kubectl_manifest.agent_sandbox_controller_vap,
    kubectl_manifest.agent_sandbox_deny_all,
    kubectl_manifest.gvisor,
    kubectl_manifest.kyverno_require_sandbox_gvisor,
    kubectl_manifest.kyverno_require_sandbox_template_unmanaged,
  ]
}
