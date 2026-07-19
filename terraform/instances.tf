locals {
  # One hostname drives everything (GitLab external_url, registry, runner
  # config, outputs). With a real domain set, it's gitlab.<domain>; otherwise
  # sslip.io resolves gitlab.<ip-with-dashes>.sslip.io to <ip> — free
  # wildcard DNS with zero setup, stable because the EIP is stable.
  gitlab_host = var.domain != "" ? "gitlab.${var.domain}" : "gitlab.${replace(aws_eip.cp.public_ip, ".", "-")}.sslip.io"

  # HTTPS rides on the real domain: omnibus' built-in Let's Encrypt does
  # HTTP-01 against the DNS record we manage. sslip.io mode stays HTTP
  # (LE won't issue for sslip hostnames in practice).
  gitlab_https      = var.domain != ""
  gitlab_scheme     = local.gitlab_https ? "https" : "http"
  letsencrypt_email = var.letsencrypt_email != "" ? var.letsencrypt_email : (var.domain != "" ? "admin@${var.domain}" : "")
}

# Official Debian cloud image — minimal surface area vs. Ubuntu (no snapd,
# no motd phone-home, smaller default package set). Default SSH user: admin.
data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Debian

  filter {
    name   = "name"
    values = ["debian-13-amd64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- SSH key pair (generated; private key written next to the module) ------

resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  key_name   = "${var.project}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "ssh_key" {
  content         = tls_private_key.ssh.private_key_openssh
  filename        = "${path.module}/${var.project}-key.pem"
  file_permission = "0600"
}

# --- Secrets ---------------------------------------------------------------

resource "random_password" "gitlab_root" {
  length  = 20
  special = false
}

resource "random_password" "k3s_token" {
  length  = 32
  special = false
}

# --- Elastic IP ------------------------------------------------------------

resource "aws_eip" "cp" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-cp"
  }
}

resource "aws_eip_association" "cp" {
  instance_id   = aws_instance.cp.id
  allocation_id = aws_eip.cp.id
}

# --- Control plane ---------------------------------------------------------

# Ansible taints this node node-role.kubernetes.io/control-plane:NoSchedule
# at k3s install time, so no workloads ever land here — that's what lets it
# be a t3a.small. (k3s' svclb daemonset tolerates the taint, so ports
# 80/5050/2222 still answer on this node and forward to the GitLab pod on
# the workers — which is why the EIP lives here.)
resource "aws_instance" "cp" {
  ami                    = data.aws_ami.debian.id
  instance_type          = var.cp_instance_type
  subnet_id              = aws_subnet.public.id
  private_ip             = var.cp_private_ip
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.this.key_name

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.cp_volume_gb
  }

  tags = {
    Name = "${var.project}-cp"
    Role = "control-plane"
  }
}

# --- Workers ---------------------------------------------------------------

resource "aws_instance" "worker" {
  count = var.worker_count

  ami                    = data.aws_ami.debian.id
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.this.key_name

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
      }
    }
  }

  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.worker_volume_gb
  }

  tags = {
    Name = "${var.project}-worker-${count.index + 1}"
    Role = "worker"
  }
}
