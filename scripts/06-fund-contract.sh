#!/usr/bin/env bash
# 06-fund-contract.sh: run the post-deploy checks on the press, then send it IMD with a plain
# IMD.transfer. Default 0.52 IMD (one chapter: 0.5 price + 0.02 bounty). FUND_AMOUNT=<wei> to change.
# Prints the transaction; sends only with CONFIRM=yes.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq
load_env
setup_signer
check_chain
press="$(press_address)"
amount="${FUND_AMOUNT:-$((PRICE + BOUNTY))}"
[[ "$amount" =~ ^[0-9]+$ ]] || die "FUND_AMOUNT must be an integer in wei"

echo "post-deploy checks on $press:"
code="$(cast code "$press" --rpc-url "$RH_RPC")"
[[ ${#code} -gt 2 ]] || die "no code at $press"
echo "  runtime code    : $(((${#code} - 2) / 2)) bytes, codehash $(cast keccak "$code")"
i="$(cast call "$press" 'intake()(address)' --rpc-url "$RH_RPC")"
m="$(cast call "$press" 'imd()(address)' --rpc-url "$RH_RPC")"
s="$(cast call "$press" 'STEWARD()(address)' --rpc-url "$RH_RPC")"
[[ "$(lower "$i")" == "$INTAKE" ]] || die "intake() is $i, expected $INTAKE"
[[ "$(lower "$m")" == "$IMD" ]] || die "imd() is $m, expected $IMD"
[[ "$s" == "0x0000000000000000000000000000000000000000" ]] || die "STEWARD() is $s, expected address(0)"
echo "  intake()        : $i"
echo "  imd()           : $m"
echo "  STEWARD()       : $s"
echo "  chapterCount()  : $(cast call "$press" 'chapterCount()(uint256)' --rpc-url "$RH_RPC" | first)"
pb="$(cast call "$IMD" 'balanceOf(address)(uint256)' "$press" --rpc-url "$RH_RPC" | first)"
wb="$(cast call "$IMD" 'balanceOf(address)(uint256)' "$FROM" --rpc-url "$RH_RPC" | first)"
echo "  press IMD       : $(fmt18 "$pb")"
echo "  wallet IMD      : $(fmt18 "$wb")"
awk -v a="$wb" -v p="$amount" 'BEGIN { exit !(a >= p) }' || die "wallet holds less than $(fmt18 "$amount") IMD"

print_tx "$IMD" 'transfer(address,uint256)' "$press" "$amount"
cast call --from "$FROM" "$IMD" 'transfer(address,uint256)(bool)' "$press" "$amount" --rpc-url "$RH_RPC" >/dev/null ||
  die "simulation reverted"
echo "simulation: ok"
confirm_or_exit
hash="$(send_tx "$IMD" 'transfer(address,uint256)' "$press" "$amount")"
echo "$(date -u +%FT%TZ) $hash $amount" >>"$STATE_DIR/fund-history.log"
echo "fund tx: $hash"
