#!/usr/bin/env bash
# 11-reset.sh: free a commission that has had no callback for more than 6 hours (anyone may).
# The 0.5 IMD already paid is spent; a late result for it will be refused. Starts a cool-down.
# Prints the transaction; sends only with CONFIRM=yes. Appends the tx to .state/resets.log.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq
load_env
setup_signer
check_chain
press="$(press_address)"
busy="$(cast call "$press" 'busy()(bool)' --rpc-url "$RH_RPC")"
[[ "$busy" == "true" ]] || die "nothing pending"
since="$(cast call "$press" 'pendingSince()(uint64)' --rpc-url "$RH_RPC" | first)"
deadline=$((since + 6 * 3600))
now="$(date +%s)"
((now > deadline)) || die "too early: reset opens after $(date -u -r "$deadline" +%FT%TZ 2>/dev/null || echo "$deadline")"
echo "pending request $(cast call "$press" 'pendingRequest()(bytes32)' --rpc-url "$RH_RPC") since $since"
print_tx "$press" 'reset()'
cast call --from "$FROM" "$press" 'reset()' --rpc-url "$RH_RPC" >/dev/null || die "simulation reverted"
echo "simulation: ok"
confirm_or_exit
hash="$(send_tx "$press" 'reset()')"
echo "reset tx: $hash"
echo "$(date -u +%FT%TZ) $hash" >>"$STATE_DIR/resets.log"
