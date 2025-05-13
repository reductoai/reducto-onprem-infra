# One-time setup steps

* We did not use Cloudflare+LetsEncrypt. We manually created a cert in ACM and used that instead. Sampo did this.
* On a fresh AWS account, we had to run `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com` before Karpenter would autoscale.
* The initial `terraform apply` is likely to fail on applying helm/karpenter changes. Just re-run it.

Create the files: `dev.tfvars` and `prod.tfvars`. These should contain the following:

```
reducto_helm_repo_username = "ram@sema4.ai"
reducto_helm_repo_password = "..."
reducto_host = "reducto.sema4ai.dev"
openai_api_key = "..."
```

## Choosing environments

We use the partial configuration of backend to support multiple environments.

Before running a `terraform plan|apply`, run the corresponding `make init-dev` or `make init-prod` to
reconfigure your local Terraform project for the dev/prod environment.

Then, the corresponding make targets `make plan-dev`/`make plan-prod` or `make apply-dev`/`make apply-prod`
