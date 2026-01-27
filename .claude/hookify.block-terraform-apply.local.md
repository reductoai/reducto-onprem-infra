---
name: require-explicit-apply
enabled: true
event: bash
pattern: terraform\s+apply
action: block
conditions:
  - field: user_context
    operator: not_contains
    pattern: apply
---

🚫 **Terraform apply blocked - explicit request required**

You configured Claude Code to ONLY run `terraform apply` when you explicitly use the word "apply" in your request.

**To allow this terraform apply:**
Your message must contain the word "apply" (e.g., "apply these changes", "run terraform apply", "apply the infrastructure")

**Current issue:**
Your recent message did not contain the word "apply", so this operation is blocked.

**Safe alternatives I can suggest:**
- `terraform init` - Initialize Terraform
- `terraform plan` - Preview changes
- `terraform validate` - Validate configuration

**User's last message likely was something like:**
"update the infrastructure" or "change the config" without mentioning apply.
