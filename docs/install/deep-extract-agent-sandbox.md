# Deep Extract agent sandbox (on-prem, AWS EKS)

This guide installs the in-cluster sandbox substrate that the Reducto agent
service uses for Deep Extract (`k8s-agent-sandbox` provider), then turns the
provider on in the Reducto Helm chart and checks the isolation.

## What Terraform installs

With `enable_agent_sandbox = true` this repo installs:

| Piece | Where | Notes |
| ----- | ----- | ----- |
| kubernetes-sigs/agent-sandbox controller v1.0.7 (`--extensions`) and its CRDs | `agent-sandbox-system` | Serves `agents.x-k8s.io/v1beta1` and `extensions.agents.x-k8s.io/v1beta1`. Two replicas on the system nodes. Same bundles as the hosted clusters (`manifests/agent-sandbox/patch.py`). |
| Controller write scope | sandbox namespaces only | A Role per sandbox namespace plus a ValidatingAdmissionPolicy that denies pod create/update anywhere else. |
| `gvisor` RuntimeClass (handler `runsc`) | cluster | Adds the sandbox node selector and toleration to every pod that uses it. |
| Sandbox nodes | `node-type=reducto-sandbox`, taint `reducto.ai/sandbox=true:NoSchedule` | Karpenter NodePool/EC2NodeClass or an EKS managed node group (`sandbox_node_provisioner`). Boot `sandbox_ami_id` with runsc baked in. |
| Node firewall | sandbox nodes | `sandbox-node-firewall` systemd unit: drops new connections from pods to their own node (kubelet, sshd, node-exporter, ...). On by default (`enable_sandbox_node_firewall`). |
| Sandbox namespace `reducto-agent-sandbox` | | Restricted Pod Security, and a `deny-all` NetworkPolicy: no ingress, **no egress at all, DNS included**. |
| VPC CNI network policy enforcement | cluster | `enableNetworkPolicy` on the `vpc-cni` add-on. |
| Kyverno policies | cluster | `require-sandbox-gvisor` (gVisor + no SA token for every sandbox pod), `require-sandbox-template-unmanaged`, `restrict-privileged-hostpath`. |

The sandbox makes no network calls. The agent service holds the model keys,
calls the LLM, and moves files in and out of the sandbox through `sandboxd`.

The Reducto Helm chart owns the rest: the ingress allow to `sandboxd`
(8080/9090, from the agent-service pods only), the Role/RoleBinding of the
agent service, the SandboxTemplate/SandboxWarmPool, and the token Secrets.

## Prerequisites

- A sandbox AMI: AL2023 EKS-optimized for the cluster's Kubernetes version,
  with `runsc` and `containerd-shim-runsc-v1` baked in (`sandbox_runsc_path`,
  default `/usr/local/bin/runsc`). Nothing is downloaded at node boot.
- The Reducto images in your registry, including `<tag>-agent-sandbox`
  (the sandbox image) and the agent-service image, and a Reducto chart version
  that has `agentService.sandboxProviders.k8sAgentSandbox`.
- A model provider key (OpenAI) in a Secret in the `reducto` namespace.
- AWS: no extra IAM. The worker signs the presigned S3 URLs and deletes the
  staged objects with the Reducto IRSA role, which already has `s3:*` on the
  job bucket. The agent service uses no AWS API. Gateway VPC endpoints for S3
  are tracked separately (reducto-onprem-infra PR #22).

## 1. Terraform

Add to `terraform.tfvars`:

```hcl
enable_kyverno       = true
enable_agent_sandbox = true
sandbox_ami_id       = "ami-0123456789abcdef0"

# Optional:
# sandbox_node_provisioner   = "managed_node_group"   # default "karpenter"
# sandbox_managed_node_group = { instance_types = ["m7i.2xlarge"], min_size = 1, max_size = 4, desired_size = 1 }
# enable_sandbox_node_firewall = true                 # default
```

Then:

```bash
terraform init
terraform plan
terraform apply
```

`terraform output agent_sandbox_namespaces` lists the sandbox namespaces
(default `["reducto-agent-sandbox"]`).

Turning on `enableNetworkPolicy` enforces every NetworkPolicy already in the
cluster, not only the sandbox ones. Review existing policies first.

### Check the substrate

```bash
kubectl get runtimeclass gvisor
kubectl get crd sandboxes.agents.x-k8s.io sandboxclaims.extensions.agents.x-k8s.io \
  sandboxtemplates.extensions.agents.x-k8s.io sandboxwarmpools.extensions.agents.x-k8s.io
kubectl api-versions | grep agents.x-k8s.io        # both groups at v1beta1
kubectl -n agent-sandbox-system get deploy agent-sandbox-controller   # 2/2 ready
kubectl -n reducto-agent-sandbox get networkpolicy deny-all -o yaml   # policyTypes Ingress+Egress, no rules
kubectl get ns reducto-agent-sandbox --show-labels                    # pod-security enforce=restricted
kubectl get clusterpolicy require-sandbox-gvisor require-sandbox-template-unmanaged
```

## 2. Reducto Helm chart values

With `enable_agent_sandbox = true`, Terraform already passes the
cluster-derived values to the `reducto` release (`reducto-helm-release.tf`),
and the release waits for the sandbox substrate:

```yaml
agentService:
  sandboxProviders:
    k8sAgentSandbox:
      namespace: reducto-agent-sandbox
      runtimeClassName: gvisor
      networkPolicy:
        createDenyAll: false   # Terraform owns the deny-all
  tuning:
    io:
      # The service fetches inputs and uploads outputs only on these hosts:
      # the job bucket's virtual-hosted S3 host, which the worker signs
      # (us-east-1 also gets <bucket>.s3.amazonaws.com).
      url_hosts: ["<bucket>.s3.<region>.amazonaws.com"]
```

If you install the chart yourself instead (`enable_reducto = false`), set
those values too. The bucket is `aws_s3_bucket.reducto_storage`
(`terraform state show aws_s3_bucket.reducto_storage`).

Turn the service on with a values file passed through
`reducto_extra_values_files` (it is layered last):

```yaml
agentService:
  enabled: true
  providerKeys:
    existingSecret: <secret with the model key>
    keys:
      openai: OPENAI_API_KEY
  sandboxProviders:
    k8sAgentSandbox:
      enabled: true
      image:
        repository: <registry>/<reducto image repo>   # empty: image.repository
        pullSecrets: [<pull secret in reducto-agent-sandbox>]
      warmPools:
        pi: { size: 2 }
```

If the image needs a pull Secret, create it in `reducto-agent-sandbox` before
the install.

Run `terraform apply`. The agent-service pods run a start check: the CRDs,
each warm pool, their RBAC, and a NetworkPolicy that denies all egress with no
policy in the namespace that has an egress rule. A failed check stops the pod
start; read the pod log.

### Turn on the profile (one deploy later)

After the agent-service pods from step 2 are running, set the profile to the
warm pool and deploy again:

```yaml
agentService:
  tuning:
    profiles:
      deep_extract:
        sandbox: { provider: k8s-agent-sandbox, image: pi, app: reducto-pi-sandbox, network: blocked }
```

The tuning ConfigMap has one name, so an old pod that restarts during the
first rollout would read the new profile without the env of step 2.

## 3. Verify

### A Ready gVisor sandbox from the warm pool

```bash
kubectl -n reducto-agent-sandbox get sandboxwarmpool,sandboxtemplate
kubectl -n reducto-agent-sandbox get pods -o wide   # Running, on node-type=reducto-sandbox nodes
kubectl -n reducto-agent-sandbox get pods \
  -o custom-columns=NAME:.metadata.name,RUNTIME:.spec.runtimeClassName,READY:.status.containerStatuses[0].ready
```

### Smoke check (end to end)

```bash
kubectl -n reducto exec deploy/reducto-reducto-agent-service -- \
  node dist/smoke.mjs --profile deep_extract
```

It makes one model call through the agent service, claims a sandbox from the
warm pool, runs `echo` in it, checks that an outbound TCP connect from the
sandbox fails, and deletes the claim. A connect that the policy drops ends at
the probe's 30 s limit. Exit code 0 is a pass.

### Isolation probe

The deny-all and the node firewall apply to every pod in the namespace, so a
throwaway pod there sees what a sandbox sees. Every check below must fail
(time out or not resolve):

```bash
kubectl -n reducto-agent-sandbox apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: isolation-probe
spec:
  runtimeClassName: gvisor
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
  - name: probe
    image: busybox:1.36   # use a mirror if Docker Hub is not reachable
    command: ["sleep", "600"]
    env:
    - name: NODE_IP
      valueFrom: { fieldRef: { fieldPath: status.hostIP } }
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: { drop: ["ALL"] }
EOF
kubectl -n reducto-agent-sandbox wait --for=condition=Ready pod/isolation-probe

probe() { kubectl -n reducto-agent-sandbox exec isolation-probe -- sh -c "$1" \
  && echo "FAIL (reachable): $1" || echo "ok (blocked): $1"; }
probe 'nslookup -timeout=3 amazonaws.com'                              # DNS
probe 'nc -w 5 1.1.1.1 443 </dev/null'                                 # internet
probe 'nc -w 5 $KUBERNETES_SERVICE_HOST 443 </dev/null'                # K8s API
probe 'wget -T 5 -q -O- http://169.254.169.254/latest/meta-data/'      # IMDS
probe 'nc -w 5 $NODE_IP 10250 </dev/null'                              # kubelet on own node
probe 'nc -w 5 $NODE_IP 22 </dev/null'                                 # sshd on own node

kubectl -n reducto-agent-sandbox delete pod isolation-probe
```

## Troubleshooting

- Agent-service pod fails the start check with "no NetworkPolicy that denies
  all egress": the `deny-all` policy is missing from the sandbox namespace, or
  the chart namespace does not match `agent_sandbox_namespaces`.
- "has a NetworkPolicy with an egress rule": remove the extra policy. Set
  `createDenyAll: false` only because Terraform owns the deny-all; any policy
  with an egress rule in the namespace stops the service.
- Pods admitted but stuck `ContainerCreating` with a runtime handler error:
  the node did not register `runsc`. Check the sandbox node's user data and
  `journalctl -u nodeadm-config`; the AMI must have runsc at
  `sandbox_runsc_path`.
- Kyverno denies a sandbox pod: it is missing `runtimeClassName: gvisor` or
  `automountServiceAccountToken: false`, or a SandboxTemplate is not
  `networkPolicyManagement: Unmanaged`.
