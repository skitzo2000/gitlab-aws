# GitLab Demo Platform — AWS + Terraform + Ansible

Self-hosted GitLab for the demo, built to be **cheap, disposable, and two-command**:
`terraform apply` provisions the infrastructure, `ansible-playbook site.yml`
configures it. `terraform destroy` deletes every trace.

**Terraform provisions, Ansible configures.** No bash in user-data — instances
boot vanilla Ubuntu; Terraform generates the Ansible inventory and hands off.

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
it to the self-hosted registry. Create a project in the demo GitLab, drop those
three files in, and edit one placeholder in `.gitlab-ci.yml`
(`REGISTRY_HOST_PLACEHOLDER` → `terraform output registry_host` — the registry
is plain HTTP, so dind needs the `--insecure-registry` flag).

To pull the image from your laptop, add the same host to your Docker daemon's
`insecure-registries`.

## Knobs (terraform/variables.tf)

| Variable | Default | Note |
|---|---|---|
| `region` | `us-east-1` | |
| `admin_cidr` | `0.0.0.0/0` | **Narrow to your IP** — gates SSH + k3s API |
| `use_spot` | `true` | `false` for on-demand |
| `worker_count` | `2` | |
| `gitlab_image` | `gitlab/gitlab-ce:18.5.0-ce.0` | bump as needed |
| `runner_image` | `gitlab/gitlab-runner:alpine-v18.5.0` | keep in step with GitLab |

## Caveats (it's a demo, on purpose)

- **HTTP only.** No TLS — sslip.io + Let's Encrypt hits rate limits, and the
  demo doesn't need it. Hence the dind `--insecure-registry` flag.
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
| Ansible can't connect | Did `terraform apply` finish? Worker IPs change on stop/start — re-apply to refresh the inventory |
| Pipeline can't push image | Did you replace `REGISTRY_HOST_PLACEHOLDER` in `.gitlab-ci.yml`? |

## What's next (per the deck)

- Keycloak (self-hosted OIDC) as the secondary SSO provider — `omniauth` block
  in `GITLAB_OMNIBUS_CONFIG` + a Keycloak deployment, as another role.
- Wiki live-edit with the real commit SHA — no infra needed, just the demo flow.
