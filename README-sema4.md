# Tooling, access and dev. machine setup required

- Python + awscli + terraform + make
  - python=3.11.11 (or later)
  - uv=0.8.4
  - make=4.4.1
  - awscli=2.28.1
  - terraform=1.12.2 
- Permissions to access `sema4ai-backend-dev` and/or `sema4ai-backend-prod` in [AWS](https://d-9067b8f409.awsapps.com/start/#/?tab=accounts)

Setup awscli profiles & login:
In `~/.aws/config` add profiles:
```
[profile reducto-dev]
region = us-east-1
sso_start_url = https://d-9067b8f409.awsapps.com/start/#
sso_region = us-east-1
sso_account_id = 247681840182
sso_role_name = NonProductionAccountAdmin
output = json

[profile reducto-prod]
region = us-east-1
sso_start_url = https://d-9067b8f409.awsapps.com/start/#
sso_region = us-east-1
sso_account_id = 004078808828
sso_role_name = ProductionAccountAdmin
output = json
```

- `aws configure list-profiles`
- `aws sso login --profile reducto-dev`
- Set AWS profile variable for terrafrom to knonw it: `export AWS_PROFILE=reducto-dev` OR `SET AWS_PROFILE=reducto-dev`
- Test the API key and check reducto version: 
  - DEV:  `curl -s -H "X-API-Key: <SEMA4AI_API_KEY>" https://backend.sema4ai.dev/reducto/version`
  - PROD:  `curl -s -H "X-API-Key: <SEMA4AI_API_KEY>" https://backend.sema4.ai/reducto/version`

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
reducto_nlb_cert_arn = "..."
```

## Choosing environments

We use the partial configuration of backend to support multiple environments.

Before running a `terraform plan|apply`, run the corresponding `make init-dev` or `make init-prod` to
reconfigure your local Terraform project for the dev/prod environment.

Then, the corresponding make targets `make plan-dev`/`make plan-prod` or `make apply-dev`/`make apply-prod`.



# Create Sema4.ai API keys for customers

1. Goto: https://d-9067b8f409.awsapps.com/start/#/?tab=accounts
   1. If you have permissions you can see the below, if not then not
2. `sema4ai-backend-prod` > `ProductionAccountAdmin`
3. [API gateway is in us-east-1](https://us-east-1.console.aws.amazon.com/apigateway/main/apis/myq53b7pg7/resources?api=myq53b7pg7&region=us-east-1)
4. Add [API Key](https://us-east-1.console.aws.amazon.com/apigateway/main/api-keys?api=unselected&region=us-east-1) with customer name
5. Select usage plan according to customer type: `ISV` / `Customers`
   1. `Internal Sema4 Users` for S4 internals