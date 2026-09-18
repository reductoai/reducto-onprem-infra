---
name: eks-sandbox-cluster
description: Create or tear down a throwaway EKS cluster from this repo for testing/verification (e.g. proving out new Terraform before it ships). Use when asked to "spin up a test/sandbox cluster", "create a new EKS cluster to verify X", or "tear down/destroy the sandbox cluster".
---

# EKS sandbox cluster

Wraps this repo's normal Terraform lifecycle (see README "Common Operations"
and "Notes on Destroy") for spinning up and tearing down a **throwaway**
EKS cluster — one used to verify new infrastructure code actually works
before it's considered done, not a long-lived environment.

## Naming convention (always follow this)

Sandbox cluster names are `<person>-<MM>-<DD>`, e.g. `lijie-09-17` for
lijie@reducto.ai on 2026-09-17:

- `<person>` = the local part of the operator's git email (`git config
  user.email`), lowercased.
- `<MM>-<DD>` = today's month and day.

**Refuse to proceed** — for both create and destroy — if the resolved or
caller-supplied `cluster_name` contains `staging`, `prod`, or `dev` (case
insensitive). Real fleet clusters are named like `staging-2`/`prod-2`/`dev-2`;
this guard exists specifically to prevent ever accidentally targeting one of
those with `terraform destroy`. If asked to operate on a cluster whose name
looks like a real fleet cluster, stop and ask the human instead.

Pick the AWS region/account the same way you would for any other change in
this repo — ask if it's not already established in the conversation. Don't
default to colocating with a real fleet cluster's region without confirming
that's actually wanted.

## Create

1. Confirm (or derive) `cluster_name` per the naming convention above, and
   the target AWS region/profile.
2. Write or update a gitignored `<cluster_name>.tfvars` in the repo root with
   at least `cluster_name`, `region`, and whatever the rest of the task needs
   (e.g. `enable_agent_sandbox = true`, `enable_reducto = false` for a
   substrate-only verification run). `reducto_helm_repo_username/password`,
   `reducto_host`, `cloudflare_api_token`, and `slack_webhook_url` have no
   defaults and must be set even when unused — placeholder values are fine
   when `enable_reducto = false` (nothing depends on them working).
3. `terraform init`
4. `terraform plan -var-file=<cluster_name>.tfvars -out=<cluster_name>.tfplan`
   and show the plan to the user before applying.
5. Only run `terraform apply <cluster_name>.tfplan` once the user's own
   message contains the word "apply" (this repo has a hook enforcing that —
   don't try to route around it).
6. `aws eks update-kubeconfig --region <region> --name <cluster_name> --alias
   <cluster_name>` so `kubectl --context <cluster_name> ...` works.

## Destroy

Tears down everything created above, including the manual cleanup this
repo's Terraform can't do for you (see README "Notes on Destroy").

1. Comment out the `lifecycle { prevent_destroy = true }` block in
   `reducto-bucket.tf` (temporarily — restore it after destroy completes in
   step 5, so the repo's default safety is intact for everyone else).
2. Make sure `db_deletion_protection = false` is set for this cluster (either
   already in its tfvars, or apply that change now).
3. Only once the user's message contains the word "apply" or "destroy":
   `terraform destroy -var-file=<cluster_name>.tfvars`.
4. `terraform destroy` will likely not finish on its own — clean up
   resources Karpenter/AWS created outside Terraform's management:
   - The NLB created by the ingress-nginx controller (find it in the AWS
     console/CLI by the cluster's VPC or the `kubernetes.io/cluster/<cluster_name>`
     tag, then delete it).
   - Any EC2 instances Karpenter provisioned that are still running.
   - Empty the S3 bucket (`aws s3 rm s3://<bucket> --recursive`) before the
     bucket delete will succeed.
   Re-run `terraform destroy` after clearing those.
5. Revert the temporary edit from step 1 (`prevent_destroy = true` restored).
6. Delete the cluster's kubeconfig context: `kubectl config delete-context
   <cluster_name>` (and `delete-cluster`/`delete-user` for the matching
   entries `aws eks update-kubeconfig` added).
7. Remove the `<cluster_name>.tfvars` and any local `<cluster_name>.tfplan`
   file — they're gitignored, so this is just local cleanup.

## Notes

- This skill assumes local Terraform state (this repo's `backend.tf` is
  commented out by default). If a remote backend has since been configured,
  make sure the AWS profile/session you're using can actually reach it before
  running any of the above.
- Never skip the "apply"/"destroy" keyword gate by rephrasing the command to
  avoid the hook — if the user hasn't said the word, ask them to confirm
  explicitly instead.
