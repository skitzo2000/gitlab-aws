# =============================================================================
# GitLab Demo Platform — configuration reference
# =============================================================================
# This file is the single source of truth for every knob in the platform.
# Values flow from here (overridden via terraform.tfvars) into the AWS
# resources AND into the generated Ansible inventory — nothing is configured
# anywhere else.
#
# Don't edit defaults here: copy terraform.tfvars.example to terraform.tfvars
# (gitignored) and follow its step-by-step walkthrough.
#
# Sections:
#   1. Basics            — project name, region
#   2. Access            — who can reach SSH / the k3s API
#   3. DNS & HTTPS       — real domain, Route 53, Let's Encrypt
#   4. SSO               — the external amnesia-labs Keycloak
#   5. Sizing & cost     — instance types, spot, volumes
#   6. Software versions — GitLab / runner images
#   7. Network           — VPC layout (rarely needs touching)

# --- 1. Basics ---------------------------------------------------------------

variable "project" {
  description = "Name prefix for all AWS resources (also names the SSH key file)."
  type        = string
  default     = "gitlab-demo"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

# --- 2. Access ---------------------------------------------------------------

variable "admin_cidr" {
  description = <<-EOT
    CIDR allowed to reach SSH (22) and the k3s API (6443).
    The default is wide open — narrow it to your own IP (e.g. 1.2.3.4/32)
    for anything beyond a throwaway demo. GitLab's public endpoints
    (80/443/5050/2222) are open to the world regardless; this only gates
    the admin plane.
  EOT
  type        = string
  default     = "0.0.0.0/0"
}

variable "ci_cidr" {
  description = <<-EOT
    Additional CIDR granted the same admin access as admin_cidr, set by the
    deploy workflow to the runner's own IP. It exists so CI doesn't have to
    overwrite admin_cidr: the runner needs SSH for the Ansible phase, but a
    pipeline run must not lock your laptop out of SSH/kubectl until the next
    local apply. Empty (the default) adds nothing.
  EOT
  type        = string
  default     = ""
}

# --- 3. DNS & HTTPS ----------------------------------------------------------
# Leaving `domain` empty gives a zero-setup HTTP demo at
# gitlab.<eip>.sslip.io. Setting it switches the whole platform to
# gitlab.<domain> AND enables HTTPS via GitLab's built-in Let's Encrypt
# (issued against the DNS record, auto-renewed, also covers the registry).

variable "domain" {
  description = "Real domain for the platform (e.g. demo.example.com). GitLab becomes https://gitlab.<domain>. Empty = HTTP on sslip.io."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for var.domain. If set, Terraform creates/owns the A record to the EIP. Empty = Cloudflare (below) or create the record at your DNS host yourself (see the dns_record output) BEFORE running the playbook."
  type        = string
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for var.domain (dashboard -> zone Overview). If set, Terraform creates/owns the A record to the EIP — always DNS-only (grey cloud): proxying breaks Let's Encrypt HTTP-01 and the non-HTTP ports (registry 5050, git-ssh 2222). Mutually exclusive with route53_zone_id."
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit on that zone (dash.cloudflare.com/profile/api-tokens). Required when cloudflare_zone_id is set."
  type        = string
  default     = ""
  sensitive   = true
}

variable "cert_bucket" {
  description = <<-EOT
    S3 bucket holding the durable copy of the Let's Encrypt certificate
    (normally the Terraform state bucket — see bootstrap's state_bucket
    output). The live cert sits on a local-path PVC, i.e. one worker's root
    volume; without this, replacing that worker spends one of Let's Encrypt's
    five weekly issuances for the hostname. Empty disables persistence and
    restores the old behaviour of issuing on every rebuild.
  EOT
  type        = string
  default     = ""
}

variable "letsencrypt_email" {
  description = "Contact email for Let's Encrypt registration. Empty = admin@<domain>."
  type        = string
  default     = ""
}

# --- 4. SSO (external amnesia-labs Keycloak) ---------------------------------
# Nothing Keycloak-related is deployed here; GitLab federates to the
# existing instance over OIDC. Requires the DNS/HTTPS setup above, since
# Keycloak redirects the browser back to GitLab's public URL.

variable "keycloak_issuer_url" {
  description = "OIDC issuer URL of the Keycloak realm, e.g. https://keycloak.amnesia-labs.com/realms/<realm>. Empty disables SSO entirely."
  type        = string
  default     = ""
}

variable "keycloak_client_id" {
  description = "Client ID of the confidential client registered in Keycloak for this GitLab."
  type        = string
  default     = "gitlab"
}

variable "keycloak_client_secret" {
  description = "Secret of that Keycloak client (standard/authorization-code flow)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "keycloak_label" {
  description = "Text on the SSO button on GitLab's login page."
  type        = string
  default     = "Amnesia Labs SSO"
}

# --- 5. Sizing & cost --------------------------------------------------------

variable "use_spot" {
  description = "false (default) = on-demand: launches always succeed, stop/start is fully under your control, no reclaim surprises. true = persistent spot (~70% off compute, but launches can stall on capacity and AWS can stop instances under you)."
  type        = bool
  default     = false
}

variable "cp_instance_type" {
  description = "Control-plane instance type. Tainted NoSchedule (runs only k3s itself), so small and cheap."
  type        = string
  default     = "t3a.small"
}

variable "worker_instance_type" {
  description = "Worker instance type. One worker hosts GitLab omnibus (~5 GiB RAM), the other the runner + CI job pods. Non-burstable (m6a) by design: fresh burstable (t*) instances start with zero CPU credits and throttle to 30%/vCPU exactly when the first GitLab boot needs CPU most (20+ min boots). t* workers get standard credits — expect slow first boots."
  type        = string
  default     = "m6a.large"
}

variable "worker_count" {
  description = "Number of k3s workers."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 1
    error_message = "At least one worker is required — the control plane is tainted and runs no workloads."
  }
}

variable "cp_volume_gb" {
  description = "Root EBS volume (GiB) for the control plane."
  type        = number
  default     = 20
}

variable "worker_volume_gb" {
  description = "Root EBS volume (GiB) for workers (GitLab data, registry blobs, container images)."
  type        = number
  default     = 40
}

# --- 6. Software versions ----------------------------------------------------

variable "gitlab_image" {
  description = "GitLab omnibus (CE) container image."
  type        = string
  default     = "gitlab/gitlab-ce:18.5.0-ce.0"
}

variable "runner_image" {
  description = "GitLab Runner container image. Keep its minor version in step with GitLab."
  type        = string
  default     = "gitlab/gitlab-runner:alpine-v18.5.0"
}

# --- 7. Network (rarely needs touching) --------------------------------------
# The defaults deliberately avoid 10.42.0.0/16 and 10.43.0.0/16, which k3s
# uses internally for pods and services.

variable "vpc_cidr" {
  description = "VPC CIDR."
  type        = string
  default     = "10.60.0.0/16"
}

variable "subnet_cidr" {
  description = "Public subnet CIDR (control plane + EIP live here)."
  type        = string
  default     = "10.60.1.0/24"
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR (workers live here, no public IPs; egress via the cp acting as NAT)."
  type        = string
  default     = "10.60.2.0/24"
}

variable "cp_private_ip" {
  description = "Static private IP for the control plane (must be inside subnet_cidr), so workers can join without boot-order games."
  type        = string
  default     = "10.60.1.10"
}
