#!/usr/bin/env bash
# 02b-check-job-body.sh: run the free POST /requests/check on the exact job body the press sends.
#   On chain (after deployment):  PRESS=0x... scripts/02b-check-job-body.sh   (or .state/press-address)
#   Offline (before deployment):  OFFLINE=1 [PRESS_AT=0x...] [PRESS_BALANCE=wei] scripts/02b-check-job-body.sh
# Prints the body and the check summary; exit 1 unless blockers is [].
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need curl jq cast
load_env

if [[ -z "${OFFLINE:-}" ]] && { [[ -n "${PRESS:-}" ]] || [[ -f "$STATE_DIR/press-address" ]]; }; then
  press="$(press_address)"
  check_chain
  hex="$(cast call "$press" 'previewBody()(bytes)' --rpc-url "$RH_RPC")"
  echo "source: previewBody() of $press on chain $CHAIN_ID"
else
  need forge
  hex="$(cd "$REPO_DIR" && forge script script/PreviewBody.s.sol --json 2>/dev/null | tail -n 1 | jq -r '.returns.body.value')"
  echo "source: offline forge script (PRESS_AT=${PRESS_AT:-0x1111111111111111111111111111111111111111}, PRESS_BALANCE=${PRESS_BALANCE:-520000000000000000})"
fi
[[ "$hex" =~ ^0x[0-9a-fA-F]+$ ]] || die "could not read the body"
body="$(cast to-utf8 "$hex")"
printf '%s' "$body" >"$STATE_DIR/job-body.json"
echo "job body ($(printf '%s' "$body" | wc -c | tr -d ' ') bytes, saved $STATE_DIR/job-body.json):"
printf '%s\n' "$body"
echo "POST $IMD_API/requests/check {\"action\":\"job.open\",\"input\":<body>} (free)"
if check_body job.open "$body"; then
  echo "PASS: blockers is []"
else
  echo "FAIL: blockers above (full response: $STATE_DIR/last-check-job.open.json)"
  exit 1
fi
