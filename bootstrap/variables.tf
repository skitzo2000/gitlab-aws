# Run-once bootstrap: creates everything the CI pipeline needs, so the
# GitHub runner itself holds NO stored AWS credentials — it assumes an IAM
# role via GitHub's OIDC federation, restricted to this repo's main branch.
#
# Run this ONCE with your own (admin) AWS credentials:
#   cd bootstrap && terraform init && terraform apply
# Then follow the github_setup output. Bootstrap state stays local
# (gitignored) — it never changes after this.

variable "project" {
  description = "Name prefix, matching the main stack."
  type        = string
  default     = "gitlab-demo"
}

variable "region" {
  description = "AWS region — must match the main stack's region; the deployer role is locked to it."
  type        = string
  default     = "us-east-1"
}

variable "github_repo" {
  description = "GitHub repository (owner/name) allowed to assume the deployer role."
  type        = string
  default     = "skitzo2000/gitlab-aws"
}

variable "branch" {
  description = "Branch whose workflow runs may assume the role."
  type        = string
  default     = "main"
}

variable "route53_zone_id" {
  description = "If the platform manages DNS in Route 53, the zone ID — the deployer role gets record-change rights on THIS zone only. Empty = no Route 53 permissions."
  type        = string
  default     = ""
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing token.actions.githubusercontent.com OIDC provider, if your account already has one (AWS allows only one per URL). Empty = create it."
  type        = string
  default     = ""
}
