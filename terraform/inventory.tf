# Terraform provisions, Ansible configures: these files hand off the
# infrastructure facts to the playbook. Both are generated (gitignored) and
# refreshed on every apply.

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../ansible/inventory/hosts.ini"
  file_permission = "0644"

  content = <<-EOT
    [control_plane]
    cp ansible_host=${aws_eip.cp.public_ip}

    [workers]
    ${join("\n", [for i, w in aws_instance.worker : "worker-${i + 1} ansible_host=${w.public_ip}"])}
  EOT

  depends_on = [aws_eip_association.cp]
}

resource "local_sensitive_file" "ansible_group_vars" {
  filename        = "${path.module}/../ansible/inventory/group_vars/all.yml"
  file_permission = "0600"

  content = yamlencode({
    ansible_user                 = "ubuntu"
    ansible_ssh_private_key_file = abspath(local_sensitive_file.ssh_key.filename)

    gitlab_host          = local.gitlab_host
    gitlab_url           = "http://${local.gitlab_host}"
    gitlab_image         = var.gitlab_image
    runner_image         = var.runner_image
    gitlab_root_password = random_password.gitlab_root.result

    k3s_token     = random_password.k3s_token.result
    cp_public_ip  = aws_eip.cp.public_ip
    cp_private_ip = var.cp_private_ip
  })
}
