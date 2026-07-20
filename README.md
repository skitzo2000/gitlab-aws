# GitLab Demo Platform — AWS + Terraform + Ansible

Self-hosted GitLab for demos, built to be **cheap, disposable, and two-command**:
`terraform apply` provisions the infrastructure, `ansible-playbook site.yml`
configures it. `terraform destroy` deletes every trace.

**Terraform provisions, Ansible configures.** No bash in user-data — instances
boot vanilla **Debian 13 minimal** (smallest surface area: no snapd, lean
default package set); Terraform generates the Ansible inventory and hands off.

## Architecture

```
                        Elastic IP (stable)
                              │
                gitlab.<eip>.sslip.io  (free wildcard DNS, zero setup)
                              │
   ┌──────────────────────────┼──────────────────────────────────────┐
   │  VPC 10.60.0.0/16 · one public subnet · no NAT (cost: $0)       │
   │                          │                                      │
   │  ┌───────────────────────┴─────┐                                │
   │  │ cp · t3a.small · spot       │   k3s server                   │
   │  │ TAINTED NoSchedule ─────────┼── nothing schedules here,      │
   │  │ (svclb fwds 80/5050/2222)   │   so it stays tiny             │
   │  └─────────────┬───────────────┘                                │
   │                │ k3s join                                       │
   │  ┌─────────────┴───────┐   ┌─────────────────────┐              │
   │  │ worker-1 t3a.large  │   │ worker-2 t3a.large  │   spot, AMD  │
   │  │ GitLab omnibus pod  │   │ gitlab-runner +     │              │
   │  │ (CE image, registry │   │ CI job pods (dind)  │              │
   │  │  enabled, 30Gi PVC) │   │                     │              │
   │  └─────────────────────┘   └─────────────────────┘              │
   └─────────────────────────────────────────────────────────────────┘
```

Design decisions:

| Decision | Why |
|---|---|
| k3s, control plane **tainted `NoSchedule`** | Properly cordons CP from workloads → CP can be a $4/mo t3a.small |
| **Omnibus image** (`gitlab/gitlab-ce`) as one Deployment | Simpler all around vs. the cloud-native Helm chart; registry, wiki, everything in one container |
| GitLab's 4Gi memory request | Effectively dedicates worker-1 to GitLab; runner + jobs land on worker-2 |
| AMD (`t3a`) **persistent spot**, interruption = *stop* | ~70% off on-demand; instances stop (not terminate) on reclaim; you can also stop them yourself between demos |
| EIP on the **control plane** + `sslip.io` | k3s svclb tolerates the CP taint and binds 80/5050/2222 on every node, so the CP's stable IP fronts the GitLab pod wherever it runs. URL never changes across rebuilds of workers |
| Manifests via k3s **auto-deploy dir** | Ansible just templates YAML into `/var/lib/rancher/k3s/server/manifests/` — no kubectl apply, no helm, no python k8s deps |
| Runner config **pre-provisioned** | Ansible creates an instance runner through the GitLab API and templates a complete `config.toml` (kubernetes executor, privileged for dind) into a Secret — the runner pod just runs, no `register` step |
| **Debian 13 minimal** AMI | Widest-surface-area OS avoided: official Debian cloud image, no snapd, minimal package set. SSH user is `admin` |
| **HTTPS via omnibus Let's Encrypt** | When a domain is set, GitLab obtains and auto-renews its own cert (HTTP-01 against the DNS record Terraform manages) — no cert-manager, no manual certs. Same cert covers the registry, so dind needs no insecure-registry flag |
| **SSO via external Keycloak** | The amnesia-labs Keycloak is the OIDC provider — nothing to deploy here, just three variables. Password login stays enabled alongside SSO |

## Cost (us-east-1, approximate)

| Item | Running | Stopped |
|---|---|---|
| 1× t3a.small spot | ~$0.006/hr | — |
| 2× t3a.large spot | ~$0.055/hr | — |
| 100 GB gp3 EBS | ~$0.011/hr | ~$0.011/hr |
| 3× public IPv4 | ~$0.015/hr | ~$0.005/hr (EIP only) |
| **Total** | **~$0.09/hr** | **~$0.02/hr** |

Stop between demos: `aws ec2 stop-instances --instance-ids ...` (persistent spot
supports stop/start; the EIP — and therefore all URLs — survives).

## Prerequisites

- Terraform ≥ 1.5, AWS credentials configured
- Ansible (`pip install ansible-core` — only builtin modules are used, no
  galaxy collections)

## Full pipeline: push to git → lands on AWS

```
git push (main) ──► GitHub Actions ──► OIDC ──► IAM deployer role ──► terraform apply
                    (no stored creds)           (minimal, region-scoped)      │
                                                                    ansible-playbook
                                                                              │
                                                                  GitLab + runner live
```

The runner holds **no AWS credentials**: the workflow assumes an IAM role via
GitHub's OIDC federation, trusted only for this repo's `main` branch. The
role is minimal by construction — `ec2:*` locked to one region, the Terraform
state bucket + lock table, optionally record-changes on your one Route 53
zone, and **zero IAM permissions** (the platform creates no IAM resources,
so the role cannot escalate).

One-time setup (with your own admin credentials):

```bash
cd bootstrap
terraform init && terraform apply     # OIDC provider, deployer role, S3 state, lock table
terraform output github_setup         # gh CLI commands: repo variables + optional secrets
```

That's it. From then on:

- **`git push` to `main`** (touching `terraform/` or `ansible/`) deploys —
  apply + playbook, with a run summary showing the URLs.
- **Actions → destroy → type `destroy`** tears everything down.
- Terraform state lives in S3 (created by bootstrap), shared between CI and
  laptops — bootstrap drops a gitignored `backend_override.tf` so local
  `terraform` commands use the same state. (If you had local state first,
  migrate once with `terraform init -migrate-state`.)
- Each deploy scopes SSH/k3s-API access (`admin_cidr`) to that runner's IP.
- Platform config in CI comes from repo variables (`GITLAB_DOMAIN`,
  `ROUTE53_ZONE_ID`, `KEYCLOAK_ISSUER_URL`, `KEYCLOAK_CLIENT_ID`) and one
  secret (`KEYCLOAK_CLIENT_SECRET`) — same knobs as the tfvars walkthrough.

## Seeding the demo content

A demo cluster is only convincing with something *in* it. `scripts/seed-demo.sh`
populates the fresh GitLab with a real project — full commit history, a
project wiki, and a first set of pipeline runs — from any repo your machine
can clone (typically a private forge on your own network, which is exactly
why this step runs locally instead of in CI):

```bash
scripts/seed-demo.sh --source <clone-url-of-your-demo-repo>
```

What it does, over GitLab's public HTTP API only (it works even when the
admin plane is IP-scoped to the CI runner that deployed):

1. Exchanges the root password (from the shared Terraform state; or pass
   `GITLAB_TOKEN`) for an API token.
2. Creates the project (public, so the audience can browse anonymously).
3. Pushes **all branches and tags** — the full history arrives intact.
4. If the source repo has a `wiki/` directory of markdown pages, publishes
   it as the **project wiki** (page-per-commit, `[[links]]` work).
5. Pushes a couple of follow-up commits (`--extra-commits N`, default 2),
   spaced out, so *CI/CD → Pipelines* shows a build history, not a lone run.

The source repo brings its own `.gitlab-ci.yml`; each seeded push triggers
the hosted runner, so by the time you present, the registry already holds
per-commit images. The script prints the project / pipelines / wiki /
registry URLs to put on screen.

Requirements on the demo repo: nothing beyond a `.gitlab-ci.yml` that
builds with dind (see [What the platform provides](#what-the-platform-provides))
and, optionally, that `wiki/` directory.

## Manual usage (no CI)

```bash
cd terraform
terraform init
terraform apply          # ~2 min; generates ../ansible/inventory/

cd ../ansible
ansible-playbook site.yml   # k3s + GitLab + runner; GitLab boot is the long pole (~8-10 min)

cd ../terraform
terraform output gitlab_url             # http://gitlab.<eip>.sslip.io
terraform output -raw gitlab_root_password
```

Log in as `root`. The registry lives at `terraform output registry_host`.
The playbook is idempotent — re-run it any time. (If you stop/start the
workers their public IPs change; run `terraform apply` again to refresh the
inventory before re-running Ansible.)

Get kubectl access:

```bash
$(terraform output -raw kubeconfig_command)
kubectl get nodes    # cp shows the control-plane taint; workers are clean
```

Tear down:

```bash
terraform destroy
```

## What the platform provides

Facts any project/pipeline in this GitLab can rely on:

- `CI_REGISTRY*` variables are auto-populated; the registry is at
  `terraform output registry_host`, and
  `docker login -u gitlab-ci-token -p "$CI_JOB_TOKEN" "$CI_REGISTRY"` works
  in jobs.
- The hosted runner (kubernetes executor) runs untagged jobs and allows
  **privileged dind**. In sslip.io/HTTP mode only, a dind service needs
  `command: ["--insecure-registry=<registry_host>"]`; with a domain (HTTPS)
  no special flags are needed.
- **Importing repos from an external forge** (*New project → Import
  project → Repository by URL*) works with any source this instance can
  reach. Note: GitLab-native *pull mirroring* is a Premium feature — on CE,
  import-by-URL is the pull path (source-side *push mirroring* into GitLab
  is the free continuous-sync alternative). If a source hostname resolves
  to a private IP, allow it under *Admin → Settings → Network → Outbound
  requests*.

## DNS / pointing a domain at it

Default is `sslip.io` wildcard DNS — zero setup, the URL embeds the EIP.
To use a real domain, set it in your `terraform.tfvars`:

```hcl
domain          = "demo.example.com"          # GitLab becomes gitlab.demo.example.com
route53_zone_id = "Z0123456789ABCDEFGHIJ"     # optional — omit if DNS is hosted elsewhere
```

With a Route 53 zone ID, Terraform manages the `A` record to the EIP itself.
Without one, `terraform output dns_record` prints the single record to create
at your DNS host (the EIP is stable, so it's set-once) — **create it before
running the playbook**, since Let's Encrypt validates against it. The hostname
flows from this one variable into GitLab's `external_url`, the registry URL,
and the runner config — after changing it, run `terraform apply` and re-run
the playbook so GitLab reconfigures (data is untouched).

**Setting a domain automatically enables HTTPS.** GitLab's built-in Let's
Encrypt integration issues the cert during the first reconfigure (HTTP-01 on
port 80, which stays open for that + the HTTPS redirect) and auto-renews it.
`letsencrypt_email` defaults to `admin@<domain>`. Without a domain (sslip.io
mode) the stack stays HTTP, since Let's Encrypt won't issue for sslip
hostnames.

## SSO (amnesia-labs Keycloak)

GitLab federates to the existing amnesia-labs Keycloak over OIDC — the
platform deploys nothing Keycloak-related, it just points at it:

1. In Keycloak, create a **confidential client** (standard/authorization-code
   flow) in your realm, with the redirect URI from
   `terraform output keycloak_redirect_uri`.
2. Set in `terraform.tfvars`:
   ```hcl
   keycloak_issuer_url    = "https://keycloak.amnesia-labs.com/realms/<realm>"
   keycloak_client_id     = "gitlab"
   keycloak_client_secret = "<from Keycloak>"
   ```
3. `terraform apply` + re-run the playbook. The login page grows an
   "Amnesia Labs SSO" button (label configurable via `keycloak_label`).

Users are auto-created on first SSO login (`preferred_username` becomes the
GitLab username) and are not blocked pending admin approval — demo-friendly
defaults, both in the omniauth block in
`ansible/roles/gitlab/templates/gitlab.yaml.j2`. PKCE is enabled. Leaving
`keycloak_issuer_url` empty disables the whole block.

## Configuration

One central config, one direction of flow:

```
terraform.tfvars  ──►  terraform/variables.tf  ──►  AWS resources
   (your values)       (single source of truth,  └►  ansible/inventory/  ──►  k8s manifests
                        reference + defaults)        (generated group_vars)   (GitLab, runner)
```

Nothing is configured anywhere else — Ansible has no variables of its own,
manifests restate nothing. Change a value, `terraform apply`, re-run the
playbook, and it lands everywhere it's used.

**Start with [`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example)** —
it's written as a step-by-step walkthrough. Copy it to `terraform.tfvars`
(gitignored) and work top to bottom; each step unlocks one capability:

| Step | What you set | What you get |
|---|---|---|
| *(none)* | nothing — empty tfvars works | HTTP demo at `http://gitlab.<eip>.sslip.io` |
| **1** | `region`, `admin_cidr` | admin plane (SSH, k3s API) locked to your IP |
| **2** | `domain` (+ `route53_zone_id`) | real URLs + automatic HTTPS via Let's Encrypt |
| **3** | `keycloak_issuer_url`, `_client_id`, `_client_secret` | SSO against the amnesia-labs Keycloak (needs step 2) |
| **4** | `use_spot`, instance types/counts, volumes | sizing & cost |
| **5** | `gitlab_image`, `runner_image` | version bumps |
| **6** | `vpc_cidr`, `subnet_cidr`, `cp_private_ip` | network layout (rarely) |

`terraform/variables.tf` is the full reference — every variable carries a
description, grouped in the same section order. **Incoherent combinations
fail at `terraform plan`** with a message naming the step to fix (e.g. a
Route 53 zone without a domain, or Keycloak SSO without the HTTPS domain it
depends on) — checks live on the generated group_vars file in
`terraform/inventory.tf`, the choke point every value flows through.

## Caveats (it's a demo, on purpose)

- **HTTPS requires a real domain.** sslip.io mode stays plain HTTP (Let's
  Encrypt won't issue there), which is where the dind `--insecure-registry`
  flag comes in.
- **Data lives on worker-1's EBS volume** (k3s local-path PVC). A worker
  *stop/start* keeps it; `terraform destroy` or a worker replacement loses it.
  Fine for a rebuildable demo.
- The initial root password is in Terraform state, the generated
  `ansible/inventory/group_vars/all.yml`, and the rendered manifest on the
  CP's disk. Demo-grade secret handling.
- Spot reclaims *stop* the instances; start them again and everything
  (including the runner) comes back on its own.
- SSH key is generated by Terraform and written to
  `terraform/gitlab-demo-key.pem` (gitignored, as is `ansible/inventory/`).

## Troubleshooting

| Symptom | Look at |
|---|---|
| GitLab not up after ~10 min | `kubectl -n gitlab get pods`, `kubectl -n gitlab logs deploy/gitlab` |
| No runner in Admin → CI/CD → Runners | `kubectl -n gitlab-runner logs deploy/gitlab-runner`; re-run the playbook |
| Workers not joining | `journalctl -u k3s-agent` on a worker |
| Cert not issued / readiness wait loops in HTTPS mode | Does the DNS record exist and point at the EIP? `kubectl -n gitlab logs deploy/gitlab \| grep -i letsencrypt`; LE rate limits are per-domain (5 duplicate certs/week) |
| SSO button missing or login fails | Issuer URL must match Keycloak's realm URL exactly (discovery is on); check the client secret and that the redirect URI is registered; `kubectl -n gitlab logs deploy/gitlab \| grep -i omniauth` |
| Ansible can't connect | Did `terraform apply` finish? Worker IPs change on stop/start — re-apply to refresh the inventory |
| Repo import by URL fails | GitLab (on AWS) must reach the source URL; if it resolves to a private IP, allow it in *Admin → Settings → Network → Outbound requests* |
| CI deploy fails at AssumeRole | Bootstrap run? Repo variables set (`terraform output github_setup`)? Workflow must run on `main` — the role trusts only that branch |
