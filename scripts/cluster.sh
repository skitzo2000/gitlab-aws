#!/usr/bin/env bash
# Cluster lifecycle for the GitLab demo platform — usable from a laptop or a
# CI runner. Subcommands:
#
#   cluster.sh status    instance states + URLs
#   cluster.sh stop      park the cluster (~$0.02/hr: EBS + EIP; data/cert survive)
#   cluster.sh start     resume it (everything self-heals; ~3 min to URLs answering)
#   cluster.sh deploy    create or update: terraform apply + ansible playbook
#   cluster.sh destroy   full teardown (releases the EIP, wipes data + cert;
#                        next deploy re-issues Let's Encrypt — 5/week limit)
#
# Configuration (env overrides): PROJECT, REGION — must match terraform.tfvars.
# AWS credentials: whatever the aws CLI / Terraform already use.
set -euo pipefail

PROJECT="${PROJECT:-gitlab-demo}"
REGION="${REGION:-us-east-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Native aws CLI when present (CI runners), docker fallback otherwise (laptops).
AWS_BIN="$(type -P aws || true)"
aws() {
  if [ -n "$AWS_BIN" ]; then
    "$AWS_BIN" --region "$REGION" "$@"
  else
    docker run --rm -v "$HOME/.aws:/root/.aws:ro" amazon/aws-cli --region "$REGION" "$@"
  fi
}

instance_ids() { # $1 = instance-state filter (running/stopped/...)
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=$1" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

cmd_status() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].{name:Tags[?Key==`Name`]|[0].Value,state:State.Name,ip:PublicIpAddress}' \
    --output table
  (cd "$REPO_ROOT/terraform" && terraform output gitlab_url 2>/dev/null) || true
}

cmd_stop() {
  local ids
  ids=$(instance_ids running)
  [ -n "$ids" ] || { echo "nothing running"; exit 0; }
  # shellcheck disable=SC2086
  aws ec2 stop-instances --instance-ids $ids --query 'StoppingInstances[].InstanceId' --output text
  echo "stopping — idle cost ~\$0.02/hr; data, cert, EIP and URLs all survive"
}

cmd_start() {
  local ids
  ids=$(instance_ids stopped)
  [ -n "$ids" ] || { echo "nothing stopped"; exit 0; }
  # shellcheck disable=SC2086
  aws ec2 start-instances --instance-ids $ids --query 'StartingInstances[].InstanceId' --output text
  # shellcheck disable=SC2086
  aws ec2 wait instance-running --instance-ids $ids
  echo "instances running — GitLab needs ~3 min to answer. If your IP changed,"
  echo "run 'terraform apply' in terraform/ to refresh admin_cidr (public URLs work regardless)."
  cmd_status
}

cmd_deploy() { # create from nothing OR update in place — both idempotent
  (cd "$REPO_ROOT/terraform" && terraform init -input=false && terraform apply -input=false -auto-approve)
  (cd "$REPO_ROOT/ansible" && ansible-playbook site.yml)
  (cd "$REPO_ROOT/terraform" && terraform output gitlab_url)
}

cmd_destroy() {
  if [ "${1:-}" != "--yes" ]; then
    echo "Full teardown: releases the EIP, wipes GitLab data AND the Let's Encrypt"
    echo "cert (re-issue on next deploy counts against LE's 5/week limit)."
    read -r -p "Type '$PROJECT' to confirm: " reply
    [ "$reply" = "$PROJECT" ] || { echo "aborted"; exit 1; }
  fi
  (cd "$REPO_ROOT/terraform" && terraform destroy -input=false -auto-approve)
}

case "${1:-}" in
  status)  cmd_status ;;
  stop)    cmd_stop ;;
  start)   cmd_start ;;
  deploy)  cmd_deploy ;;
  destroy) shift; cmd_destroy "$@" ;;
  *) grep '^#   cluster.sh' "$0" | sed 's/^#   //'; exit 1 ;;
esac
