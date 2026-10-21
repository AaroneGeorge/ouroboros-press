#!/usr/bin/env bash
# 10-verify.sh: verify the press source on Robinhood Chain's Blockscout if the launch factory did
# not. Prints the exact command; runs it only with CONFIRM=yes. Not a transaction (no key used).
# RH_EXPLORER defaults to https://robinhoodchain.blockscout.com (unverified, see REPORT.md).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need forge
load_env
press="$(press_address)"
explorer="${RH_EXPLORER:-https://robinhoodchain.blockscout.com}"
cmd=(forge verify-contract "$press" src/OuroborosPress.sol:OuroborosPress
  --chain-id "$CHAIN_ID" --verifier blockscout --verifier-url "$explorer/api/" --watch)
echo "cd $REPO_DIR && ${cmd[*]}"
echo "(compiler settings come from foundry.toml: solc 0.8.26, cancun, optimizer 200 runs, via_ir off,"
echo " bytecode_hash none, cbor_metadata false; zero constructor arguments)"
confirm_or_exit
cd "$REPO_DIR" && "${cmd[@]}"
