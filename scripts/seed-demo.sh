#!/usr/bin/env bash
# seed-demo.sh — populate the freshly deployed GitLab with a demo project:
# full git history, project wiki, and a first set of pipeline runs.
#
# Runs from YOUR machine (not CI): the demo source usually lives on a
# private forge only your network can reach, and this script only needs
# GitLab's public HTTP endpoint — it works even when the admin plane
# (SSH / k3s API) is scoped to the CI runner that deployed.
#
# Usage:
#   scripts/seed-demo.sh --source <git-clone-url> [options]
#
# Options:
#   --source URL       Clone URL of the demo repo (required; SSH or HTTPS,
#                      anything *your* machine can clone). Its optional
#                      wiki/ directory becomes the GitLab project wiki.
#   --project NAME     Project name in GitLab (default: source repo name)
#   --extra-commits N  Push N follow-up commits, one at a time, so the
#                      pipeline graph shows a build history (default: 2)
#   --private          Create the project private (default: public, so the
#                      demo audience can browse without logging in)
#
# Auth (first match wins):
#   GITLAB_TOKEN         existing API token (api scope)
#   GITLAB_ROOT_PASSWORD root password (exchanged via OAuth password grant)
#   otherwise            terraform output -raw gitlab_root_password
#
# GitLab URL: $GITLAB_URL if set, else terraform output -raw gitlab_url.
# The terraform fallbacks need working AWS credentials (e.g. run under
# vault-run) since state lives in S3.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

SOURCE_REPO="${SOURCE_REPO:-}"
PROJECT=""
EXTRA_COMMITS=2
VISIBILITY=public

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)        SOURCE_REPO="$2"; shift 2 ;;
    --project)       PROJECT="$2"; shift 2 ;;
    --extra-commits) EXTRA_COMMITS="$2"; shift 2 ;;
    --private)       VISIBILITY=private; shift ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SOURCE_REPO" ]] || { echo "error: --source <git-clone-url> is required (or set SOURCE_REPO)" >&2; exit 2; }
PROJECT="${PROJECT:-$(basename "$SOURCE_REPO" .git)}"

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

GITLAB_URL="${GITLAB_URL:-$(tf_out gitlab_url)}"
GITLAB_URL="${GITLAB_URL%/}"
echo "GitLab: $GITLAB_URL"

api() { # api METHOD PATH [curl-data-args...]
  local method="$1" path="$2"; shift 2
  curl -fsS -X "$method" -H "Authorization: Bearer $TOKEN" "$@" \
    "$GITLAB_URL/api/v4$path"
}

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

# --- token -------------------------------------------------------------------
if [[ -n "${GITLAB_TOKEN:-}" ]]; then
  TOKEN="$GITLAB_TOKEN"
else
  ROOT_PASS="${GITLAB_ROOT_PASSWORD:-$(tf_out gitlab_root_password)}"
  echo "Exchanging root credentials for an OAuth token..."
  TOKEN=$(curl -fsS "$GITLAB_URL/oauth/token" \
    --data-urlencode grant_type=password \
    --data-urlencode username=root \
    --data-urlencode "password=$ROOT_PASS" | json "['access_token']")
fi

# --- project -----------------------------------------------------------------
ENCODED="root%2F$PROJECT"
if api GET "/projects/$ENCODED" -o /dev/null 2>/dev/null; then
  echo "Project root/$PROJECT already exists — reusing."
else
  echo "Creating project root/$PROJECT ($VISIBILITY)..."
  api POST /projects \
    --data-urlencode "name=$PROJECT" \
    --data-urlencode "visibility=$VISIBILITY" \
    --data-urlencode "description=Demo workload — every push rebuilds the container image on this cluster" \
    -o /dev/null
fi

# --- code: full history ------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
AUTH_HOST="${GITLAB_URL#*://}"
SCHEME="${GITLAB_URL%%://*}"
PUSH_BASE="$SCHEME://oauth2:$TOKEN@$AUTH_HOST"

echo "Cloning $SOURCE_REPO..."
git clone --quiet "$SOURCE_REPO" "$WORK/src"
git -C "$WORK/src" push --quiet "$PUSH_BASE/root/$PROJECT.git" --all
git -C "$WORK/src" push --quiet "$PUSH_BASE/root/$PROJECT.git" --tags
echo "Pushed $(git -C "$WORK/src" rev-list --count HEAD) commits + tags."

# --- wiki --------------------------------------------------------------------
if [[ -d "$WORK/src/wiki" ]]; then
  echo "Publishing wiki pages..."
  WIKI="$WORK/wiki"
  mkdir "$WIKI"
  cp "$WORK/src/wiki/"*.md "$WIKI/"
  git -C "$WIKI" init --quiet -b main
  # Home last, so the wiki's own history reads oldest→newest sensibly.
  for page in $(ls "$WIKI" | grep -v '^Home\.md$') Home.md; do
    git -C "$WIKI" add "$page"
    git -C "$WIKI" commit --quiet -m "wiki: add ${page%.md} page"
  done
  git -C "$WIKI" push --quiet "$PUSH_BASE/root/$PROJECT.wiki.git" main:main
  echo "Wiki: $(ls "$WIKI" | wc -l) pages."
else
  echo "Source has no wiki/ directory — skipping wiki."
fi

# --- pipeline history --------------------------------------------------------
if [[ "$EXTRA_COMMITS" -gt 0 ]]; then
  echo "Generating $EXTRA_COMMITS extra pipeline run(s)..."
  DEFAULT_BRANCH=$(git -C "$WORK/src" symbolic-ref --short HEAD)
  for i in $(seq 1 "$EXTRA_COMMITS"); do
    printf '%s  staging build %s of %s on the demo cluster\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$i" "$EXTRA_COMMITS" >> "$WORK/src/DEMO_LOG.md"
    git -C "$WORK/src" add DEMO_LOG.md
    git -C "$WORK/src" commit --quiet -m "chore(demo): record staging build $i on the demo cluster"
    git -C "$WORK/src" push --quiet "$PUSH_BASE/root/$PROJECT.git" "$DEFAULT_BRANCH"
    if [[ "$i" -lt "$EXTRA_COMMITS" ]]; then sleep 20; fi
  done
fi

# --- summary -----------------------------------------------------------------
cat <<EOF

Seeded. Show the audience:
  project    $GITLAB_URL/root/$PROJECT
  pipelines  $GITLAB_URL/root/$PROJECT/-/pipelines
  wiki       $GITLAB_URL/root/$PROJECT/-/wikis/home
  registry   $GITLAB_URL/root/$PROJECT/container_registry
EOF
