variable "project" {
  description = "Name prefix for all resources."
  type        = string
  default     = "gitlab-demo"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH (22) and the k3s API (6443). Narrow this to your own IP (e.g. 1.2.3.4/32) for anything beyond a throwaway demo."
  type        = string
  default     = "0.0.0.0/0"
}

variable "cp_instance_type" {
  description = "Control-plane instance type. Tainted NoSchedule, so it only runs k3s itself — small and cheap."
  type        = string
  default     = "t3a.small"
}

variable "worker_instance_type" {
  description = "Worker instance type. One worker hosts GitLab omnibus (~5 GiB), the other hosts the runner + CI job pods."
  type        = string
  default     = "t3a.large"
}

variable "worker_count" {
  description = "Number of k3s workers."
  type        = number
  default     = 2
}

variable "use_spot" {
  description = "Run all nodes as persistent spot instances (interruption behavior = stop). Set false for on-demand."
  type        = bool
  default     = true
}

variable "cp_volume_gb" {
  description = "Root EBS volume size (GiB) for the control plane."
  type        = number
  default     = 20
}

variable "worker_volume_gb" {
  description = "Root EBS volume size (GiB) for workers (GitLab data, registry blobs, container images)."
  type        = number
  default     = 40
}

variable "gitlab_image" {
  description = "GitLab omnibus (CE) container image."
  type        = string
  default     = "gitlab/gitlab-ce:18.5.0-ce.0"
}

variable "runner_image" {
  description = "GitLab Runner container image."
  type        = string
  default     = "gitlab/gitlab-runner:alpine-v18.5.0"
}

variable "vpc_cidr" {
  description = "VPC CIDR. Deliberately outside 10.42.0.0/16 / 10.43.0.0/16, which k3s uses for pods/services."
  type        = string
  default     = "10.60.0.0/16"
}

variable "subnet_cidr" {
  description = "Public subnet CIDR."
  type        = string
  default     = "10.60.1.0/24"
}

variable "domain" {
  description = "Real domain for the platform (e.g. demo.example.com). GitLab becomes gitlab.<domain>. Leave empty to use free sslip.io wildcard DNS (gitlab.<eip>.sslip.io)."
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID for var.domain. If set (and domain is set), Terraform creates the A record to the EIP itself. Leave empty if your DNS is hosted elsewhere — the dns_record output tells you what to create."
  type        = string
  default     = ""
}

variable "cp_private_ip" {
  description = "Static private IP for the control plane, so workers can join without ordering games."
  type        = string
  default     = "10.60.1.10"
}
