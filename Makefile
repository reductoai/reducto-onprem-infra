init-dev:
	terraform init -upgrade -reconfigure -backend-config backend-config-dev

plan-dev:
	terraform plan -var-file=dev.tfvars

apply-dev:
	terraform apply -var-file=dev.tfvars

init-prod:
	terraform init -upgrade -reconfigure -backend-config backend-config-prod

plan-prod:
	terraform plan -var-file=prod.tfvars

apply-prod:
	terraform apply -var-file=prod.tfvars
