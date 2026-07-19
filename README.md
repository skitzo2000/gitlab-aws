# GitLab Demo Platform — AWS + Terraform

Self-hosted GitLab for the demo, built to be **cheap, disposable, and one-command**:
`terraform apply` brings up the whole platform, `terraform destroy` deletes every trace.

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
| Hosted runner auto-registered at boot | A systemd unit on the CP waits for GitLab readiness, creates an instance runner via the API, and deploys `gitlab-runner` (kubernetes executor, privileged for dind) |

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

## Usage

```bash
cd terraform
terraform init
terraform apply                       # ~2 min for AWS, then ~8-10 min for GitLab to boot

terraform output gitlab_url           # http://gitlab.<eip>.sslip.io
terraform output -raw gitlab_root_password
```

Log in as `root`. The registry lives at `terraform output registry_host`.

Watch the runner register itself:

```bash
$(terraform output -raw runner_bootstrap_logs)
```

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

## Knobs (variables.tf)

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
- The initial root password is visible in the rendered manifest on the CP's
  disk and in Terraform state. Demo-grade secret handling.
- Spot reclaims *stop* the instances; start them again and everything
  (including the runner) comes back on its own.
- SSH key is generated by Terraform and written to
  `terraform/gitlab-demo-key.pem` (gitignored).

## Troubleshooting

| Symptom | Look at |
|---|---|
| GitLab not up after ~10 min | `kubectl -n gitlab get pods`, `kubectl -n gitlab logs deploy/gitlab` |
| No runner in Admin → CI/CD → Runners | `journalctl -u runner-bootstrap` on the CP |
| Workers not joining | `journalctl -u k3s-agent` on a worker |
| Pipeline can't push image | Did you replace `REGISTRY_HOST_PLACEHOLDER` in `.gitlab-ci.yml`? |

## What's next (per the deck)

- Keycloak (self-hosted OIDC) as the secondary SSO provider — `omniauth` block
  in `GITLAB_OMNIBUS_CONFIG` + a Keycloak deployment.
- Wiki live-edit with the real commit SHA — no infra needed, just the demo flow.
