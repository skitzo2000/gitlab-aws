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
  else
    # /tmp is mounted too: the recovered pair is staged there and `s3 cp`
    # has to see it from inside the container.
    docker run --rm -v "$HOME/.aws:/root/.aws:ro" -v /tmp:/tmp \
      amazon/aws-cli --region "$REGION" "$@"
  fi
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

  # Mount read-only. The attached disk is identified as the largest partition
  # with no mountpoint — matching on size alone is wrong, since a 40 GiB
  # volume presents its partition as 39.9G. nouuid keeps the kernel from
  # tripping over a filesystem UUID identical to the cp's own.
  #
  # Verification and packing happen on the cp: it has openssl, this machine
  # may not. The pair comes back base64-encoded over the same SSH channel,
  # so nothing is left behind in /tmp on either end.
  OUT="$(ssh_cp "sudo bash -s" <<REMOTE || true
set -euo pipefail
mkdir -p /mnt/rescue
dev=\$(lsblk -rno NAME,TYPE,SIZE,MOUNTPOINT | awk '\$2=="part" && \$4=="" {print \$3, \$1}' \\
  | sed 's/G / /' | sort -rn | head -1 | awk '{print \$2}')
[ -n "\$dev" ] || { echo "NO_UNMOUNTED_PARTITION"; exit 0; }
mount -o ro,nouuid "/dev/\$dev" /mnt/rescue 2>/dev/null || mount -o ro "/dev/\$dev" /mnt/rescue
src=\$(find /mnt/rescue/var/lib/rancher/k3s/storage -path '*/config/ssl/$HOST.crt' 2>/dev/null | head -1)
if [ -z "\$src" ]; then umount /mnt/rescue; echo "NO_CERT_HERE"; exit 0; fi
key="\${src%.crt}.key"
openssl x509 -in "\$src" -noout -checkend 0 || { umount /mnt/rescue; echo "EXPIRED"; exit 0; }
[ "\$(openssl x509 -in "\$src" -noout -pubkey)" = "\$(openssl pkey -in "\$key" -pubout)" ] \\
  || { umount /mnt/rescue; echo "KEY_MISMATCH"; exit 0; }
echo "ENDDATE \$(openssl x509 -in "\$src" -noout -enddate | cut -d= -f2)"
echo "CRT \$(base64 -w0 "\$src")"
echo "KEY \$(base64 -w0 "\$key")"
umount /mnt/rescue
REMOTE
)"

  case "$OUT" in
    *NO_CERT_HERE*|*NO_UNMOUNTED_PARTITION*)
      echo "    no certificate for $HOST on this volume"
      restore_volume; trap - EXIT; continue ;;
    *EXPIRED*)      echo "error: certificate on $WORKER is expired" >&2; exit 1 ;;
    *KEY_MISMATCH*) echo "error: key on $WORKER does not match the certificate" >&2; exit 1 ;;
  esac
  grep -q '^CRT ' <<<"$OUT" || { echo "error: could not read the pair:" >&2; echo "$OUT" >&2; exit 1; }

  echo "==> recovered, valid until $(grep '^ENDDATE ' <<<"$OUT" | cut -d' ' -f2-)"
  TMP="$(mktemp -d)"
  grep '^CRT ' <<<"$OUT" | cut -d' ' -f2 | base64 -d > "$TMP/$HOST.crt"
  grep '^KEY ' <<<"$OUT" | cut -d' ' -f2 | base64 -d > "$TMP/$HOST.key"
  [ -s "$TMP/$HOST.crt" ] && [ -s "$TMP/$HOST.key" ] \
    || { echo "error: decoded certificate or key is empty" >&2; rm -rf "$TMP"; exit 1; }

  aws s3 cp "$TMP/$HOST.crt" "s3://$CERT_BUCKET/certs/$HOST/$HOST.crt"
  aws s3 cp "$TMP/$HOST.key" "s3://$CERT_BUCKET/certs/$HOST/$HOST.key"
  rm -rf "$TMP"

  restore_volume; trap - EXIT
  echo
  echo "Certificate stored at s3://$CERT_BUCKET/certs/$HOST/"
  echo "The next deploy restores it instead of asking Let's Encrypt for a new one."
  exit 0
done

echo "No certificate for $HOST found on any stopped worker." >&2
exit 1
