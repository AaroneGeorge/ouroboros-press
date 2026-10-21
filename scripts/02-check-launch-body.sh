#!/usr/bin/env bash
# 02-check-launch-body.sh: build the launch.open body (evm_contracts on 4663 from the imported
# repo) and run the free POST /requests/check. Saves .state/launch-body.json only when blockers
# is []. Exit 1 otherwise.
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need curl jq
load_env
[[ -f "$STATE_DIR/import.json" ]] || die "run scripts/01-import.sh first"
repo="$(jq -r '.source.repoUrl' "$STATE_DIR/import.json")"
commit="$(jq -r '.source.baseCommit' "$STATE_DIR/import.json")"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "bad baseCommit in import.json"

objective="Ouroboros Press: an ownerless contract on Robinhood Chain (4663) that is itself a paying customer of IMD Intake v2. Anyone calls commission(); the contract pays Intake v2 exactly 0.5 IMD from its own balance for one research-report job (job.open@job-1) asking the swarm to write chapter N of a book about the contract itself, and the writer's callback onResult (0x4374622e) records the result hash; onFailure (0x5a0df71e) clears a refused or failed request; reset() frees a request with no answer after 6 hours. Deploy the OuroborosPress contract from this repository as it arrived: evm_contracts, no token, no pool, zero constructor arguments (Intake v2 0xa43e6f75ee006411f79ac1c84120606c2330de82 and IMD 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127 are constants in the source), nothing called after deployment. Do not edit src/ unless an audit finding reproduces. There is no owner, admin, upgrade, pause, withdraw or selfdestruct: setIntake is gated by STEWARD = address(0) and can never be called, and IMD leaves the contract only as the 0.5 IMD Intake price and a 0.02 IMD bounty to the commissioner of a delivered chapter. Tests: forge test (offline; mocks deployed at the real addresses) and an optional Robinhood fork suite; see README.md and THREAT-MODEL.md."

body="$(jq -cn --arg o "$objective" --arg r "$repo" --arg c "$commit" \
  '{objective:$o, repoUrl:$r, baseCommit:$c, onchain:"evm_contracts", chainId:4663, contracts:["OuroborosPress"], shape:"chain", steps:[{skill:"audit-imported-code"}]}')"
echo "launch body ($(printf '%s' "$body" | wc -c | tr -d ' ') bytes):"
echo "$body" | jq .
echo "POST $IMD_API/requests/check (free)"
if check_body launch.open "$body"; then
  printf '%s' "$body" >"$STATE_DIR/launch-body.json"
  echo "PASS: blockers is []. Saved $STATE_DIR/launch-body.json."
  echo "Read the plan above: expect the manifest ("Write what to deploy"), audit-imported-code, then "Deploy on Robinhood Chain"."
else
  echo "FAIL: fix the blockers above before paying (full response: $STATE_DIR/last-check-launch.open.json)"
  exit 1
fi
