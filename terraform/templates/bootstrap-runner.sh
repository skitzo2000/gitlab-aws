#!/bin/bash
# Auto-registers a hosted GitLab Runner against the in-cluster GitLab.
# Runs on the control plane as the `runner-bootstrap` systemd unit.
# Idempotent: safe to re-run; skips runner creation if the token secret exists.
set -u
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
NS_GITLAB=gitlab
NS_RUNNER=gitlab-runner

log() { echo "[runner-bootstrap] $*"; }

gitlab_pod() {
  kubectl -n "$NS_GITLAB" get pod -l app=gitlab \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# 1. Wait for the k3s API, the GitLab pod, and GitLab readiness.
until kubectl get nodes >/dev/null 2>&1; do
  log "waiting for k3s API"
  sleep 10
done

POD=""
until POD=$(gitlab_pod) && [ -n "$POD" ]; do
  log "waiting for gitlab pod to be scheduled"
  sleep 15
done

until kubectl -n "$NS_GITLAB" exec "$POD" -- \
  curl -sfo /dev/null http://localhost/-/readiness 2>/dev/null; do
  log "waiting for gitlab readiness (first boot takes ~5-8 min)"
  sleep 20
  POD=$(gitlab_pod)
done
log "gitlab is ready (pod $POD)"

# 2. Create an instance runner via the API and stash its auth token.
create_runner_secret() {
  local pat resp token
  pat="glpat-$(openssl rand -hex 12)"

  kubectl -n "$NS_GITLAB" exec "$POD" -- gitlab-rails runner "
    u = User.find_by_username('root')
    t = u.personal_access_tokens.create!(scopes: ['api', 'create_runner'],
                                         name: 'runner-bootstrap',
                                         expires_at: 90.days.from_now)
    t.set_token('$pat')
    t.save!
  " || return 1

  resp=$(kubectl -n "$NS_GITLAB" exec "$POD" -- \
    curl -sf -X POST http://localhost/api/v4/user/runners \
    -H "PRIVATE-TOKEN: $pat" \
    --data "runner_type=instance_type" \
    --data "description=aws-hosted-runner" \
    --data "run_untagged=true" \
    --data "tag_list=docker,aws,demo") || return 1

  token=$(echo "$resp" | python3 -c \
    'import sys, json; print(json.load(sys.stdin)["token"])') || return 1

  kubectl -n "$NS_RUNNER" create secret generic runner-token \
    --from-literal=token="$token" || return 1
}

kubectl get ns "$NS_RUNNER" >/dev/null 2>&1 || kubectl create ns "$NS_RUNNER"

if kubectl -n "$NS_RUNNER" get secret runner-token >/dev/null 2>&1; then
  log "runner-token secret already exists, skipping runner creation"
else
  until create_runner_secret; do
    log "runner creation failed, retrying in 30s"
    sleep 30
  done
  log "runner created and token stored"
fi

# 3. Deploy the runner.
until kubectl apply -f /opt/gitlab-demo/runner.yaml; do
  log "runner manifest apply failed, retrying in 15s"
  sleep 15
done

log "done — hosted runner deployed"
