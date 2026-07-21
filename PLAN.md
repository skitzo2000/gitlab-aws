# Plan — GitLab demo platform

*Updated 2026-07-20, end of the launch-debugging session. The cluster is
LIVE and PARKED (stopped instances; EIP, DNS, cert, and data intact).*

## Where we are

The platform deployed successfully end-to-end for the first time tonight:
`https://gitlab.amnesia-labs.com` with a valid Let's Encrypt cert, private
workers NATed through the control plane, runner registered, on-demand
instances. Park mode: `scripts/cluster.sh stop` (resume: `start`, ~3 min).

All of tonight's work is **uncommitted on `main`** (~18 files):

- **Fixes** (each was a first-boot blocker):
  - Security-group descriptions: no apostrophes allowed (AWS charset)
  - S3-native state locking (`use_lockfile`) — DynamoDB table + IAM removed
  - `publishNotReadyAddresses: true` — Let's Encrypt HTTP-01 vs. startup
    probe deadlock in HTTPS mode
  - `monitoring_whitelist` 10/8 — GitLab 404s health endpoints to
    non-whitelisted sources; kubelet/ansible probes were blocked
  - Non-burstable `m6a.large` workers — fresh T3s have zero credits and
    throttle to 30 %/vCPU during first reconfigure (20+ min boots)
- **Features**:
  - Cloudflare-managed DNS record (provider v5, forced DNS-only/grey-cloud)
  - Private worker subnet, cp doubles as NAT instance (systemd oneshot,
    survives stop/start); worker addresses now stable → inventory never stale
  - On-demand by default (`use_spot=false`); spot remains opt-in
  - `scripts/cluster.sh` — status/stop/start/deploy/destroy lifecycle
- **Docs**: README (architecture, costs ~$0.21/hr running / ~$0.02/hr
  parked, lifecycle section), full tfvars reference (all values = defaults)

## Next session (in order)

1. **Commit + PR**: branch `dev/v0.2.0-launch-fixes` off `main`, commit the
   ~18 files (include both `.terraform.lock.hcl`), PR, merge.
2. **GitHub Actions workflows** (`.github/workflows/`):
   - `deploy.yml` — push to `main` touching `terraform/`/`ansible/` →
     OIDC-assume the deployer role → `scripts/cluster.sh deploy`
   - `destroy.yml` — manual dispatch, typed confirmation →
     `scripts/cluster.sh destroy --yes`
3. **Repo wiring**: `gh variable set` AWS_ROLE_ARN / AWS_REGION /
   TF_STATE_BUCKET (values: `terraform output github_setup` in bootstrap/)
   + GITLAB_DOMAIN + CLOUDFLARE_ZONE_ID; `gh secret set`
   CLOUDFLARE_API_TOKEN. (No TF_LOCK_TABLE — DynamoDB is gone. No
   ROUTE53_ZONE_ID — DNS is Cloudflare.)
4. **Test the pipeline**: `cluster.sh start`, push a trivial change, watch
   the workflow update the live cluster in place.
5. **Release**: tag `v0.2.0` on main.
6. **Seed the demo**: `scripts/seed-demo.sh --source <repo>` once the
   pipeline is proven.

## Constraints to remember

- **Let's Encrypt duplicate-cert budget: assume 1 rebuild left this rolling
  week** (~4 of 5 issuances spent tonight; window rolls off ~next weekend).
  Full destroys spend one; stop/start spends none. Escape hatch if
  exhausted: comment out `domain` in tfvars → HTTP/sslip.io mode.
- Cost changes (instance types, pricing modes, managed services) are
  **user decisions** — present estimates first.
- `admin_cidr` pins SSH/kubectl to one IP; refresh with `terraform apply`
  if the home IP changes. Public URLs are unaffected.

## Backlog (v0.3 candidates)

- Cert persistence as a k8s TLS Secret (backup/restore) → makes full
  teardowns free of the LE budget; enables "destroy to VPC" parking (~$4/mo
  vs ~$12/mo stopped)
- Optional `az_index` variable (spot-mode capacity shopping across AZs)
- Scheduled park/resume workflows (cron stop/start via `cluster.sh`)
