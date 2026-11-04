# Agent sandbox prerequisites on AKS

> **Status: preview, not yet qualified (FDE-18).** No AKS install has run this
> module end to end yet. The design follows the hosted EKS sandbox and
> Microsoft's documentation, but the items under
> [Not yet verified](#not-yet-verified) need a live AKS cluster to confirm.
> Run every check under [Verify](#verify) before you send customer traffic.

Deep Extract on-prem runs the agent service with the in-cluster sandbox
provider (`k8s-agent-sandbox`). The Reducto Helm chart does not install the
cluster prerequisites. On AKS, the Terraform module `modules/agent-sandbox-aks`
installs them into an existing cluster. `examples/aks` is a root module that
calls it.

The chart's requirements are in reductoai/api `agent-service/AGENTS.md`, section
"On-prem". The module covers them as follows.

| Chart prerequisite | What the module does |
|---|---|
| A gVisor or Kata RuntimeClass | Creates an AKS Pod Sandboxing node pool (`workload_runtime = KataVmIsolation`, Azure Linux). Creates the RuntimeClass `reducto-kata` on the AKS `kata` handler. The class carries the pool's node selector and toleration. |
| A CNI that enforces NetworkPolicy | Fails the plan unless the cluster's `networkProfile.networkPolicy` is `cilium`. You can opt in to `calico`. |
| A host firewall against pod to own node | Uses Cilium's per-endpoint egress enforcement: a deny-all with no egress rule, plus a Cilium egress deny. See [Network design](#network-design). |
| agent-sandbox controller v1.0.6+ with `--extensions` and the CRDs | Installs v1.0.7, the same manifests and RBAC narrowing that hosted runs. |
| The controller may create pods in the sandbox namespace | Adds a namespaced Role and RoleBinding, plus the hosted ValidatingAdmissionPolicy that allows controller pod creation in that namespace only. |
| Pod security that admits uid and gid 1000 | Labels the sandbox namespace with Pod Security Standards `restricted`. The chart's pool pods meet that standard. |
| The image `<tag>-agent-sandbox` and its pull Secret | Not covered. See [Image](#image). |
| Installer RBAC | Optional: `installer_subjects` gets the sandbox-namespace rights the chart needs. See [Installer RBAC](#installer-rbac). |

The module also does the following:

- It adds native ValidatingAdmissionPolicies. Sandbox pods must use the Kata RuntimeClass, set no ServiceAccount token, select the sandbox pool, and use no host namespaces. SandboxTemplates must be `Unmanaged`. No NetworkPolicy in the sandbox namespace may carry an egress rule.
- It sets up Azure Workload Identity for the Reducto worker. It creates a user-assigned identity with federated credentials. The identity gets `Storage Blob Data Contributor` on the containers and `Storage Blob Delegator` on the account.

### Who owns what

| Owner | Objects |
|---|---|
| Terraform (this module) | Kata node pool, RuntimeClass, controller and CRDs, `agent-sandbox-system`, the sandbox namespace and its `deny-all` (zero egress, no DNS), the Cilium egress deny, the controller Role/RoleBinding, all admission policies, the storage identity |
| Helm chart | The ingress policy (8080/9090 from the agent-service pods only), the agent-service Role/RoleBinding, SandboxTemplate/SandboxWarmPool, token Secrets |

Install the chart with `networkPolicy.createDenyAll: false`. Terraform already
makes the deny-all, and the agent service refuses to start if any policy in
the namespace has an egress rule.

## Prerequisites

The existing AKS cluster needs:

- **Kubernetes 1.30 or later.** The module uses `ValidatingAdmissionPolicy` v1. Pod Sandboxing itself needs 1.27 or later.
- **Azure CNI powered by Cilium.** `az aks show -g <rg> -n <cluster> --query networkProfile` must show `"networkPolicy": "cilium"` (and `"networkDataplane": "cilium"`). A cluster created without it can be updated in place: see Microsoft's "Update an existing cluster to Azure CNI Powered by Cilium". Calico works only with opt-in (`allowed_network_policies = ["cilium", "calico"]`); see [Calico](#calico). Azure NPM (`networkPolicy: azure`) is rejected.
- **The OIDC issuer and the workload-identity webhook** (`az aks update --enable-oidc-issuer --enable-workload-identity`). If you set `require_workload_identity_webhook = false` and use the chart's explicit token projection, only the OIDC issuer is needed.
- **At least 2 untainted nodes outside the sandbox pool.** The controller runs 2 replicas with a hard per-node spread and no node selector, the same as the GKE module. The sandbox pool's taint keeps it off the sandbox nodes. A system pool with `only_critical_addons_enabled` (taint `CriticalAddonsOnly`) does not count, because the controller does not tolerate that taint.
- **vCPU quota for the sandbox VM family** in the region. The default is `Standard_D16s_v5`. The size must be generation 2 with nested virtualization, and x86-64 (Arm64 is not supported).
- **The FIPS and Trusted Launch constraints.** Neither can be enabled on a Pod Sandboxing pool.

The applying principal needs:

- **Azure.** Contributor on the cluster (to add a node pool), and rights to create a managed identity in the identity resource group. To create the role assignments it needs Owner or User Access Administrator (or Role Based Access Control Administrator) on the storage account.
- **Kubernetes.** cluster-admin. The module creates CRDs, ClusterRoles, RuntimeClass, and admission policies.

The workstation needs:

- Terraform 1.3 or later.
- The `az` CLI, logged in.
- `kubelogin`, for Entra ID clusters, as in `examples/aks/main.tf`.

## Apply

1. Copy `examples/aks/terraform.tfvars.example` to `terraform.tfvars` and fill it in. `*.tfvars` is git-ignored.

   ```hcl
   subscription_id             = "00000000-0000-0000-0000-000000000000"
   cluster_name                = "reducto-aks"
   cluster_resource_group_name = "reducto-rg"

   node_vm_size   = "Standard_D16s_v5"
   node_min_count = 1
   node_max_count = 3

   # The chart's worker ServiceAccount: <release>-reducto in the release namespace.
   reducto_namespace           = "reducto"
   worker_service_account_name = "reducto-reducto"
   storage_account_id      = "/subscriptions/.../resourceGroups/.../providers/Microsoft.Storage/storageAccounts/reductodata"
   storage_container_names = ["reducto"]
   ```

2. Run the apply:

   ```sh
   cd examples/aks
   terraform init
   terraform plan    # fails here if the cluster checks fail
   terraform apply
   ```

3. Reconcile the cluster once. Microsoft's procedure for adding a Pod Sandboxing pool to an existing cluster runs a plain update after the pool exists:

   ```sh
   az aks update -g <rg> -n <cluster>
   az aks nodepool show -g <rg> --cluster-name <cluster> -n sandbox \
     --query "{workloadRuntime:workloadRuntime, osSKU:osSKU, vmSize:vmSize}" -o table
   ```

   The output must show `KataVmIsolation` and `AzureLinux`.

4. Check that the module's handler matches AKS:

   ```sh
   kubectl get runtimeclass
   kubectl get runtimeclass kata-vm-isolation -o jsonpath='{.handler}{"\n"}'   # expect: kata
   ```

   If AKS reports another handler, set `runtime_class_handler` to it and apply again.

## Chart values

The module's outputs have the same names as the GKE module's:

- **`k8s_agent_sandbox_values`** goes under `agentService.sandboxProviders.k8sAgentSandbox`. It holds:
  - `namespace`
  - `runtimeClassName: reducto-kata`
  - `allowRunc: false`
  - the sandbox pool's `nodeSelector` and `tolerations`; the module's RuntimeClass adds them too, and a duplicate is harmless
  - `networkPolicy: {enabled: true, createDenyAll: false}`
- **`worker_service_account_annotations`** goes under `serviceAccount.annotations`. It holds `azure.workload.identity/client-id` and `azure.workload.identity/tenant-id`.
- **`worker_pod_labels`** (`azure.workload.identity/use: "true"`) goes under the podLabels of every component that uses Azure storage (see below).
- **`worker_identity_client_id`** and **`worker_identity_tenant_id`** are for the chart's explicit projection (`azureWorkloadIdentity`). Use them instead of the annotations when the webhook is off.

Merge them with the rest of the on-prem agent-service values (AGENTS.md, "On-prem"):

```yaml
agentService:
  enabled: true
  providerRegion: us                     # a region of model_providers.json
  providerKeys:
    existingSecret: <customer secret>
    keys: { openai: OPENAI_API_KEY }
  callerWorkers: [<streaqWorkers keys>]  # STREAQ_LOCAL installs only
  sandboxProviders:
    k8sAgentSandbox:
      warmPools:
        pi: { size: 2 }
      image:
        repository: <customer registry>/<repo>   # serves <tag>-agent-sandbox
        pullSecrets: [<secret in the sandbox namespace>]
      # Kata sizing: see below.
      resources:
        requests: { cpu: 500m, memory: 2Gi, ephemeral-storage: 1Gi }
        limits:   { cpu: "2", memory: 2Gi, ephemeral-storage: 10Gi }
  tuning:
    profiles:
      deep_extract:
        sandbox: { provider: k8s-agent-sandbox, image: pi, app: reducto-pi-sandbox }

# Workload identity (webhook path): label every pod that uses Azure storage.
http:
  podLabels: { azure.workload.identity/use: "true" }
worker:
  podLabels: { azure.workload.identity/use: "true" }
streaqWorkerDefaults:
  podLabels: { azure.workload.identity/use: "true" }
```

Follow the order in AGENTS.md, "Turn on k8s-agent-sandbox":

1. Deploy the provider with no profile pointing at it.
2. Check the pool.
3. One deploy later, point `profiles.deep_extract.sandbox` at it.

### Kata sizing

Kata sizes pods differently from gVisor (Microsoft Learn, "Pod sandboxing considerations"):

- **The pod memory limit is the fixed size of the pod VM.** The VM's memory stays charged to the node while the pod lives, idle warm-pool pods included. The hosted pattern (128Mi requests, 2Gi limits, overcommitted) does not carry over. Set `requests.memory` equal to `limits.memory` so the scheduler sees the real footprint.
- **The CPU limit sets the VM's vCPU count,** rounded up to whole vCPUs.
- **The RuntimeClass overhead is added to each pod.** The module defaults to 250m / 256Mi, Microsoft's reference value for a 2Gi pod VM. For a 1Gi VM the reference is 128Mi. Change `runtime_class_overhead` together with the memory limit.
- **Node count:** each pod takes `limits.memory + overhead`. At 2Gi + 256Mi on a `Standard_D16s_v5` (64 GiB), a node holds about 25 sandbox pods after system reservations. Count warm-pool pods and concurrent sessions against that.

Hosted sessions peaked at about 137 MiB (AGENTS.md, "Tune the sandbox pool"). A
1Gi limit (128Mi overhead) is likely enough and doubles the density. That is
not qualified yet.

### Image

The chart pulls `<tag>-agent-sandbox` from `image.repository`. Mirror that
image to the customer registry. Create its pull Secret in the sandbox
namespace and list it in `image.pullSecrets`. An attached ACR needs no pull
Secret. The sandbox nodes pull the image at node level, so the pod's zero
egress does not affect pulls.

### Installer RBAC

The Helm installer needs these rights (AGENTS.md):

- Create a Role, a RoleBinding, and Secrets in the sandbox namespace.
- `get` RuntimeClasses.
- `get` Secrets in the release namespace and the sandbox namespace, for the token `lookup`.

If the installer is not cluster-admin, list it in `installer_subjects`. The module (shared `installer-rbac.tf`) then grants it the sandbox-namespace rights and `get` on the RuntimeClass. The sandbox-namespace rights include every verb the chart's agent-service Role grants, because RBAC refuses to let a subject create a Role with more than it holds. Rights in the release namespace are not covered.

Without cluster-scoped RBAC, set `agentService.auth.createAuthDelegatorBinding: false` and bind `system:auth-delegator` by hand.

### Storage credentials

The module grants the identity:

- `Storage Blob Data Contributor` on each container (read, write, delete). This also caps what a user delegation SAS signed by the identity can grant.
- `Storage Blob Delegator` on the account.

The worker keeps the precedence in api `docs/onprem/azure_blob_storage.mdx`:

- **An account key wins.** If `AccountKey` is in the connection string, or `AZURE_STORAGE_ACCOUNT_KEY` is set, the worker signs with that key. To sign with the identity, remove both.
- **The identity settings go together.** Any of `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, or `AZURE_FEDERATED_TOKEN_FILE` opts in to the identity, and then all three must be set. The webhook injects them.

The agent-service ServiceAccount needs no Azure identity.

## Verify

Run these checks after every install and upgrade. The provider and Terraform
see only the objects. These checks test the behaviour.

1. **Controller and CRDs:**

   ```sh
   kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller
   kubectl api-resources --api-group=agents.x-k8s.io            # sandboxes   v1beta1
   kubectl api-resources --api-group=extensions.agents.x-k8s.io # sandboxclaims/templates/warmpools
   kubectl get validatingadmissionpolicy | grep -E 'restrict-controller-pod-create|agent-sandbox-'
   ```

2. **Admission denies a runc pod in the sandbox namespace.** Save the probe manifest from step 3 as `egress-probe.yaml`. Delete its `runtimeClassName` line, and dry-run it. The command must fail, and the error must name `agent-sandbox-pod-isolation`. The manifest meets the restricted Pod Security Standard, so the denial comes from this policy, not from PodSecurity.

   ```sh
   kubectl apply --dry-run=server -f egress-probe.yaml
   ```

3. **Pod to own node, IMDS, wireserver, API server, and internet are all closed.** Run a probe pod that matches the sandbox pods: the same RuntimeClass (so it lands on a sandbox node), no token, `restricted` PSS. Every line must print `blocked`. A drop shows up as the 5 s timeout.

   ```sh
   kubectl apply -f - <<'EOF'
   apiVersion: v1
   kind: Pod
   metadata:
     name: egress-probe
     namespace: reducto-agent-sandbox
   spec:
     runtimeClassName: reducto-kata
     automountServiceAccountToken: false
     restartPolicy: Never
     securityContext:
       runAsNonRoot: true
       runAsUser: 1000
       runAsGroup: 1000
       seccompProfile: { type: RuntimeDefault }
     containers:
     - name: probe
       image: mcr.microsoft.com/azurelinux/base/core:3.0   # any image with bash + timeout
       env:
       - name: HOST_IP
         valueFrom: { fieldRef: { fieldPath: status.hostIP } }
       command: ["bash", "-c"]
       args:
       - |
         uname -r
         for t in "$HOST_IP:10250" "$HOST_IP:22" "169.254.169.254:80" \
                  "168.63.129.16:80" "168.63.129.16:32526" "168.63.129.16:53" \
                  "$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT" "1.1.1.1:443"; do
           if timeout 5 bash -c "exec 3<>/dev/tcp/${t%:*}/${t##*:}" 2>/dev/null; then
             echo "OPEN    $t"; else echo "blocked $t"; fi
         done
       resources:
         limits: { cpu: "1", memory: 512Mi }
       securityContext:
         allowPrivilegeEscalation: false
         capabilities: { drop: [ALL] }
   EOF
   kubectl -n reducto-agent-sandbox wait --for=jsonpath='{.status.phase}'=Succeeded pod/egress-probe --timeout=180s
   kubectl -n reducto-agent-sandbox logs egress-probe
   kubectl -n reducto-agent-sandbox delete pod egress-probe
   ```

   The module's RuntimeClass adds the sandbox pool's nodeSelector and toleration, which the admission policy requires. With `create_runtime_class = false`, add `nodeSelector: {node-type: reducto-sandbox}` and the `reducto.ai/sandbox` toleration to the probe yourself.

   The first line, from `uname -r`, is the Kata guest kernel. It differs from the node's kernel; Microsoft's example shows `6.6.96.mshv1`. Any `OPEN` line is a failed install: stop and fix it.

4. **Warm pool:** run `kubectl -n reducto-agent-sandbox get sandboxwarmpool,pods -o wide`. The pods must be Ready on the sandbox nodes. Then check the agent-service start log `sandbox.providers`.

5. **Smoke script** (AGENTS.md, "Smoke check"). It checks the gateway and creates a sandbox. It runs `echo` and checks that an outbound connect fails (blocked within the probe's 30 s limit). It exits 0 on success.

   ```sh
   kubectl -n <release namespace> exec deploy/<release>-reducto-agent-service -- \
     node dist/smoke.mjs --profile deep_extract
   ```

6. **Storage identity:** in a worker pod, check that `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_FEDERATED_TOKEN_FILE` are set and the token file exists. Then run a Deep Extract job and open its result link.

## Network design

The sandbox pods have no egress at all: no proxy, and no DNS. The agent
service connects in on 8080 and 9090, and moves every file itself.

**Pod to own node.** The chart asks for "a host firewall on the sandbox nodes
against the path from a pod to its own node". On AKS with Cilium, the policy
engine does this job; no separate node firewall is needed:

- **Cilium enforces each pod's egress policy at the pod's own endpoint, for every destination.** That includes the `host` entity (the pod's own node) and other nodes. Microsoft's Cilium page shows both sides: an `ipBlock` cannot even allow node IPs, and LocalDNS needs an explicit `toEntities: host` allow. With no egress rule, kubelet (10250), NodePorts, hostPorts, IMDS (169.254.169.254), and wireserver (168.63.129.16) are denied, like the internet.
- **The module adds a CiliumClusterwideNetworkPolicy `egressDeny` (all entities, plus the IMDS and wireserver IPs) for the sandbox namespace.** Cilium applies deny rules before allow rules. So a later allow cannot reopen egress, whether it is a stray NetworkPolicy, a CiliumNetworkPolicy, a cluster-wide policy, or a Managed SandboxTemplate. Replies on accepted connections (agent service, kubelet probes) are not new egress and still pass.
- **Kata adds a second wall.** The workload runs behind a guest kernel in its own VM, and Kata supports no host networking. A sandbox kernel exploit lands in the pod VM, not in the node network namespace.
- **NSGs are not used, because they cannot do this job.** Pod to own-node traffic never leaves the host. With Azure CNI Overlay, pod egress is SNATed to the node IP, so an NSG cannot tell pods from the node.
- **AKS IMDS restriction is an optional extra layer.** `az aks update --enable-imds-restriction`, then a node reimage, adds node iptables rules against IMDS for all non-hostNetwork pods. It is a preview and cluster-wide. It cannot be enabled together with Container Insights, Azure Policy, Application Routing, Flux, and other add-ons. So the module leaves it to the customer.

### Calico

The module accepts Calico only with opt-in. Calico enforces a workload's
egress policy on the host side of its interface. That should cover traffic to
the pod's own node, but this has not been verified on AKS. The Cilium egress
deny does not apply, so the deny-all and the egress admission policy are the
only network guards. Step 3 of [Verify](#verify) is mandatory.

**Azure NPM is rejected.** Linux NPM retires on 2028-09-30. Its pod to own-node
behaviour is unverified.

## Admission design

Hosted enforces these rules with Kyverno. The AKS module uses native
ValidatingAdmissionPolicies, all with `failurePolicy: Fail`:

| Policy | Rule |
|---|---|
| `restrict-controller-pod-create` | Copied from hosted. The controller ServiceAccount may create or update pods only in the sandbox namespace. |
| `agent-sandbox-pod-isolation` | Every pod in the sandbox namespace, and every pod with `agents.x-k8s.io/sandbox-name-hash`, must meet four rules: set the Kata `runtimeClassName`, set `automountServiceAccountToken: false`, select the sandbox pool (`node-type: reducto-sandbox`), and use no hostNetwork, hostPID, or hostIPC. |
| `agent-sandbox-template-unmanaged` | SandboxTemplates in the sandbox namespace must set `networkPolicyManagement: Unmanaged`. |
| `agent-sandbox-namespace-no-egress` | No NetworkPolicy in the sandbox namespace may carry an egress rule. The same template also rejects GKE `FQDNNetworkPolicy`; AKS does not serve that resource. |

The policy template (`manifests/admission/sandbox-admission.yaml.tftpl`) is the
GKE module's file, copied verbatim. Some of its comments and denial messages
say "gVisor" or "GKE Sandbox pool". The rules themselves read the Kata
RuntimeClass name and the AKS pool label from the module's variables.

Why native policies instead of Kyverno:

- They add no webhook Deployment to install, keep available, and upgrade.
- They cover all namespaces. Kyverno's chart excludes `kube-system` by default.
- These rules are plain field checks.

Customers who run the AKS Azure Policy add-on (Gatekeeper) can keep it. It does
not conflict with these policies.

## Operations and caveats

- **Node upgrades end sessions.** AKS has no equivalent of Karpenter's `do-not-disrupt`, so a node-image or Kubernetes upgrade of the sandbox pool drains each node and evicts claimed sandboxes. `max_surge = 1` lets the warm pool refill on the surge node first. Upgrade the pool at low traffic. The chart's `karpenter.sh/do-not-disrupt` annotation is harmless on AKS.
- **`kubectl port-forward` does not work for Kata pods** (agent-sandbox AKS example). The agent service connects by pod IP, and `kubectl exec` works.
- **Microsoft Defender for Containers does not assess Kata pods.**
- **The sandbox namespace is apply-only.** `terraform destroy` leaves it, with the chart objects in it.
- **Some files are shared with the GKE module.** `controller.tf`, `namespace.tf`, `admission.tf`, `installer-rbac.tf` and `manifests/` are copies of `modules/agent-sandbox-gke` (verbatim, except for the cluster gate in `depends_on`). Change them in both modules until they move to a shared `modules/agent-sandbox-k8s`.
- **To bump the controller,** first bump hosted in reductoai/api (`terragrunt/modules/aws-eks-addons/manifests/agent-sandbox/patch.py`). Then carry the bump into the on-prem `patch.py` and run it (`uv run --with pyyaml python3 manifests/agent-sandbox/patch.py`, then `--check`). The on-prem `patch.py` drops only the hosted controller's EKS system-pool placement. Copy the result to both modules.

## Not yet verified

These items need a live AKS cluster (FDE-18):

1. **The custom RuntimeClass.** The custom `reducto-kata` class on handler `kata` runs pod VMs exactly as the built-in `kata-vm-isolation` does. Microsoft documents custom classes on `kata`, but this module's class has not been run.
2. **The reconcile step.** It is unknown whether `az aks update` after adding the pool is needed for the custom class, or only for the built-in one.
3. **Cilium enforcement for Kata pods.** Cilium enforces egress for Kata pod VMs exactly as for runc pods, including to the `host` entity. Kata attaches the VM to the pod's veth, where Cilium's eBPF runs. No Microsoft page states Kata + Cilium policy compatibility explicitly.
4. **The egress deny.** AKS-managed Cilium may or may not honour `egressDeny` in a CiliumClusterwideNetworkPolicy; the deny-all covers the same paths without it.
5. **The probe pod image.** `mcr.microsoft.com/azurelinux/base/core:3.0` may not contain `bash` and `timeout`. If it does not, use any image that does.
6. **Kata sizing for the sandbox workload.** This covers the overhead values, pod density per VM size, and pod start latency (Kata cold start is slower than gVisor; the warm pool hides it).
7. **Calico on AKS.** This covers pod to own-node enforcement.

## Sources

- Microsoft Learn: [Pod sandboxing with AKS](https://learn.microsoft.com/azure/aks/use-pod-sandboxing) (`KataVmIsolation`, `kata-vm-isolation`, Azure Linux, Gen2 with nested virtualization, limitations, the existing-cluster `az aks update` step)
- Microsoft Learn: [Pod sandboxing considerations](https://learn.microsoft.com/azure/aks/considerations-pod-sandboxing) (custom RuntimeClass on `handler: kata`, memory and CPU sizing, overhead table)
- Microsoft Learn: [Azure CNI powered by Cilium](https://learn.microsoft.com/azure/aks/azure-cni-powered-by-cilium) (policy enforcement, `ipBlock` cannot select node IPs, `toEntities: host` for LocalDNS, CiliumClusterwideNetworkPolicy support)
- Microsoft Learn: [Block pod access to IMDS (preview)](https://learn.microsoft.com/azure/aks/imds-restriction)
- Azure Updates AZ500268: Azure NPM for Linux nodes retires on 2028-09-30
- kubernetes-sigs/agent-sandbox: [Kata on AKS example](https://agent-sandbox.sigs.k8s.io/docs/use-cases/examples/kata-aks/)
- hashicorp/terraform-provider-azurerm 4.78.0 changelog: `KataVmIsolation` for `workload_runtime` (#32579)
- reductoai/api: `agent-service/AGENTS.md` ("On-prem", "Turn on k8s-agent-sandbox", "Smoke check"), `docs/onprem/azure_blob_storage.mdx`, `terragrunt/modules/aws-eks-addons/agent-sandbox.tf`
