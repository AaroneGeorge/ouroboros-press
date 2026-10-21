#!/usr/bin/env bash
# 09-inscribe.sh N [URI]: copy chapter N's delivered uri into the press's storage. The uri comes
# from the Intake API (completion.uri of chapter N's commission) unless given. Checks
# keccak(uri) against the uriHash on chain first. Prints the transaction; sends only with CONFIRM=yes.
# Appends "<chapter> <tx>" to .state/inscribes.log (read by 12-demo.sh).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq curl
load_env
setup_signer
check_chain
press="$(press_address)"
n="${1:-}"
[[ "$n" =~ ^[1-9][0-9]*$ ]] || die "usage: scripts/09-inscribe.sh <chapter number> [uri]"
uri="${2:-}"
if [[ -z "$uri" ]]; then
  tx="$(awk -v n="$n" '$1 == n { t = $2 } END { print t }' "$STATE_DIR/commissions.log" 2>/dev/null || true)"
  [[ -n "$tx" ]] || die "no commission tx for chapter $n in .state/commissions.log: pass the uri"
  uri="$(api_get "/intake/$CHAIN_ID/$tx" | jq -r '.entries[0].completion.uri // empty')"
  [[ -n "$uri" ]] || die "the Intake API has no completion uri for $tx yet"
fi
rec="$(cast call "$press" 'chapter(uint256)((bytes32,bytes32,bytes32,address,uint48,uint48,string))' "$n" --rpc-url "$RH_RPC")" ||
  die "chapter $n is not delivered"
onchain_hash="$(sed -E 's/^\(([^,]+), ([^,]+), ([^,]+),.*/\3/' <<<"$rec")"
[[ "$(cast keccak "$uri")" == "$onchain_hash" ]] || die "keccak(uri) $(cast keccak "$uri") != uriHash $onchain_hash"
echo "uri: $uri (hash matches)"
print_tx "$press" 'inscribe(uint256,string)' "$n" "$uri"
cast call --from "$FROM" "$press" 'inscribe(uint256,string)' "$n" "$uri" --rpc-url "$RH_RPC" >/dev/null || die "simulation reverted"
echo "simulation: ok"
confirm_or_exit
hash="$(send_tx "$press" 'inscribe(uint256,string)' "$n" "$uri")"
echo "inscribe tx (chapter $n): $hash"
echo "$n $hash" >>"$STATE_DIR/inscribes.log"
