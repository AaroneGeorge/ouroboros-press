#!/usr/bin/env bash
# 04-launch.sh: pay Intake v2 0.5 IMD for launch.open@launch-1 with the checked body from
# .state/launch-body.json, with no callback (allowed from a wallet: (address(0), 0x00000000)).
# Re-runs the free check first and refuses to send if blockers is not [].
# Prints the transaction; sends only with CONFIRM=yes. Saves .state/launch-tx.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq curl
load_env
setup_signer
check_chain
[[ -f "$STATE_DIR/launch-body.json" ]] || die "run scripts/02-check-launch-body.sh first"
body="$(cat "$STATE_DIR/launch-body.json")"
check_body launch.open "$body" || die "the check now reports blockers; not sending"

action="$(cast format-bytes32-string 'launch.open@launch-1')"
data="$(cast from-utf8 "$body")"
balance="$(cast call "$IMD" 'balanceOf(address)(uint256)' "$FROM" --rpc-url "$RH_RPC" | first)"
allowance="$(cast call "$IMD" 'allowance(address,address)(uint256)' "$FROM" "$INTAKE" --rpc-url "$RH_RPC" | first)"
awk -v a="$balance" -v p="$PRICE" 'BEGIN { exit !(a >= p) }' || die "wallet holds $(fmt18 "$balance") IMD, needs 0.5"
awk -v a="$allowance" -v p="$PRICE" 'BEGIN { exit !(a >= p) }' || die "allowance $(fmt18 "$allowance") < 0.5 IMD: run 03-approve-intake.sh"

sig='request(bytes32,bytes,(address,bytes4),address,uint256)'
echo "body: $(printf '%s' "$body" | wc -c | tr -d ' ') bytes, keccak $(cast keccak "$body")"
echo "action launch.open@launch-1 = $action"
print_tx "$INTAKE" "$sig" "$action" "$data" "$NO_CALLBACK" "$IMD" "$PRICE"
sim="$(cast call --from "$FROM" "$INTAKE" "$sig(bytes32)" "$action" "$data" "$NO_CALLBACK" "$IMD" "$PRICE" --rpc-url "$RH_RPC")" ||
  die "simulation reverted"
echo "simulation: ok, requestId would be $sim"
confirm_or_exit
hash="$(send_tx "$INTAKE" "$sig" "$action" "$data" "$NO_CALLBACK" "$IMD" "$PRICE")"
echo "$hash" >"$STATE_DIR/launch-tx"
echo "$(date -u +%FT%TZ) $hash" >>"$STATE_DIR/launch-history.log"
echo "launch request tx: $hash"
echo "follow it: scripts/05-watch-launch.sh   (or $IMD_API/intake/$CHAIN_ID/$hash)"
