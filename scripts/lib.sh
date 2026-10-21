#!/usr/bin/env bash
# Shared helpers for scripts/NN-*.sh. Sourced, never executed.
#
# Settings come from ENV_FILE, outside the repo (default below). To use another file:
#   ENV_FILE=/path/to/file scripts/NN-*.sh
# Expected keys:
#   KEYSTORE_ACCOUNT=ouroboros   recommended: a foundry keystore (scripts/00-wallet.sh new-keystore);
#                                then WALLET_ADDRESS is required
#   WALLET_ADDRESS=0x...         required with KEYSTORE_ACCOUNT, optional with PRIVATE_KEY (cross-checked)
#   PRIVATE_KEY=0x...            fallback: a temp wallet key, used only when KEYSTORE_ACCOUNT is unset
#   RH_RPC=https://...           optional, default https://rpc.mainnet.chain.robinhood.com
#   RH_EXPLORER=https://...      optional, default https://robinhoodchain.blockscout.com
#   GITHUB_REPO_URL=https://github.com/<owner>/<repo>
#   PROJECT_X_HANDLE=@handle
#   PRESS=0x...                  optional: the deployed OuroborosPress (else .state/press-address).
#                                PRESS=0x... given on the command line wins over the file.
#
# The file is read as KEY=value lines (quotes and trailing "# comments" allowed). It is never executed,
# and a line that is not KEY=value is skipped without echoing it (so a key pasted on a line of its own
# is not printed in an error). PRIVATE_KEY is kept out of child processes' environment.
#
# Rules kept by every script: the key is never printed, never written anywhere, and reaches only
# cast's --private-key flag; every write prints the exact transaction and sends only with CONFIRM=yes.

set -euo pipefail
set +x

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-/Users/aarone/programs/projects/hackathons/01-identity-md/.env}"
STATE_DIR="$REPO_DIR/.state"

CHAIN_ID=4663
INTAKE=0xa43e6f75ee006411f79ac1c84120606c2330de82
IMD=0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127
PRICE=500000000000000000   # 0.5 IMD, Intake v2's price per action
BOUNTY=20000000000000000   # 0.02 IMD, OuroborosPress.BOUNTY
IMD_API="${IMD_API:-https://api.imd.fun}"
NO_CALLBACK='(0x0000000000000000000000000000000000000000,0x00000000)'
EXPLORER="${RH_EXPLORER:-https://robinhoodchain.blockscout.com}"

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
  done
}

_ENV_SKIP_RE='^[[:space:]]*(#.*)?$'
_ENV_LINE_RE='^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$'
_ENV_DQ_RE='^"([^"]*)"'
_ENV_SQ_RE="^'([^']*)'"

load_env() {
  local _cli_press="${PRESS:-}" _line _k _v _n=0
  if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r _line || [[ -n "$_line" ]]; do
      _n=$((_n + 1))
      _line="${_line%$'\r'}"
      [[ "$_line" =~ $_ENV_SKIP_RE ]] && continue
      if ! [[ "$_line" =~ $_ENV_LINE_RE ]]; then
        echo "warning: $ENV_FILE line $_n is not KEY=value; skipped (its text is not shown)" >&2
        continue
      fi
      _k="${BASH_REMATCH[2]}"
      _v="${BASH_REMATCH[3]}"
      if [[ "$_v" =~ $_ENV_DQ_RE || "$_v" =~ $_ENV_SQ_RE ]]; then
        _v="${BASH_REMATCH[1]}"
      else
        _v="${_v%%[[:space:]]#*}"
        _v="${_v%"${_v##*[![:space:]]}"}"
      fi
      case "$_k" in
        PATH | IFS | HOME | SHELL | ENV | BASH* | PS4 | SHELLOPTS | _* | \
          CHAIN_ID | INTAKE | IMD | PRICE | BOUNTY | NO_CALLBACK | REPO_DIR | STATE_DIR | ENV_FILE | \
          SIGNER_ARGS | SIGNER_DESC | FROM | CONFIRM)
          echo "warning: $ENV_FILE line $_n sets reserved name $_k; skipped" >&2
          continue
          ;;
      esac
      if ! printf -v "$_k" '%s' "$_v" 2>/dev/null; then
        echo "warning: $ENV_FILE line $_n: cannot set $_k; skipped" >&2
        continue
      fi
      if [[ "$_k" == "PRIVATE_KEY" ]]; then
        export -n PRIVATE_KEY
      else
        export "${_k?}"
      fi
    done <"$ENV_FILE"
  fi
  if [[ -n "$_cli_press" ]]; then PRESS="$_cli_press"; fi
  RH_RPC="${RH_RPC:-https://rpc.mainnet.chain.robinhood.com}"
  EXPLORER="${RH_EXPLORER:-https://robinhoodchain.blockscout.com}"
  mkdir -p "$STATE_DIR"
}

require_env_file() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Create it yourself (see RUNBOOK.md, step 0); scripts never create it."
}

check_chain() {
  local id
  id="$(cast chain-id --rpc-url "$RH_RPC" 2>/dev/null)" || die "RPC $RH_RPC unreachable"
  [[ "$id" == "$CHAIN_ID" ]] || die "RPC $RH_RPC is chain $id, expected $CHAIN_ID (Robinhood Chain)"
}

# Sets SIGNER_ARGS (never printed), SIGNER_DESC (safe to print) and FROM.
SIGNER_ARGS=()
SIGNER_DESC=""
FROM=""
setup_signer() {
  require_env_file
  if [[ -n "${KEYSTORE_ACCOUNT:-}" ]]; then
    [[ -n "${WALLET_ADDRESS:-}" ]] || die "KEYSTORE_ACCOUNT is set: also set WALLET_ADDRESS in $ENV_FILE"
    SIGNER_ARGS=(--account "$KEYSTORE_ACCOUNT")
    SIGNER_DESC="foundry keystore account '$KEYSTORE_ACCOUNT' (password prompt)"
    FROM="$WALLET_ADDRESS"
  elif [[ -n "${PRIVATE_KEY:-}" ]]; then
    SIGNER_ARGS=(--private-key "$PRIVATE_KEY")
    SIGNER_DESC="PRIVATE_KEY from $ENV_FILE (not shown)"
    FROM="$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)" || die "PRIVATE_KEY in $ENV_FILE is not a valid key"
    if [[ -n "${WALLET_ADDRESS:-}" ]]; then
      [[ "$(lower "$FROM")" == "$(lower "$WALLET_ADDRESS")" ]] || die "WALLET_ADDRESS does not match PRIVATE_KEY"
    fi
  else
    die "set KEYSTORE_ACCOUNT + WALLET_ADDRESS (or PRIVATE_KEY) in $ENV_FILE"
  fi
}

# The wallet address without needing the key (read-only scripts).
wallet_address() {
  if [[ -n "${WALLET_ADDRESS:-}" ]]; then
    echo "$WALLET_ADDRESS"
  elif [[ -n "${PRIVATE_KEY:-}" ]]; then
    cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || die "PRIVATE_KEY in $ENV_FILE is not a valid key"
  else
    die "set WALLET_ADDRESS (or PRIVATE_KEY) in $ENV_FILE"
  fi
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

press_address() {
  local p="${PRESS:-}"
  if [[ -z "$p" && -f "$STATE_DIR/press-address" ]]; then
    p="$(tr -d '[:space:]' <"$STATE_DIR/press-address")"
  fi
  [[ -n "$p" ]] || die "no press address: set PRESS=0x... or run 05-watch-launch.sh"
  [[ "$p" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "press address '$p' (PRESS or .state/press-address) is not 0x + 40 hex digits"
  echo "$p"
}

# wei -> decimal IMD/ETH string
fmt18() {
  cast from-wei "$1" 2>/dev/null || echo "$1 wei"
}

# First word of a cast call result ("123 [1.23e2]" -> "123").
first() {
  awk '{print $1}'
}

# Exact arithmetic on wei amounts of any size (bash integers overflow above about 9.2e18).
calc() {
  BC_LINE_LENGTH=0 bc <<<"$1"
}
# ge A B: true when A >= B.
ge() {
  [[ "$(calc "$1 >= $2")" == "1" ]]
}
# dec EXPR [SCALE]: decimal result with a leading zero ("0.0024", not ".0024").
dec() {
  local x
  x="$(calc "scale=${2:-6}; $1")"
  case "$x" in
    .*) x="0$x" ;;
    -.*) x="-0${x#-}" ;;
  esac
  echo "$x"
}

# Epoch seconds -> 2026-10-21T14:00:00Z; seconds -> "1 h 5 min".
utc() {
  date -u -r "$1" +%FT%TZ 2>/dev/null || date -u -d "@$1" +%FT%TZ 2>/dev/null || echo "$1"
}
dur() {
  local s="$1"
  ((s < 0)) && s=$((-s))
  if ((s >= 3600)); then
    echo "$((s / 3600)) h $((s % 3600 / 60)) min"
  elif ((s >= 60)); then
    echo "$((s / 60)) min"
  else
    echo "$s s"
  fi
}

# fetch_imd_price: prints "<ETH per IMD> <USD per IMD> <source>" for the deepest IMD/ETH pair on
# Robinhood Chain, read from Dexscreener with a 10 s timeout, or "unknown" when that fails.
# IMD_PRICE_ETH=<ETH per IMD> skips the fetch (offline use).
fetch_imd_price() {
  local out=""
  if [[ -n "${IMD_PRICE_ETH:-}" ]]; then
    if [[ "$IMD_PRICE_ETH" =~ ^[0-9]*\.?[0-9]+$ ]]; then
      echo "$IMD_PRICE_ETH unknown IMD_PRICE_ETH(set-by-hand)"
    else
      echo "unknown"
    fi
    return 0
  fi
  out="$(curl -fsS --max-time 10 "https://api.dexscreener.com/latest/dex/tokens/$IMD" 2>/dev/null |
    jq -r --arg imd "$IMD" '
      [.pairs[]? | select(.chainId == "robinhood"
        and ((.baseToken.address // "") | ascii_downcase) == $imd
        and ((.quoteToken.symbol // "") | test("^W?ETH$")))]
      | max_by(.liquidity.usd // 0) // empty
      | "\(.priceNative) \(.priceUsd // "unknown") dexscreener:\(.pairAddress)"' 2>/dev/null)" || true
  if [[ "$out" =~ ^[0-9]*\.?[0-9]+\ [^\ ]+\ [^\ ]+$ ]]; then
    echo "$out"
  else
    echo "unknown"
  fi
}

api_get() {
  curl -sS --max-time 60 "$IMD_API$1"
}

api_post() {
  # $1 path, $2 JSON
  curl -sS --max-time 60 -X POST "$IMD_API$1" -H 'Content-Type: application/json' --data-binary "$2"
}

# For each "<chapter> <request tx>" line of .state/commissions.log: Intake state, request id, IMD job
# UUID, completion and callback tx, with explorer links. Read-only. Used by 08-status.sh and 12-demo.sh.
print_commissions() {
  local n tx entry job cb
  if [[ ! -f "$STATE_DIR/commissions.log" ]]; then
    echo "(no .state/commissions.log yet)"
    return 0
  fi
  echo "commissions (request tx -> job -> callback):"
  while read -r n tx; do
    [[ -n "${tx:-}" ]] || continue
    entry="$(api_get "/intake/$CHAIN_ID/$tx" | jq -c '.entries[0] // empty' 2>/dev/null || true)"
    echo "  chapter $n request tx: $tx  ($EXPLORER/tx/$tx)"
    if [[ -z "$entry" ]]; then
      echo "    intake has not read it yet"
      continue
    fi
    job="$(jq -r '.admission.result.jobId // empty' <<<"$entry")"
    echo "    state      : $(jq -r '.state' <<<"$entry")  reason: $(jq -r '.reason // "-"' <<<"$entry")"
    echo "    requestId  : $(jq -r '.requestId' <<<"$entry")"
    echo "    job UUID   : ${job:--}  ${job:+$IMD_API/jobs/$job  https://explorer.imd.fun/jobs/$job (path unverified)}"
    echo "    completion : $(jq -c '.completion // null' <<<"$entry")"
    cb="$(jq -r '.completion.txHash // empty' <<<"$entry")"
    if [[ -n "$cb" ]]; then
      echo "    callback tx: $cb  ($EXPLORER/tx/$cb)"
    fi
  done <"$STATE_DIR/commissions.log"
  return 0
}

# Prints a transaction block. Args: to, signature, then args...; VALUE env (default 0).
print_tx() {
  local to="$1" sig="$2"
  shift 2
  echo "-------------------------------------------------------------------------------"
  echo " transaction (chain $CHAIN_ID, RPC $RH_RPC)"
  echo "   from     : $FROM"
  echo "   signer   : $SIGNER_DESC"
  echo "   to       : $to"
  echo "   function : $sig"
  local i=1 a
  for a in "$@"; do
    if ((${#a} > 200)); then
      echo "   arg $i    : ${a:0:120}... (${#a} chars)"
    else
      echo "   arg $i    : $a"
    fi
    i=$((i + 1))
  done
  echo "   value    : ${VALUE:-0} wei"
  echo "-------------------------------------------------------------------------------"
}

confirm_or_exit() {
  if [[ "${CONFIRM:-}" != "yes" ]]; then
    echo "Dry run: nothing sent. Re-run with CONFIRM=yes to send exactly this transaction."
    exit 0
  fi
}

# Sends with cast; prints and returns the tx hash. Args as print_tx.
send_tx() {
  local to="$1" sig="$2" out hash status
  shift 2
  out="$(cast send "$to" "$sig" "$@" --value "${VALUE:-0}" --rpc-url "$RH_RPC" "${SIGNER_ARGS[@]}" --json)" ||
    die "cast send failed"
  hash="$(jq -r '.transactionHash' <<<"$out")"
  status="$(jq -r '.status' <<<"$out")"
  echo "sent: $hash (status $status)" >&2
  [[ "$status" == "0x1" || "$status" == "1" ]] || die "transaction reverted: $hash"
  echo "$hash"
}

# POST /requests/check; prints a summary; returns 0 only when blockers is [].
# Args: action (job.open | launch.open), body JSON (compact)
check_body() {
  local action="$1" body="$2" payload resp blockers
  payload="$(jq -cn --arg a "$action" --argjson b "$body" '{action:$a,input:$b}')" || die "body is not valid JSON"
  resp="$(api_post /requests/check "$payload")" || die "POST /requests/check failed"
  echo "$resp" >"$STATE_DIR/last-check-$action.json"
  jq -c '{action, kind, blockers, suggestions, plan: [.plan[]? | (.skill // .title)]}' <<<"$resp" 2>/dev/null ||
    echo "$resp"
  blockers="$(jq -c '.blockers // "missing"' <<<"$resp" 2>/dev/null || echo '"unparseable"')"
  [[ "$blockers" == "[]" ]]
}
