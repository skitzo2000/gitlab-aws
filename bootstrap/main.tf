# --- GitHub OIDC federation -------------------------------------------------
# The runner presents a short-lived GitHub-signed token; AWS trusts it only
# for this repo + branch. No access keys exist anywhere.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.existing_oidc_provider_arn == "" ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

locals {
  oidc_provider_arn = var.existing_oidc_provider_arn != "" ? var.existing_oidc_provider_arn : aws_iam_openid_connect_provider.github[0].arn
}

# --- Remote Terraform state (shared by CI and laptops) ----------------------

resource "random_id" "state" {
  byte_length = 4
}

resource "aws_s3_bucket" "state" {
  bucket = "${var.project}-tfstate-${random_id.state.hex}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = "${var.project}-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# --- The deployer role (what the GitHub runner becomes) ---------------------
# Minimal by construction: EC2 locked to one region, state bucket + lock
# table, optionally record-changes on ONE Route 53 zone. No IAM actions at
# all — the platform creates no IAM resources, and the role can't escalate.

resource "aws_iam_role" "deployer" {
  name = "${var.project}-deployer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/${var.branch}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deployer" {
  name = "deploy-${var.project}"
  role = aws_iam_role.deployer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "Ec2RegionScoped"
          Effect   = "Allow"
          Action   = "ec2:*"
          Resource = "*"
          Condition = {
            StringEquals = { "aws:RequestedRegion" = var.region }
          }
        },
        {
          Sid      = "StateBucketList"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = aws_s3_bucket.state.arn
        },
        {
          Sid      = "StateObjects"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = "${aws_s3_bucket.state.arn}/*"
        },
        {
          Sid      = "StateLock"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
          Resource = aws_dynamodb_table.lock.arn
        },
      ],
      var.route53_zone_id != "" ? [
        {
          Sid      = "DnsZone"
          Effect   = "Allow"
          Action   = ["route53:GetHostedZone", "route53:ListResourceRecordSets", "route53:ChangeResourceRecordSets"]
          Resource = "arn:aws:route53:::hostedzone/${var.route53_zone_id}"
        },
        {
          Sid      = "DnsChangeStatus"
          Effect   = "Allow"
          Action   = ["route53:GetChange"]
          Resource = "arn:aws:route53:::change/*"
        },
      ] : []
    )
  })
}

# --- Point the main stack (local runs) at the remote state ------------------
# *_override.tf merges into the main stack's terraform block; gitignored.
# CI writes the identical file from repo variables.

resource "local_file" "backend_override" {
  filename        = "${path.module}/../terraform/backend_override.tf"
  file_permission = "0644"

  content = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.state.bucket}"
        key            = "${var.project}/terraform.tfstate"
        region         = "${var.region}"
        dynamodb_table = "${aws_dynamodb_table.lock.name}"
      }
    }
  EOT
}
