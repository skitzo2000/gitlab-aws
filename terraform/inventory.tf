# Terraform provisions, Ansible configures: these files hand off the
# infrastructure facts to the playbook. Both are generated (gitignored) and
# refreshed on every apply.

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.ini"
  file_permission = "0644"

  # Workers are private: addressed by (stable) private IP, reached by
  # tunneling through the cp. ProxyCommand rather than ProxyJump so the jump
  # hop gets the same key/options without touching ~/.ssh/config.
  content = <<-EOT
    [control_plane]
    cp ansible_host=${aws_eip.cp.public_ip}

    [workers]
    ${join("\n", [for i, w in aws_instance.worker : "worker-${i + 1} ansible_host=${w.private_ip}"])}

    [workers:vars]
    ansible_ssh_common_args=-o ProxyCommand="ssh -W %h:%p -i ${abspath(local_sensitive_file.ssh_key.filename)} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null admin@${aws_eip.cp.public_ip}"
  EOT

  depends_on = [aws_eip_association.cp]
}

resource "local_sensitive_file" "ansible_group_vars" {
  filename        = "${path.module}/../ansible/inventory/group_vars/all.yml"
  file_permission = "0600"

  content = yamlencode({
    ansible_user                 = "admin" # Debian cloud images' default user
    ansible_ssh_private_key_file = abspath(local_sensitive_file.ssh_key.filename)

    gitlab_host          = local.gitlab_host
    gitlab_url           = "${local.gitlab_scheme}://${local.gitlab_host}"
    gitlab_https         = local.gitlab_https
    letsencrypt_email    = local.letsencrypt_email
    gitlab_image         = var.gitlab_image
    runner_image         = var.runner_image
    gitlab_root_password = random_password.gitlab_root.result

    keycloak_enabled       = var.keycloak_issuer_url != ""
    keycloak_issuer_url    = var.keycloak_issuer_url
    keycloak_client_id     = var.keycloak_client_id
    keycloak_client_secret = var.keycloak_client_secret
    keycloak_label         = var.keycloak_label

    k3s_token     = random_password.k3s_token.result
    cp_public_ip  = aws_eip.cp.public_ip
    cp_private_ip = var.cp_private_ip
    vpc_cidr      = var.vpc_cidr # masquerade scope for the nat_gateway role
  })

  # Config coherence checks — every value funnels through this file on its
  # way to Ansible, so misconfigurations are caught here at plan time with
  # a pointer to the right step in terraform.tfvars.example.
  lifecycle {
    precondition {
      condition     = var.route53_zone_id == "" || var.domain != ""
      error_message = "route53_zone_id is set but domain is empty — set domain too (terraform.tfvars.example STEP 2)."
    }

    precondition {
      condition     = var.cloudflare_zone_id == "" || var.domain != ""
      error_message = "cloudflare_zone_id is set but domain is empty — set domain too (terraform.tfvars.example STEP 2)."
    }

    precondition {
      condition     = !(var.route53_zone_id != "" && var.cloudflare_zone_id != "")
      error_message = "route53_zone_id and cloudflare_zone_id are both set — exactly one DNS host can own the record (terraform.tfvars.example STEP 2)."
    }

    precondition {
      condition     = var.cloudflare_zone_id == "" || var.cloudflare_api_token != ""
      error_message = "cloudflare_zone_id is set but cloudflare_api_token is empty — create a token with Zone:DNS:Edit and set it (terraform.tfvars.example STEP 2)."
    }

    precondition {
      condition     = var.keycloak_issuer_url == "" || var.domain != ""
      error_message = "SSO requires the real-domain/HTTPS setup: Keycloak redirects back to GitLab's public URL. Set domain (STEP 2) before enabling Keycloak (STEP 3)."
    }

    precondition {
      condition     = var.keycloak_issuer_url == "" || var.keycloak_client_secret != ""
      error_message = "keycloak_issuer_url is set but keycloak_client_secret is empty — register the confidential client in Keycloak and set its secret (terraform.tfvars.example STEP 3)."
    }

    precondition {
      condition     = var.keycloak_issuer_url == "" || can(regex("^https://", var.keycloak_issuer_url))
      error_message = "keycloak_issuer_url must be an https:// realm URL, e.g. https://keycloak.amnesia-labs.com/realms/<realm>."
    }
  }
}
