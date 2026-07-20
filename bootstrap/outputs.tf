output "deployer_role_arn" {
  description = "IAM role the GitHub workflow assumes via OIDC."
  value       = aws_iam_role.deployer.arn
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "github_setup" {
  description = "Run these once (gh CLI, from the repo root) to wire the repository to AWS."
  value       = <<-EOT

    gh variable set AWS_ROLE_ARN    --body "${aws_iam_role.deployer.arn}"
    gh variable set AWS_REGION      --body "${var.region}"
    gh variable set TF_STATE_BUCKET --body "${aws_s3_bucket.state.bucket}"
    gh variable set TF_LOCK_TABLE   --body "${aws_dynamodb_table.lock.name}"

    # Optional — real domain + HTTPS (walkthrough STEP 2):
    # gh variable set GITLAB_DOMAIN    --body "demo.example.com"
    # gh variable set ROUTE53_ZONE_ID  --body "${var.route53_zone_id != "" ? var.route53_zone_id : "Z..."}"

    # Optional — Keycloak SSO (STEP 3):
    # gh variable set KEYCLOAK_ISSUER_URL --body "https://keycloak.example.com/realms/<realm>"
    # gh variable set KEYCLOAK_CLIENT_ID  --body "gitlab"
    # gh secret  set KEYCLOAK_CLIENT_SECRET
  EOT
}
