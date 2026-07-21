# One security group for all nodes. Cluster-internal traffic (k3s API,
# flannel VXLAN, kubelet, etc.) is allowed via the self-rule; only the demo's
# public endpoints are exposed outward.

locals {
  # The admin plane is reachable from your IP AND, during a pipeline run, the
  # runner's. compact() drops ci_cidr when unset (local applies); distinct()
  # guards the case where they're the same address.
  admin_cidrs = distinct(compact([var.admin_cidr, var.ci_cidr]))
}

resource "aws_security_group" "cluster" {
  name        = "${var.project}-cluster"
  description = "GitLab demo k3s cluster"
  vpc_id      = aws_vpc.this.id

  # All traffic between cluster nodes.
  ingress {
    description = "intra-cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description = "SSH (admin)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = local.admin_cidrs
  }

  ingress {
    description = "k3s API / kubectl (admin)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = local.admin_cidrs
  }

  # GitLab web UI. Open to the world so CI job pods can also reach the
  # external URL (their traffic hairpins through the IGW with a node public
  # IP as source).
  ingress {
    description = "GitLab HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "GitLab HTTPS (Lets Encrypt HTTP-01 uses port 80 above)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "GitLab container registry"
    from_port   = 5050
    to_port     = 5050
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "GitLab SSH (git over ssh)"
    from_port   = 2222
    to_port     = 2222
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-cluster"
  }
}
