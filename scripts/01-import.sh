#!/usr/bin/env bash
# 01-import.sh: resolve the public GitHub repo at a commit with POST /requests/import (free,
# pins nothing). Saves .state/import.json; prints repoUrl and baseCommit.
#   REF=<commit sha> scripts/01-import.sh     (default: this checkout's HEAD; it must be pushed)
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need curl jq git
load_env
url="${GITHUB_REPO_URL:-}"
[[ "$url" =~ ^https://github\.com/[^/]+/[^/]+$ ]] || die "set GITHUB_REPO_URL=https://github.com/<owner>/<repo> in $ENV_FILE"
ref="${REF:-$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)}"
[[ "$ref" =~ ^[0-9a-f]{40}$ ]] || die "no commit: commit and push first, or pass REF=<40-hex sha>"
if [[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]]; then
  echo "warning: working tree has uncommitted changes; the launch uses $ref as pushed" >&2
fi

payload="$(jq -cn --arg u "$url" --arg r "$ref" '{url:$u, ref:$r, kind:"contracts"}')"
echo "POST $IMD_API/requests/import $payload"
resp="$(api_post /requests/import "$payload")" || die "import request failed"
echo "$resp" | jq . 2>/dev/null || echo "$resp"
[[ "$(jq -r '.ok' <<<"$resp")" == "true" ]] || die "import refused (see problems above)"
echo "$resp" >"$STATE_DIR/import.json"
echo "repoUrl    : $(jq -r '.source.repoUrl' <<<"$resp")"
echo "baseCommit : $(jq -r '.source.baseCommit' <<<"$resp")"
echo "sizeKb     : $(jq -r '.source.sizeKb' <<<"$resp")"
echo "saved $STATE_DIR/import.json; next: scripts/02-check-launch-body.sh"
