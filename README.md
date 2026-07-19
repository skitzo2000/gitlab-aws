# GitLab Demo Platform — AWS + Terraform + Ansible

Self-hosted GitLab for the demo, built to be **cheap, disposable, and two-command**:
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

Design decisions (mirrors the demo deck):

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
| **SSO via external Keycloak** | The amnesia-labs Keycloak is the OIDC provider — nothing to deploy here, just three variables. Password login stays enabled (Keycloak is the *secondary* provider, per the demo narrative) |

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

## Usage

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

## Demo pipeline

`examples/spaceballs-the-docker/` is the deck's narrative: a commit triggers a
pipeline on the hosted runner, which **builds** Spaceballs-the-docker and pushes
it to the self-hosted registry. Create a project in the demo GitLab and drop
those three files in — with a domain configured (HTTPS) it works as-is,
including `docker pull` from your laptop. Only in sslip.io/HTTP mode does dind
need the `--insecure-registry` flag (see the comment in the `.gitlab-ci.yml`).

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

## Knobs (terraform/variables.tf)

All configuration is centralized in `terraform/variables.tf`; copy
`terraform.tfvars.example` to `terraform.tfvars` (gitignored) to override.
Highlights:

| Variable | Default | Note |
|---|---|---|
| `region` | `us-east-1` | |
| `admin_cidr` | `0.0.0.0/0` | **Narrow to your IP** — gates SSH + k3s API |
| `domain` / `route53_zone_id` | `""` | real DNS (see above); empty = sslip.io |
| `keycloak_issuer_url` / `_client_id` / `_client_secret` | `""` | SSO against the amnesia-labs Keycloak; empty issuer = disabled |
| `use_spot` | `true` | `false` for on-demand |
| `worker_count` | `2` | |
| `vpc_cidr` / `subnet_cidr` | `10.60.0.0/16` / `10.60.1.0/24` | avoids k3s' 10.42/10.43 |
| `gitlab_image` | `gitlab/gitlab-ce:18.5.0-ce.0` | bump as needed |
| `runner_image` | `gitlab/gitlab-runner:alpine-v18.5.0` | keep in step with GitLab |

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
| Pipeline can't push image | Did you replace `REGISTRY_HOST_PLACEHOLDER` in `.gitlab-ci.yml`? |

## What's next (per the deck)

- Wiki live-edit with the real commit SHA — no infra needed, just the demo flow.
