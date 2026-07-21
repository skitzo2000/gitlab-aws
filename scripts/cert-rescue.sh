#!/usr/bin/env bash
# cert-rescue.sh — recover the Let's Encrypt certificate from a worker whose
# instance can no longer start, and seed it into the S3 store that the
# gitlab_cert Ansible role reads on every deploy.
#
# One-shot, for the migration onto S3-backed certs. Once a deploy has run with
# cert_bucket set, the role keeps S3 current by itself and this script has no
# further use.
#
# Why it exists: the cert lives in /etc/gitlab/ssl on a local-path PVC, i.e. a
# directory on one worker's ROOT volume. If that instance won't boot (stranded
# spot capacity, say), the only way to the bytes is to attach its volume to a
# machine that IS running. The control plane is that machine.
#
# Safe to re-run: the volume is mounted read-only and put back where it came
# from on exit, including on failure.
#
#   scripts/cert-rescue.sh <gitlab-host>
#
# Env: PROJECT, REGION (must match terraform.tfvars), CERT_BUCKET.
set -euo pipefail

HOST="${1:-}"
[ -n "$HOST" ] || { sed -n '2,20p' "$0"; exit 2; }

PROJECT="${PROJECT:-gitlab-demo}"
REGION="${REGION:-us-east-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_BUCKET="${CERT_BUCKET:-$(terraform -chdir="$REPO_ROOT/terraform" output -raw cert_bucket 2>/dev/null || true)}"
[ -n "$CERT_BUCKET" ] || { echo "error: set CERT_BUCKET (the Terraform state bucket)" >&2; exit 2; }

KEY="$REPO_ROOT/terraform/$PROJECT-key.pem"
DEVICE=/dev/sdf # Nitro renames this; we locate the real node by size below

AWS_BIN="$(type -P aws || true)"
aws() {
  if [ -n "$AWS_BIN" ]; then "$AWS_BIN" --region "$REGION" "$@"
  else docker run --rm -v "$HOME/.aws:/root/.aws:ro" amazon/aws-cli --region "$REGION" "$@"; fi
}

instance_id() { # $1 = Name tag
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=pending,running,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

CP_ID="$(instance_id "$PROJECT-cp")"
CP_IP="$(aws ec2 describe-instances --instance-ids "$CP_ID" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text)"
[ -n "$CP_ID" ] && [ -n "$CP_IP" ] || { echo "error: control plane not found or has no public IP" >&2; exit 1; }

ssh_cp() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=15 admin@"$CP_IP" "$@"; }

ssh_cp true || { echo "error: cannot SSH to the control plane at $CP_IP" >&2; exit 1; }

# The PVC could be on either worker — try each until the cert turns up.
for n in 1 2; do
  WORKER="$PROJECT-worker-$n"
  W_ID="$(instance_id "$WORKER")"
  [ -n "$W_ID" ] || continue

  VOL="$(aws ec2 describe-instances --instance-ids "$W_ID" \
    --query 'Reservations[].Instances[].BlockDeviceMappings[0].Ebs.VolumeId' --output text)"
  ORIG_DEV="$(aws ec2 describe-instances --instance-ids "$W_ID" \
    --query 'Reservations[].Instances[].RootDeviceName' --output text)"
  STATE="$(aws ec2 describe-instances --instance-ids "$W_ID" \
    --query 'Reservations[].Instances[].State.Name' --output text)"
  [ "$STATE" = "stopped" ] || { echo "$WORKER is $STATE, not stopped — skipping"; continue; }

  echo "==> inspecting $WORKER ($VOL)"

  # Always hand the volume back, whatever happens next.
  restore_volume() {
    ssh_cp "sudo umount /mnt/rescue 2>/dev/null || true" || true
    aws ec2 detach-volume --volume-id "$VOL" >/dev/null 2>&1 || true
    aws ec2 wait volume-available --volume-id "$VOL" 2>/dev/null || true
    aws ec2 attach-volume --volume-id "$VOL" --instance-id "$W_ID" \
      --device "$ORIG_DEV" >/dev/null 2>&1 || \
      echo "WARNING: could not reattach $VOL to $W_ID as $ORIG_DEV — do it by hand" >&2
  }
  trap restore_volume EXIT

  aws ec2 detach-volume --volume-id "$VOL" >/dev/null
  aws ec2 wait volume-available --volume-id "$VOL"
  aws ec2 attach-volume --volume-id "$VOL" --instance-id "$CP_ID" --device "$DEVICE" >/dev/null
  aws ec2 wait volume-in-use --volume-id "$VOL"
  sleep 5

  # Read-only, and by partition rather than whole disk. nouuid keeps the
  # kernel from tripping over a filesystem UUID identical to the cp's own.
  FOUND="$(ssh_cp "bash -s" <<REMOTE || true
set -e
sudo mkdir -p /mnt/rescue
dev=\$(lsblk -rno NAME,SIZE,TYPE | awk '\$3=="part" && \$2=="40G" {print \$1; exit}')
[ -n "\$dev" ] || dev=\$(lsblk -rno NAME,TYPE | awk '\$2=="part"' | tail -1 | cut -d' ' -f1)
sudo mount -o ro,nouuid "/dev/\$dev" /mnt/rescue 2>/dev/null || sudo mount -o ro "/dev/\$dev" /mnt/rescue
src=\$(sudo find /mnt/rescue/var/lib/rancher/k3s/storage -path '*/config/ssl/$HOST.crt' 2>/dev/null | head -1)
[ -n "\$src" ] || { echo "NOTFOUND"; exit 0; }
sudo cat "\$src" > /tmp/$HOST.crt
sudo cat "\${src%.crt}.key" > /tmp/$HOST.key
echo FOUND
REMOTE
)"

  if [ "${FOUND%%$'\n'*}" != "FOUND" ] && ! grep -q FOUND <<<"$FOUND"; then
    echo "    no certificate for $HOST on this volume"
    restore_volume; trap - EXIT; continue
  fi

  echo "==> found the certificate — copying it out"
  scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    admin@"$CP_IP":"/tmp/$HOST.crt" admin@"$CP_IP":"/tmp/$HOST.key" /tmp/ 2>/dev/null || {
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      admin@"$CP_IP":"/tmp/$HOST.{crt,key}" /tmp/; }
  ssh_cp "rm -f /tmp/$HOST.crt /tmp/$HOST.key"

  openssl x509 -in "/tmp/$HOST.crt" -noout -checkend 0 \
    || { echo "error: recovered certificate is expired" >&2; exit 1; }
  [ "$(openssl x509 -in "/tmp/$HOST.crt" -noout -pubkey)" = \
    "$(openssl pkey -in "/tmp/$HOST.key" -pubout)" ] \
    || { echo "error: recovered key does not match the certificate" >&2; exit 1; }

  echo "==> valid until $(openssl x509 -in "/tmp/$HOST.crt" -noout -enddate | cut -d= -f2)"
  aws s3 cp "/tmp/$HOST.crt" "s3://$CERT_BUCKET/certs/$HOST/$HOST.crt"
  aws s3 cp "/tmp/$HOST.key" "s3://$CERT_BUCKET/certs/$HOST/$HOST.key"
  rm -f "/tmp/$HOST.crt" "/tmp/$HOST.key"

  restore_volume; trap - EXIT
  echo
  echo "Certificate stored at s3://$CERT_BUCKET/certs/$HOST/"
  echo "The next deploy restores it instead of asking Let's Encrypt for a new one."
  exit 0
done

echo "No certificate for $HOST found on any stopped worker." >&2
exit 1
