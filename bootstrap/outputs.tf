output "deployer_role_arn" {
  description = "IAM role the GitHub workflow assumes via OIDC."
  value       = aws_iam_role.deployer.arn
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "github_setup" {
  description = "Run these once (gh CLI, from the repo root) to wire the repository to AWS."
  value       = <<-EOT

    # The workflow builds its whole configuration from these — it never reads
    # terraform.tfvars (gitignored, laptop-only). Anything you override there
    # and DON'T set here silently reverts to its variables.tf default on the
    # next pipeline apply. Keep the two in step.

    gh variable set AWS_ROLE_ARN    --body "${aws_iam_role.deployer.arn}"
    gh variable set AWS_REGION      --body "${var.region}"
    gh variable set TF_STATE_BUCKET --body "${aws_s3_bucket.state.bucket}"
    gh variable set ADMIN_CIDR      --body "1.2.3.4/32"   # your IP; CI adds its own via ci_cidr

    # Optional — real domain + HTTPS (walkthrough STEP 2). Note: the gitlab.
    # prefix is added for you, so this is the ZONE apex, not the final host.
    # gh variable set GITLAB_DOMAIN      --body "example.com"
    # gh variable set LETSENCRYPT_EMAIL  --body "admin@example.com"
    #
    # ...with DNS at Cloudflare (the token needs Zone:DNS:Edit on that zone):
    # gh variable set CLOUDFLARE_ZONE_ID --body "<zone id>"
    # gh secret   set CLOUDFLARE_API_TOKEN
    #
    # ...or at Route 53 instead (re-run bootstrap with route53_zone_id set,
    # so the deployer role gets record-change rights on the zone):
    # gh variable set ROUTE53_ZONE_ID    --body "${var.route53_zone_id != "" ? var.route53_zone_id : "Z..."}"

    # Optional — Keycloak SSO (STEP 3; requires the domain above):
    # gh variable set KEYCLOAK_ISSUER_URL --body "https://auth.example.com/realms/<realm>"
    # gh variable set KEYCLOAK_CLIENT_ID  --body "gitlab"
    # gh secret   set KEYCLOAK_CLIENT_SECRET
  EOT
}
