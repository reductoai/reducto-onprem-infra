# Deep Extract agent sandbox on GKE

> **Preview. Not yet qualified (FDE-18).** No one has applied this module to a real cluster yet.
> Run every check in [Verify](#verify) on the target cluster before you turn on a
> `k8s-agent-sandbox` profile, and read [Caveats and unverified items](#caveats-and-unverified-items) first.

The Reducto chart runs Deep Extract sessions in `k8s-agent-sandbox` pods (agent-service + kubernetes-sigs/agent-sandbox).
The chart does not install the cluster parts of that path. On GKE, the Terraform module
[`modules/agent-sandbox-gke`](../../modules/agent-sandbox-gke) installs them on an **existing GKE Standard cluster**.
[`examples/gke`](../../examples/gke) is a root module that calls it.

## Layout

```text
modules/agent-sandbox-gke/        self-contained: one module per cloud (modules/agent-sandbox-<cloud>/)
  cluster.tf                      reads the cluster; postconditions refuse a cluster that cannot isolate the sandbox
  node-pool.tf                    GKE Sandbox (gVisor) node pool + least-privilege node service account
  firewall.tf                     VPC deny rule: sandbox pod range -> every VM in the network
  namespace.tf                    sandbox namespace (PSS restricted) + zero-egress deny-all
  controller.tf                   agent-sandbox v1.0.7 controller (--extensions), CRDs, controller RBAC narrowing, its VAP
  admission.tf                    ValidatingAdmissionPolicies for the sandbox namespace
  installer-rbac.tf               optional RBAC for the identity that runs `helm install`
  workload-identity.tf            worker KSA -> GSA: GCS object read/write/delete + signBlob on itself
  manifests/agent-sandbox/        vendored upstream bundles + patch.py (same release and patches as hosted)
  manifests/admission/            VAP template
examples/gke/                     example root (providers, module call, tfvars example)
```

The AWS root module in the repository root is unchanged. Each cloud gets its own module under `modules/agent-sandbox-<cloud>/`
(AKS: `modules/agent-sandbox-aks/`), plus an example root under `examples/<cloud>/`. The Kubernetes-only files (`controller.tf`,
`namespace.tf`, `admission.tf`, `installer-rbac.tf`, and `manifests/`) do not depend on the cloud. Move them to a shared
`modules/agent-sandbox-k8s/` once a second cloud module uses them.

## What it creates

| Object | Where | Why |
|---|---|---|
| Node pool `reducto-sandbox` | GKE | `sandbox_config { type = "GVISOR" }`, `COS_CONTAINERD`, Shielded nodes (secure boot + integrity monitoring), `workload_metadata_config.mode = GKE_METADATA`, `disable-legacy-endpoints`, kubelet read-only port off, label `node-type=reducto-sandbox`, taint `reducto.ai/sandbox=true:NoSchedule`, surge upgrades (1 up, 0 down), autoscaling |
| Service account `<pool>-node` | IAM | Node identity with `roles/container.defaultNodeServiceAccount` only (plus `node_service_account_extra_roles`), and the `gke-default` scopes |
| Firewall `<pool>-pods-deny-<hash>` | VPC | Deny all traffic from the pool's dedicated pod range to every VM in the network (priority 100). Logging on |
| Namespace `reducto-agent-sandbox` | k8s | PSS `restricted` (enforce, audit, warn) |
| NetworkPolicy `deny-all` | sandbox ns | Every pod, Ingress + Egress, no rules. No DNS |
| Namespace `agent-sandbox-system` + controller | k8s | kubernetes-sigs/agent-sandbox **v1.0.7** (image pinned by digest), `--extensions`, 2 replicas, PDB, `system-cluster-critical` plus the ResourceQuota that GKE requires for that class outside `kube-system` |
| CRDs | k8s | `agents.x-k8s.io/v1beta1` (Sandbox), `extensions.agents.x-k8s.io/v1beta1` (SandboxTemplate, SandboxClaim, SandboxWarmPool) |
| Role/RoleBinding `agent-sandbox-controller-workloads` | sandbox ns, controller ns | Pod/PVC/Service/NetworkPolicy write only in the sandbox namespace, and the lease only in its own namespace. The ClusterRoles are read-only on those resources (patch.py) |
| VAP `restrict-controller-pod-create` | cluster | The controller SA can create or modify pods only in the sandbox namespace |
| VAP `agent-sandbox-pod-isolation` | sandbox ns + any pod labeled `agents.x-k8s.io/sandbox-name-hash` | `runtimeClassName: gvisor`, `automountServiceAccountToken: false`, `nodeSelector node-type=reducto-sandbox`, no host namespaces |
| VAP `agent-sandbox-template-unmanaged` | sandbox ns | SandboxTemplates must set `networkPolicyManagement: Unmanaged` |
| VAP `agent-sandbox-namespace-no-egress` | sandbox ns | Denies a NetworkPolicy with an egress rule, and any GKE `FQDNNetworkPolicy` |
| GSA `reducto-worker` + bindings | IAM | `roles/storage.objectUser` on the bucket, `roles/iam.serviceAccountTokenCreator` on itself (signBlob for signed URLs), `roles/iam.workloadIdentityUser` for `<reducto ns>/<release>-reducto` |

The module does **not** create a RuntimeClass, because GKE Sandbox provides `gvisor`. It also does not create the cluster,
the network, the bucket, or anything that the chart renders.

## Prerequisites

Cluster (the `cluster.tf` postconditions fail the plan when one is missing):

- GKE **Standard**, control plane **1.30 or later**, because ValidatingAdmissionPolicy v1 is GA from 1.30.
- **GKE Dataplane V2** (`datapath_provider = ADVANCED_DATAPATH`). It always enforces NetworkPolicy. Calico (legacy dataplane)
  passes only with `allow_calico_network_policy = true`, and only after the own-node probe below fails closed on that cluster.
- **Workload Identity Federation for GKE** on, with `workload_pool = <project>.svc.id.goog`.
- The GKE-managed **Agent Sandbox add-on is off** (`addons_config.agent_sandbox_config`). It serves `v1alpha1`, but the chart
  needs the `v1beta1` API of the OSS controller.
- **`enable_cilium_clusterwide_network_policy` is off**. A cluster-wide Cilium policy could open egress in a way that the agent
  service's start check cannot see.

Cluster facts that the module does not check:

- A **VPC-native** cluster in the **same project as its network**, if `sandbox_pod_range.create = true`. In a Shared VPC service
  project, add the secondary range to the host subnet yourself and set `create = false`. Routes-based clusters do not support
  per-pool pod ranges.
- At least one **non-sandbox node pool** with nodes, for GKE system workloads and the controller. The node pool of the Reducto
  workers must run `GKE_METADATA` for Workload Identity.
- No ip-masq-agent config that SNATs pod traffic to in-VPC destinations, because the VPC firewall then sees the node IP and not
  the pod range.
- An existing GCS bucket for the worker.

Operator:

- Terraform >= 1.5, `gcloud`, and `kubectl`, with network access to the control plane.
- GCP roles: Kubernetes Engine Admin (node pool), Compute Security Admin (firewall), Service Account Admin, Project IAM Admin
  (node SA role), Storage Admin on the bucket (or `storage.buckets.setIamPolicy`). If `sandbox_pod_range.create = true`, also
  Compute Network Admin on the subnet.
- Kubernetes: cluster-admin for the apply (CRDs, ClusterRoles, VAPs).

## Apply

```sh
cp -r examples/gke ~/reducto-agent-sandbox && cd ~/reducto-agent-sandbox
# Edit the module source to point at this repo, e.g.
#   source = "git::https://github.com/reductoai/reducto-onprem-infra.git//modules/agent-sandbox-gke?ref=<tag>"
cp terraform.tfvars.example terraform.tfvars   # fill in project, cluster, pod range, bucket
gcloud auth application-default login
terraform init
terraform plan
terraform apply
terraform output -json k8s_agent_sandbox_values
terraform output -json worker_service_account_annotations
```

`sandbox_pod_range` is a pod CIDR that only the sandbox pool uses. The VPC firewall names the sandbox pods by that range. It
is immutable on the pool. Size it at one /24 for each node at the default 110 max pods. Without a range, the plan fails unless
you set `accept_no_vpc_firewall = true`.

## Chart values

Merge the Terraform outputs into the Reducto values file. Example with the module defaults:

```yaml
serviceAccount:
  create: true
  annotations:
    iam.gke.io/gcp-service-account: reducto-worker@<project>.iam.gserviceaccount.com   # worker_service_account_annotations

agentService:
  enabled: true
  providerRegion: <region of src/super_agent/model_providers.json>
  sandboxProviders:
    k8sAgentSandbox:
      enabled: true
      namespace: reducto-agent-sandbox
      runtimeClassName: gvisor
      allowRunc: false
      nodeSelector:
        node-type: reducto-sandbox
        sandbox.gke.io/runtime: gvisor
      tolerations:
        - { key: reducto.ai/sandbox, operator: Equal, value: "true", effect: NoSchedule }
        - { key: sandbox.gke.io/runtime, operator: Equal, value: gvisor, effect: NoSchedule }
      networkPolicy:
        enabled: true          # the chart's ingress allow (agent-service -> sandboxd 8080/9090)
        createDenyAll: false   # Terraform owns deny-all
      image:
        repository: <customer registry>/reducto   # <tag>-agent-sandbox
        pullSecrets: [<pull secret in reducto-agent-sandbox>]
      warmPools:
        pi: { size: 2 }
  tuning:
    profiles:
      deep_extract:
        sandbox: { provider: k8s-agent-sandbox, image: pi, app: deep-extract }
```

For the rest of the on-prem values (provider keys, `callerWorkers`, the rollout order of `enabled` first and the profile one
deploy later), see `agent-service/AGENTS.md`, "On-prem" and "Turn on k8s-agent-sandbox", in reductoai/api. Leave
`idlePodsDoNotDisrupt` at its default. On GKE it has no effect, because it sets a Karpenter annotation (see the caveats).

If the installer is not cluster-admin, set `installer_subjects` to give it the sandbox-namespace rights and the RuntimeClass
read that the chart's `lookup` and RBAC need. Its rights in the release namespace are your own.

## Verify

1. The cluster parts:

   ```sh
   kubectl get runtimeclass gvisor
   kubectl get nodes -l node-type=reducto-sandbox -L sandbox.gke.io/runtime
   kubectl api-versions | grep -E '^(extensions\.)?agents\.x-k8s\.io/v1beta1$'      # two lines
   kubectl -n agent-sandbox-system rollout status deploy/agent-sandbox-controller
   kubectl get validatingadmissionpolicy | grep -E 'agent-sandbox|restrict-controller'
   kubectl -n reducto-agent-sandbox get networkpolicy deny-all -o yaml               # no egress key
   ```

2. Admission denies a pod that is not sandboxed, and an egress allow:

   ```sh
   kubectl -n reducto-agent-sandbox run not-sandboxed --image=busybox:1.36 --restart=Never -- true
   # expect: denied by ValidatingAdmissionPolicy 'agent-sandbox-pod-isolation'
   kubectl -n reducto-agent-sandbox apply -f - <<'EOF'
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata: { name: allow-egress-test }
   spec: { podSelector: {}, policyTypes: [Egress], egress: [{}] }
   EOF
   # expect: denied by ValidatingAdmissionPolicy 'agent-sandbox-namespace-no-egress'
   ```

3. **Pod to its own node, and to another node.** The smoke script only probes a public IP, so run this probe once for each
   cluster. Every line must print `closed` (each connect waits up to 3 s):

   ```sh
   OTHER_NODE_IP=$(kubectl get nodes -l '!node-type' -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
   kubectl -n reducto-agent-sandbox apply -f - <<EOF
   apiVersion: v1
   kind: Pod
   metadata: { name: node-probe }
   spec:
     runtimeClassName: gvisor
     automountServiceAccountToken: false
     restartPolicy: Never
     nodeSelector: { node-type: reducto-sandbox }
     tolerations:
       - { key: reducto.ai/sandbox, operator: Equal, value: "true", effect: NoSchedule }
       - { key: sandbox.gke.io/runtime, operator: Equal, value: gvisor, effect: NoSchedule }
     securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: { type: RuntimeDefault } }
     containers:
       - name: probe
         image: busybox:1.36
         securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
         env:
           - { name: HOST_IP, valueFrom: { fieldRef: { fieldPath: status.hostIP } } }
         command: ["sh", "-c"]
         args:
           - |
             for t in \$HOST_IP:10250 \$HOST_IP:22 \$HOST_IP:988 \$HOST_IP:10256 \$HOST_IP:30000 \
                      169.254.169.254:80 169.254.169.252:988 ${OTHER_NODE_IP}:10250 1.1.1.1:443; do
               if nc -w 3 \${t%:*} \${t#*:} </dev/null 2>/dev/null; then echo "OPEN   \$t"; else echo "closed \$t"; fi
             done
   EOF
   kubectl -n reducto-agent-sandbox wait --for=jsonpath='{.status.phase}'=Succeeded pod/node-probe --timeout=120s
   kubectl -n reducto-agent-sandbox logs node-probe
   kubectl -n reducto-agent-sandbox delete pod node-probe
   ```

   An `OPEN` line means the cluster is not fit for the sandbox: do not turn on a profile. If `$HOST_IP` shows `OPEN`, the
   NetworkPolicy dataplane is not closing the path from a pod to its own node (see the caveats).

4. After the chart deploy, the agent service starts only when its start check passes (warm pools, claims, deny-all, no egress
   rule), then the smoke script runs end to end (gateway call, sandbox create, `echo`, egress probe, terminate):

   ```sh
   kubectl -n reducto-agent-sandbox get sandboxwarmpool
   kubectl -n <reducto ns> logs deploy/<release>-reducto-agent-service | grep sandbox.providers
   kubectl -n <reducto ns> exec deploy/<release>-reducto-agent-service -- node dist/smoke.mjs --profile deep_extract
   ```

5. Workload Identity for the worker:

   ```sh
   kubectl -n <reducto ns> get sa <release>-reducto -o jsonpath='{.metadata.annotations.iam\.gke\.io/gcp-service-account}'
   gcloud iam service-accounts get-iam-policy reducto-worker@<project>.iam.gserviceaccount.com
   # expect: roles/iam.workloadIdentityUser for serviceAccount:<project>.svc.id.goog[<reducto ns>/<release>-reducto]
   #         roles/iam.serviceAccountTokenCreator for serviceAccount:reducto-worker@...
   ```

   Then run one Deep Extract job. It stages its inputs in the bucket and hands the agent service signed URLs, so a failed
   sign or upload shows up in the worker log.

## Design notes

**Node firewall (pod to its own node).** On EKS the NetworkPolicy agent always allows a pod to reach its own node, so hosted
adds an iptables DROP to the sandbox node user data. GKE has no supported node user data. A host-firewall DaemonSet would
be privileged, and its iptables rule may not see the traffic that Dataplane V2 routes in eBPF. So this module uses only
controls that GKE supports:

1. The namespace `deny-all` enforced by Dataplane V2 (Cilium). In Cilium the node is a policy entity (`host`), so egress to it
   should need an explicit allow. GKE documents that a Dataplane V2 cluster with an egress deny must explicitly allow `169.254.169.254` for the metadata
   server, so that node-local endpoint is blocked by the deny. Nothing in GKE's documentation states this for the node IP
   itself, so probe 3 is the check.
2. A VPC firewall deny from the sandbox pod range to every VM in the network, at priority 100. It overrides the
   GKE-created `gke-<cluster>-*-all` allow (priority 1000), which GKE widens to every pod range. The rule is independent of
   Kubernetes. It covers the other nodes, their pods, and other VMs, but not the pod's own node, because that traffic never
   leaves the VM.
3. Defense in depth on the node itself. gVisor puts a user-space kernel between the code and the host. The node runs
   `GKE_METADATA`, so a pod never sees the node's credentials or `kube-env`. The kubelet read-only port is off. Sandbox pods
   mount no ServiceAccount token and run as uid 1000 under PSS `restricted`.

**Admission: ValidatingAdmissionPolicy, not Kyverno.** Hosted uses Kyverno for `require-sandbox-gvisor` and
`require-sandbox-template-unmanaged`. Each rule is a field check that CEL expresses directly, and VAP:

- runs in the API server, so there is no webhook to be down and no extra chart to install, upgrade, or patch;
- has no namespace exclusions (Kyverno's defaults skip `kube-system`, which is why the controller's own backstop was already a
  VAP);
- is GA from Kubernetes 1.30.

Every policy is `failurePolicy: Fail` with no `matchConditions`, so an error can only deny the objects its binding selects. The
module does not port hosted's cluster-wide `restrict-privileged-hostpath` (PSS baseline everywhere). That is a cluster policy
of the customer's, and the sandbox namespace enforces `restricted` itself.

**Controller.** The release, upstream asset sha256s, image digest, and RBAC narrowing are the same as hosted (api
`terragrunt/modules/aws-eks-addons/manifests/agent-sandbox/patch.py`). The one change is that the controller is not pinned
to an EKS `node-type: system` pool. The sandbox pool taint keeps it off sandbox nodes. Regenerate with
`uv run --with pyyaml python3 modules/agent-sandbox-gke/manifests/agent-sandbox/patch.py`, and check for drift with `--check`.

## Caveats and unverified items

- **Not run on a cluster.** `terraform validate` has not run against the google provider schema, and nothing has been applied.
  The first install must run all of [Verify](#verify).
- **Pod to its own node on Dataplane V2.** The module expects Cilium's deny-all to drop it, but GKE does not document this.
  Probe 3 decides. If the probe finds the path open, the fix is not in this module yet: a node-level rule would need a
  privileged DaemonSet, checked against Dataplane V2's eBPF datapath.
- **Calico (legacy dataplane)** is untested. It is refused unless `allow_calico_network_policy = true`.
- **Node upgrades and autoscaling end sessions.** GKE auto-upgrade drains sandbox nodes, and a claimed sandbox pod does not
  survive a drain. The chart's `karpenter.sh/do-not-disrupt` annotation means nothing to the GKE cluster autoscaler or to
  upgrades. Use a maintenance window or exclusion for the cluster. The cluster autoscaler should not scale down a node that
  holds pods owned by a custom controller (Sandbox), but that is unverified for GKE. Expect idle warm-pool pods to keep nodes
  up.
- **VPC firewall scope.** It needs pod traffic to keep its pod source IP inside the VPC (the GKE default for RFC 1918
  destinations). It does not cover Google-managed endpoints that are not VMs in the network (control plane, Cloud SQL or
  Memorystore over peering or PSC). The NetworkPolicy covers those.
- **`agents.x-k8s.io/sandbox-name-hash`** is the controller's pod label in v1.0.7 (`controllers/sandbox_controller.go`). The
  label binding of `agent-sandbox-pod-isolation` depends on it. The namespace binding does not.
- **GKE `gvisor` RuntimeClass scheduling.** The module assumes that the RuntimeClass adds the `sandbox.gke.io/runtime`
  toleration. The chart values set it explicitly anyway.
- **signBlob grant.** The GCS docs grant Token Creator to an attached service account at the project level. The module grants
  it only on the worker GSA itself, which is narrower and covers `signBlob` on that SA. Confirm that the worker's signing
  library signs as its own GSA (by email) and not as another account.

## References

- GKE Sandbox, how-to (COS image, label and taint `sandbox.gke.io/runtime`, `gvisor` RuntimeClass, the non-sandbox pool):
  https://cloud.google.com/kubernetes-engine/docs/how-to/sandbox-pods
- GKE Sandbox, concepts (limits, metadata access, Workload Identity):
  https://cloud.google.com/kubernetes-engine/docs/concepts/sandbox-pods
- Network policy on GKE (Dataplane V2 always enforces it; metadata server egress on Dataplane V2):
  https://cloud.google.com/kubernetes-engine/docs/how-to/network-policy
- Agent Sandbox on GKE, OSS install v1.0.6, `v1beta1` CRDs: https://cloud.google.com/kubernetes-engine/docs/how-to/how-install-agent-sandbox
- GKE add-on serves `v1alpha1`, OSS serves `v1beta1`: https://agent-sandbox.sigs.k8s.io/docs/use-cases/anthropic-managed-agents/
- Node pool pod ranges (VPC-native, Shared VPC, GKE-updated firewall rule): https://cloud.google.com/kubernetes-engine/docs/how-to/multi-pod-cidr
- Signed URLs with `signBlob` and Service Account Token Creator: https://cloud.google.com/storage/docs/access-control/signing-urls-with-helpers
- Workload Identity Federation for GKE: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
- ValidatingAdmissionPolicy: https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Terraform google provider (`sandbox_config.type` GA in 7.22.0, `agent_sandbox_config` GA in 7.39.0):
  https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_node_pool
- Chart requirements: reductoai/api `agent-service/AGENTS.md`, "On-prem"
