#!/usr/bin/env bash
# acm-provision.sh — request an ACM *exportable public* certificate for the
# GitLab host and drive it to ISSUED via DNS validation at Cloudflare.
#
# This is the one-time, costs-money half of the ACM fallback. Once a cert is
# ISSUED here, the gitlab_cert role's acm.yml exports and seeds it on any
# rebuild whose S3 store is empty — so a rebuild always comes up on HTTPS even
# after Let's Encrypt's five-per-week duplicate budget for the host is spent.
#
#   $$$  Requesting a cert costs $7 per FQDN, and again when ACM auto-renews
#        it (~every 198 days). Exporting an already-issued cert is free. This
#        script only ever creates ONE cert per host: re-runs that find an
#        existing ISSUED exportable cert do nothing.
#
#   scripts/acm-provision.sh <gitlab-host>
#
# Config (env overrides, else read from terraform/terraform.tfvars):
#   REGION                 AWS region (default us-east-1)
#   CLOUDFLARE_ZONE_ID     zone for the host's domain
#   CLOUDFLARE_API_TOKEN   token with Zone:DNS:Edit on that zone
set -euo pipefail

HOST="${1:-}"
[ -n "$HOST" ] || { sed -n '2,20p' "$0"; exit 2; }

REGION="${REGION:-us-east-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$REPO_ROOT/terraform/terraform.tfvars"

# Pull a value out of terraform.tfvars unless already in the environment.
from_tfvars() { # $1 = hcl key
  [ -f "$TFVARS" ] || return 0
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$TFVARS" | head -1
}
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-$(from_tfvars cloudflare_zone_id)}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-$(from_tfvars cloudflare_api_token)}"

AWS_BIN="$(type -P aws || true)"
aws() {
  if [ -n "$AWS_BIN" ]; then "$AWS_BIN" --region "$REGION" "$@"
  else docker run --rm -v "$HOME/.aws:/root/.aws:ro" amazon/aws-cli --region "$REGION" "$@"; fi
}

# --- idempotency: reuse an existing issued cert ------------------------------
existing="$(aws acm list-certificates --includes keyTypes=RSA_2048,RSA_3072,RSA_4096 \
  --query "CertificateSummaryList[?DomainName=='$HOST' && Status=='ISSUED' && ExportOption=='ENABLED'].CertificateArn | [0]" \
  --output text)"
if [ -n "$existing" ] && [ "$existing" != "None" ]; then
  echo "An issued exportable certificate for $HOST already exists:"
  echo "  $existing"
  echo "Nothing to do — the deploy will export it when the S3 store is empty."
  exit 0
fi

# A requested-but-not-yet-issued one from a previous run? Reuse it rather than
# paying for another.
pending="$(aws acm list-certificates --certificate-statuses PENDING_VALIDATION \
  --includes keyTypes=RSA_2048,RSA_3072,RSA_4096 \
  --query "CertificateSummaryList[?DomainName=='$HOST' && ExportOption=='ENABLED'].CertificateArn | [0]" \
  --output text)"

if [ -n "$pending" ] && [ "$pending" != "None" ]; then
  ARN="$pending"
  echo "Resuming a pending request: $ARN"
else
  echo ">>> Requesting an exportable public certificate for $HOST (this is the \$7 step)"
  ARN="$(aws acm request-certificate \
    --domain-name "$HOST" \
    --validation-method DNS \
    --key-algorithm RSA_2048 \
    --options Export=ENABLED \
    --query CertificateArn --output text)"
  echo "    $ARN"
fi

# --- fetch the DNS validation record -----------------------------------------
# ACM populates ResourceRecord a beat after the request; poll briefly.
echo ">>> Waiting for the validation record"
for _ in $(seq 1 20); do
  read -r RR_NAME RR_VALUE < <(aws acm describe-certificate --certificate-arn "$ARN" \
    --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]" --output text)
  [ -n "${RR_NAME:-}" ] && [ "$RR_NAME" != "None" ] && break
  sleep 3
done
[ -n "${RR_NAME:-}" ] && [ "$RR_NAME" != "None" ] || { echo "error: no validation record appeared" >&2; exit 1; }
RR_NAME="${RR_NAME%.}" # Cloudflare wants no trailing dot on the name

# --- create the CNAME at Cloudflare ------------------------------------------
if [ -n "$CLOUDFLARE_ZONE_ID" ] && [ -n "$CLOUDFLARE_API_TOKEN" ]; then
  echo ">>> Creating the validation CNAME at Cloudflare"
  api="https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records"
  # Skip if the record already exists (previous run), else create it.
  exists="$(curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "$api?type=CNAME&name=$RR_NAME" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("result",[])))')"
  if [ "$exists" = "0" ]; then
    curl -sS -X POST "$api" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
      --data "{\"type\":\"CNAME\",\"name\":\"$RR_NAME\",\"content\":\"${RR_VALUE%.}\",\"ttl\":300,\"proxied\":false}" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("success") else (print("Cloudflare error:", d.get("errors")) or 1))'
  else
    echo "    validation CNAME already present"
  fi
else
  echo ">>> No Cloudflare credentials — create this DNS record yourself:"
  echo "      $RR_NAME  CNAME  ${RR_VALUE%.}"
fi

# --- wait for ACM to validate ------------------------------------------------
echo ">>> Waiting for ACM to validate (usually 2-5 min)"
if aws acm wait certificate-validated --certificate-arn "$ARN"; then
  echo
  echo "ISSUED: $ARN"
  echo "The next rebuild will export and seed it whenever the S3 store is empty."
else
  echo "error: validation did not complete in time. It may still finish — re-run" >&2
  echo "this script to resume, or check: aws acm describe-certificate --certificate-arn $ARN" >&2
  exit 1
fi
