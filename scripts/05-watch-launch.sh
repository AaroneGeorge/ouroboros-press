#!/usr/bin/env bash
# 05-watch-launch.sh: follow the launch request: intake entry -> job -> launch record.
# Read-only. WATCH=1 polls every 60 s until the launch is live, parked or failed.
#   scripts/05-watch-launch.sh [launch-request-tx-hash]   (default .state/launch-tx)
# When the deployed OuroborosPress address is found and checked, saves .state/press-address.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq curl
load_env
check_chain
tx="${1:-$(cat "$STATE_DIR/launch-tx" 2>/dev/null || true)}"
[[ "$tx" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "pass the launch request tx hash or run 04-launch.sh"
commit="$(jq -r '.source.baseCommit // empty' "$STATE_DIR/import.json" 2>/dev/null || true)"

verify_press() {
  local a="$1" code i m
  code="$(cast code "$a" --rpc-url "$RH_RPC")"
  [[ ${#code} -gt 2 ]] || return 1
  i="$(cast call "$a" 'intake()(address)' --rpc-url "$RH_RPC" 2>/dev/null)" || return 1
  m="$(cast call "$a" 'imd()(address)' --rpc-url "$RH_RPC" 2>/dev/null)" || return 1
  [[ "$(lower "$i")" == "$INTAKE" && "$(lower "$m")" == "$IMD" ]]
}

once() {
  local entry job_id job launch_id launch status number addrs a
  entry="$(api_get "/intake/$CHAIN_ID/$tx" | jq -c '.entries[0] // empty' 2>/dev/null || true)"
  if [[ -z "$entry" ]]; then
    echo "$(date -u +%TZ) intake has not seen $tx yet (404 until 2 confirmations are read)"
    return 1
  fi
  echo "$(date -u +%TZ) intake: $(jq -c '{state, reason, requestId, action, payer}' <<<"$entry")"
  job_id="$(jq -r '.admission.result.jobId // empty' <<<"$entry")"
  [[ -n "$job_id" ]] || return 1
  job="$(api_get "/jobs/$job_id")"
  echo "  job $job_id: $(jq -c '{state, blockedReason, paidBy}' <<<"$job" 2>/dev/null)"
  echo "  job page: $IMD_API/jobs/$job_id   explorer: https://explorer.imd.fun/jobs/$job_id (path unverified)"
  launch_id="$(jq -r '.launch | if type == "object" then (.id // .launchId // empty) elif type == "string" then . else empty end' <<<"$job" 2>/dev/null || true)"
  if [[ -z "$launch_id" && -n "$commit" ]]; then
    launch_id="$(api_get "/launches?limit=100" | jq -r --arg c "$commit" \
      '[.launches[]? | select((.sourceCommit // "") as $s | $s != "" and ($c | startswith($s | rtrimstr("…")))) | .id][0] // empty' 2>/dev/null || true)"
  fi
  [[ -n "$launch_id" ]] || {
    echo "  no launch record yet (builds take 35-65 min)"
    return 1
  }
  launch="$(api_get "/launches/$launch_id")"
  status="$(jq -r '.status // empty' <<<"$launch")"
  number="$(jq -r '.launchNumber // empty' <<<"$launch")"
  echo "  launch $launch_id: number #$number, status $status, chain $(jq -r '.chainId // empty' <<<"$launch")"
  echo "  record: $IMD_API/launches/$launch_id"
  echo "$launch" >"$STATE_DIR/launch.json"
  echo "$number" >"$STATE_DIR/launch-number"
  jq -c '{artifacts: [.artifacts[]? | {role, name, address, txHash}], addresses, transactions}' <<<"$launch" 2>/dev/null || true
  # Candidate addresses anywhere in artifacts (where api.imd.fun/launches/<id> lists deployed
  # contracts, checked 21 Oct 2026), addresses or attestation; keep the one that is an OuroborosPress.
  addrs="$(jq -r '[(.artifacts, .addresses, .attestation) | .. | strings | select(test("^0x[0-9a-fA-F]{40}$"))] | unique | .[]' <<<"$launch" 2>/dev/null || true)"
  for a in $addrs; do
    if verify_press "$a"; then
      echo "$a" >"$STATE_DIR/press-address"
      echo "  OuroborosPress deployed at $a (code present, intake() and imd() match). Saved $STATE_DIR/press-address"
      break
    fi
  done
  case "$status" in
    live | deployed | parked | failed | refused) return 0 ;;
  esac
  return 1
}

if [[ -n "${WATCH:-}" ]]; then
  until once; do sleep 60; done
else
  once || true
fi
