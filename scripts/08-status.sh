#!/usr/bin/env bash
# 08-status.sh: the evidence set. Press state, every chapter on chain, and for each commission
# in .state/commissions.log: request tx, Intake request id, IMD job UUID, callback tx, uri.
# Read-only. scripts/12-demo.sh narrates the same evidence for a judge or a video.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq curl
load_env
check_chain
press="$(press_address)"
explorer="$EXPLORER"
call() { cast call "$press" "$@" --rpc-url "$RH_RPC"; }

count="$(call 'chapterCount()(uint256)' | first)"
echo "OuroborosPress $press  ($explorer/address/$press)"
echo "  launch number    : $(cat "$STATE_DIR/launch-number" 2>/dev/null || echo '?')"
echo "  IMD balance      : $(fmt18 "$(cast call "$IMD" 'balanceOf(address)(uint256)' "$press" --rpc-url "$RH_RPC" | first)")"
echo "  chapters         : $count"
echo "  busy             : $(call 'busy()(bool)')"
echo "  pendingRequest   : $(call 'pendingRequest()(bytes32)')"
echo "  pendingSince     : $(call 'pendingSince()(uint64)' | first)"
echo "  pendingCommiss.  : $(call 'pendingCommissioner()(address)')"
echo "  failures         : $(call 'failures()(uint256)' | first)  last reason: $(cast parse-bytes32-string "$(call 'lastFailureReason()(bytes32)')" 2>/dev/null || true)"
echo "  cooldownUntil    : $(call 'cooldownUntil()(uint48)' | first)"
for ((n = 1; n <= count; n++)); do
  echo "  chapter $n: $(call 'chapter(uint256)((bytes32,bytes32,bytes32,address,uint48,uint48,string))' "$n")"
  echo "    inscribed: $(call 'isInscribed(uint256)(bool)' "$n")"
done

echo
print_commissions
