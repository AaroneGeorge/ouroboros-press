#!/usr/bin/env bash
# 07-commission.sh: order the next chapter. Checks the press is idle, out of cool-down, funded
# (>= 0.52 IMD) and that the previous chapter is inscribed (else run 09-inscribe.sh); runs the
# free POST /requests/check on the exact on-chain previewBody() and refuses to send unless
# blockers is []; simulates; prints the transaction; sends only with CONFIRM=yes.
# Appends "<chapter> <tx>" to .state/commissions.log.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq curl
load_env
setup_signer
check_chain
press="$(press_address)"

busy="$(cast call "$press" 'busy()(bool)' --rpc-url "$RH_RPC")"
count="$(cast call "$press" 'chapterCount()(uint256)' --rpc-url "$RH_RPC" | first)"
cool="$(cast call "$press" 'cooldownUntil()(uint48)' --rpc-url "$RH_RPC" | first)"
bal="$(cast call "$IMD" 'balanceOf(address)(uint256)' "$press" --rpc-url "$RH_RPC" | first)"
now="$(date +%s)"
n=$((count + 1))
echo "press $press: chapters $count, busy $busy, cooldownUntil $cool, balance $(fmt18 "$bal") IMD"
[[ "$busy" == "false" ]] || die "a chapter is pending: wait for the callback or, after 6 h, reset() (see RUNBOOK.md)"
((cool <= now)) || die "cooling down until $(date -u -r "$cool" +%FT%TZ 2>/dev/null || echo "$cool") after a failure"
awk -v a="$bal" -v p="$((PRICE + BOUNTY))" 'BEGIN { exit !(a >= p) }' || die "press holds less than 0.52 IMD: run 06-fund-contract.sh"
if ((count > 0)); then
  ins="$(cast call "$press" 'isInscribed(uint256)(bool)' "$count" --rpc-url "$RH_RPC")"
  [[ "$ins" == "true" ]] || die "chapter $count is not inscribed yet: run scripts/09-inscribe.sh $count"
fi

echo "checking the exact body chapter $n will send:"
PRESS="$press" "$(dirname "$0")/02b-check-job-body.sh" || die "the job body does not pass /requests/check; not sending"

print_tx "$press" 'commission()'
sim="$(cast call --from "$FROM" "$press" 'commission()(bytes32)' --rpc-url "$RH_RPC")" || die "simulation reverted"
echo "simulation: ok, requestId would be $sim"
confirm_or_exit
hash="$(send_tx "$press" 'commission()')"
echo "$n $hash" >>"$STATE_DIR/commissions.log"
echo "commission tx (chapter $n): $hash"
echo "follow it: scripts/08-status.sh   (callbacks take 10-60 min)"
