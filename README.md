# Reducto 

Terraform project to install Reducto on EKS.

## Overview

Project creates an EKS cluster along with required dependencies and installs Reducto Helm chart in `reducto` namespace.

S3 Bucket, RDS Instance required by Reducto are also created.

During bootstrapping of the cluster both public and private endpoints are enabled.
Public endpoint can be restricted for the duration of bootstrapping by setting `cluster_endpoint_public_access_cidrs = [ CIDR ]`

Cluster's public endpoint access can be restricted or removed after provisioning: 
by setting:
1. Remove public endpoint `cluster_endpoint_public_access = false`.
2. Restrict public endpoint `cluster_endpoint_public_access_cidrs = [ vpc_cidr ]`

All worklods are only created in private subnet, including LB for ingress-nginx.

### Step 1 | Terraform State

To use a bucket for Terraform state, create a bucket and update `backend.tf`.

OR you can skip this to quickly run Terraform plan and apply with locally managed `terraform.tfstate` state file for testing purposes.

### Step 2 | Configuration

Make sure `variables.tf` has configuration that you desire, like restricting EKS public endpoint or avoiding VPC CIDR collisions or database instance type.

Create `terraform.tfvars` with following contents:

```
reducto_helm_repo_username = "todo"
reducto_helm_repo_password = "todo"
reducto_host = "reducto.example.com"
cloudflare_api_token = "token"
```

### Step 3 | Provisioning

Apply Terraform

```
terraform init
terraform plan
terraform apply
```

### Step 4 | Configure Cloudflare DNS

Cloudflare DNS is used to obtain TLS certificate from Letsencrypt via [cert-manager using dns01 solver](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/).

Check the private LB hostname created by cluster for Nginx Ingress Controller and use it to create CNAME DNS record on Cloudflare to point to value provided in `reducto_host`.

### Step 5 | Access Reducto

Make sure all workloads are healthy.

Reducto will be accessible on private LB via hostname configured in `reducto_host`

For checking Reducto service health without public endpoint: Port forward your local 4567 to Reducto service:

```
kubectl port-forward service/reducto-reducto-http 4567:80 -n reducto

# Access Reducto
curl localhost:4567
```

### Step 6 | Restrict or remove EKS public endpoint

Cluster is created with both public and private endpoint enabled to bootstrap cluster. 

After complete bootstrap, set `cluster_endpoint_public_access = false` and/or set `cluster_endpoint_public_access_cidrs = [ vpc_cidr ]`, and apply Terraform.


## Notes on Destroy

To `terraform destroy`, comment out the `lifecycle` block in `reducto-bucket.tf` and remove deletion protection from DB.

You can remove deletion protection by setting `var.db_deletion_protection = false` and `terraform apply`.

`terraform destroy` may not finish because VPC will contain resources created outside of Terraform managment:
- NLB for nginx controller created by AWS load balancer controller
- EKS Nodes from autoscaling by Karpenter
- Bucket not empty

So along side `terraform destroy` you'll need to manually delete above resources from AWS console.
