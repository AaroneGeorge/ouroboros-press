#!/usr/bin/env bash
# 03-approve-intake.sh: let Intake v2 pull IMD from the temp wallet for the launch payment.
# IMD has no permit. Default: exactly 0.5 IMD (one launch). APPROVE_AMOUNT=<wei> to change.
# Prints the transaction; sends only with CONFIRM=yes.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq
load_env
setup_signer
check_chain
amount="${APPROVE_AMOUNT:-$PRICE}"
[[ "$amount" =~ ^[0-9]+$ ]] || die "APPROVE_AMOUNT must be an integer in wei"
current="$(cast call "$IMD" 'allowance(address,address)(uint256)' "$FROM" "$INTAKE" --rpc-url "$RH_RPC" | first)"
balance="$(cast call "$IMD" 'balanceOf(address)(uint256)' "$FROM" --rpc-url "$RH_RPC" | first)"
echo "IMD balance $(fmt18 "$balance"), current allowance to Intake $(fmt18 "$current"), new allowance $(fmt18 "$amount")"

print_tx "$IMD" 'approve(address,uint256)' "$INTAKE" "$amount"
cast call --from "$FROM" "$IMD" 'approve(address,uint256)(bool)' "$INTAKE" "$amount" --rpc-url "$RH_RPC" >/dev/null ||
  die "simulation reverted"
echo "simulation: ok"
confirm_or_exit
hash="$(send_tx "$IMD" 'approve(address,uint256)' "$INTAKE" "$amount")"
echo "$hash" >"$STATE_DIR/approve-tx"
echo "approve tx: $hash"
