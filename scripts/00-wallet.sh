#!/usr/bin/env bash
# 00-wallet.sh: is the launch wallet ready? Prints its address, ETH and IMD on Robinhood Chain, its
# IMD allowance to Intake v2, what its IMD pays for, and a verdict. Read-only; never prints the key.
#
#   scripts/00-wallet.sh                      status of the wallet in .env (WALLET_ADDRESS, else PRIVATE_KEY)
#   scripts/00-wallet.sh new-keystore [name]  create a fresh encrypted foundry keystore (default name
#                                             "ouroboros"); cast asks for a password; the key is never shown
#
# ETH: needs MIN_ETH = max(0.0002 ETH, live gas price x 2,000,000 gas x 5): about ten transactions of
#      up to 400k gas, with a five-fold margin. MIN_ETH_WEI=<wei> overrides it.
# IMD: launch 0.5; one park retry 0.5; each chapter 0.52 (0.5 price + 0.02 bounty), sent to the press.
#      READY (launch + N chapters) from 1.02 IMD; READY (launch + retry + N chapters) from 1.52 IMD.
# Swap estimates use the deepest IMD/ETH pair on Dexscreener, plus 2 % for the 1 % pool fee and
# slippage. IMD_PRICE_ETH=<ETH per IMD> sets the price by hand; offline the estimate reads "unknown".
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq curl bc
load_env

LAUNCH=$PRICE                   # 0.5 IMD
CHAPTER=$((PRICE + BOUNTY))     # 0.52 IMD
MIN_ETH_FLOOR=200000000000000   # 0.0002 ETH
GAS_BUDGET=2000000              # about ten transactions, none above about 400k gas
GAS_MARGIN=5

# amt WEI [DECIMALS]: wei -> decimal, trailing zeros trimmed ("1.52", "0.00020034", "0").
amt() {
  dec "$1 / 10^18" "${2:-6}" | sed -E 's/(\.[0-9]*[1-9])0+$/\1/; s/\.0+$//'
}
plural() {
  if [[ "$1" == "1" ]]; then echo "1 chapter"; else echo "$1 chapters"; fi
}

# ------------------------------------------------------------------ new-keystore
if [[ "${1:-}" == "new-keystore" ]]; then
  name="${2:-ouroboros}"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "keystore name: letters, digits, - and _ only"
  dir="${KEYSTORE_DIR:-$HOME/.foundry/keystores}"
  if [[ -e "$dir/$name" ]]; then
    die "keystore '$name' already exists ($dir/$name) and may hold funds, so it is never overwritten.
  Its address: cast wallet address --account $name   (asks for its password)
  A new one:   scripts/00-wallet.sh new-keystore <other-name>"
  fi
  if [[ "$dir" != "$HOME/.foundry/keystores" ]]; then
    echo "note: KEYSTORE_DIR=$dir is not ~/.foundry/keystores, so cast --account will not find it (tests only)." >&2
  fi
  mkdir -p "$dir"
  out="$(mktemp)"
  trap 'rm -f "$out"' EXIT
  echo "Creating encrypted keystore '$name' in $dir."
  echo "cast now asks for a password (typed blind). The private key is never shown."
  # In keystore mode cast prints only the file path and the address; the sed drops any 64-hex line anyway.
  cast wallet new "$dir" "$name" | sed -E '/[0-9a-fA-F]{64}/d' | tee "$out" || die "cast wallet new failed"
  addr="$(grep -oE '0x[0-9a-fA-F]{40}' "$out" | head -n 1 || true)"
  [[ -n "$addr" ]] || die "keystore written but no address printed: run cast wallet address --account $name"
  cat <<STEPS

Keystore '$name' created. Its address is the launch wallet:
    $addr
It pays the launch, so it is the launch's paidBy and receives any prize.

Next, three steps:
  1. In MetaMask, on Robinhood Chain (4663), send to $addr:
       a. first all your IMD (token 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127, name "Identity.md");
       b. then the leftover ETH (MetaMask's Max keeps back the gas for that send).
     Each send costs a fraction of a cent in gas. Compare the address character by character.
  2. Put exactly these two lines in $ENV_FILE (no PRIVATE_KEY line), then chmod 600 it:
       KEYSTORE_ACCOUNT=$name
       WALLET_ADDRESS=$addr
  3. Run scripts/00-wallet.sh again: expect READY.

Back up $dir/$name and keep the password: without both, this wallet and any prize are lost.
STEPS
  exit 0
fi
[[ -z "${1:-}" ]] || die "usage: scripts/00-wallet.sh [new-keystore [name]]"

# ------------------------------------------------------------------ status
require_env_file
check_chain
addr="$(wallet_address)"
[[ "$addr" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "the wallet address from $ENV_FILE is not a 0x address"
eth="$(cast balance "$addr" --rpc-url "$RH_RPC" 2>/dev/null | first)" || die "could not read the ETH balance"
imd="$(cast call "$IMD" 'balanceOf(address)(uint256)' "$addr" --rpc-url "$RH_RPC" 2>/dev/null | first)" ||
  die "could not read the IMD balance"
allow="$(cast call "$IMD" 'allowance(address,address)(uint256)' "$addr" "$INTAKE" --rpc-url "$RH_RPC" 2>/dev/null | first)" ||
  die "could not read the IMD allowance"
sym="$(cast call "$IMD" 'symbol()(string)' --rpc-url "$RH_RPC" 2>/dev/null | tr -d '"' || echo '?')"
decimals="$(cast call "$IMD" 'decimals()(uint8)' --rpc-url "$RH_RPC" 2>/dev/null | first || echo '?')"
gas="$(cast gas-price --rpc-url "$RH_RPC" 2>/dev/null | first || true)"
[[ "$eth" =~ ^[0-9]+$ && "$imd" =~ ^[0-9]+$ ]] || die "unexpected balance output from cast"

if [[ -n "${KEYSTORE_ACCOUNT:-}" ]]; then
  if [[ -f "$HOME/.foundry/keystores/$KEYSTORE_ACCOUNT" ]]; then
    signer="foundry keystore '$KEYSTORE_ACCOUNT' (file present; password asked at each send)"
  else
    signer="foundry keystore '$KEYSTORE_ACCOUNT' (WARNING: no file ~/.foundry/keystores/$KEYSTORE_ACCOUNT)"
  fi
elif [[ -n "${PRIVATE_KEY:-}" ]]; then
  signer="PRIVATE_KEY in $ENV_FILE (fallback; not shown)"
else
  signer="none (WALLET_ADDRESS only: fine for this check, the write scripts need a signer)"
fi

read -r p_eth p_usd p_src <<<"$(fetch_imd_price)"
price_at="$(date -u +%FT%TZ)"
eth_usd=""
if [[ "$p_eth" != "unknown" && "${p_usd:-}" =~ ^[0-9]*\.?[0-9]+$ ]]; then
  eth_usd="$(dec "$p_usd / $p_eth" 2)"
fi
usd() { # usd ETH_WEI -> " (≈ $x.xx)" when the ETH price is known
  [[ -n "$eth_usd" ]] && echo " (≈ \$$(dec "$1 * $eth_usd / 10^18" 2))"
  return 0
}

# ETH reserve
if [[ -n "${MIN_ETH_WEI:-}" ]]; then
  [[ "$MIN_ETH_WEI" =~ ^[0-9]+$ ]] || die "MIN_ETH_WEI must be an integer in wei"
  min_eth="$MIN_ETH_WEI"
  min_why="MIN_ETH_WEI, set by hand"
elif [[ "$gas" =~ ^[0-9]+$ ]]; then
  g="$(calc "$gas * $GAS_BUDGET * $GAS_MARGIN")"
  if ge "$g" "$MIN_ETH_FLOOR"; then min_eth="$g"; else min_eth="$MIN_ETH_FLOOR"; fi
  min_why="max(0.0002, $(dec "$gas / 10^9" 6) gwei x 2,000,000 gas x 5)"
else
  min_eth="$MIN_ETH_FLOOR"
  min_why="gas price unreadable, so the 0.0002 ETH floor"
fi

echo "wallet            : $addr  ($EXPLORER/address/$addr)"
echo "signer            : $signer"
echo "chain             : $CHAIN_ID via $RH_RPC, gas price ${gas:-?} wei ($(dec "${gas:-0} / 10^9" 6) gwei)"
echo "ETH               : $(amt "$eth" 8)$(usd "$eth")"
echo "IMD ($sym, $decimals dec): $(amt "$imd")"
echo "allowance->Intake : $(amt "$allow") IMD"
echo "github repo       : ${GITHUB_REPO_URL:-<unset>}"
echo "project X handle  : ${PROJECT_X_HANDLE:-<unset>}"
if [[ "$p_eth" == "unknown" ]]; then
  echo "IMD price         : unknown (Dexscreener unreachable at $price_at; set IMD_PRICE_ETH=<ETH per IMD> to estimate)"
else
  usd_part=""
  [[ "${p_usd:-}" =~ ^[0-9]*\.?[0-9]+$ ]] && usd_part=" = \$$p_usd"
  echo "IMD price         : $p_eth ETH$usd_part per IMD (source $p_src, read $price_at; spot, not a quote)"
fi
echo
echo "ETH reserve: MIN_ETH = $min_why = $(amt "$min_eth" 8) ETH$(usd "$min_eth")"

# IMD plan
echo "IMD plan for $(amt "$imd") IMD (launch 0.5, park retry 0.5, chapter 0.52 = 0.5 price + 0.02 bounty):"
if ge "$imd" "$LAUNCH"; then
  a="$(calc "($imd - $LAUNCH) / $CHAPTER")"
  echo "  no park        : launch + $(plural "$a")  = $(amt "$(calc "$LAUNCH + $a * $CHAPTER")") IMD, $(amt "$(calc "$imd - $LAUNCH - $a * $CHAPTER")") left"
else
  a=0
  echo "  no park        : not even the launch (0.5 IMD)"
fi
if ge "$imd" "$((2 * LAUNCH))"; then
  b="$(calc "($imd - 2 * $LAUNCH) / $CHAPTER")"
  echo "  one park retry : launch + retry + $(plural "$b")  = $(amt "$(calc "2 * $LAUNCH + $b * $CHAPTER")") IMD, $(amt "$(calc "$imd - 2 * $LAUNCH - $b * $CHAPTER")") left"
else
  b=0
  echo "  one park retry : not covered (launch + retry = 1.0 IMD)"
fi
if [[ -f "$STATE_DIR/launch-tx" ]]; then
  echo "  note: .state/launch-tx exists, so a launch may already be paid. From here each chapter needs"
  echo "        0.52 IMD sent to the press ($(plural "$(calc "$imd / $CHAPTER")") covered) and a relaunch 0.5."
fi

# ETH to swap for IMD_WEI of IMD at the spot price + 2 %: "≈ X ETH (≈ $Y)", or "unknown (no price)".
swap_est() {
  local e
  if [[ "$p_eth" == "unknown" ]]; then
    echo "unknown (no price)"
    return 0
  fi
  e="$(calc "scale=18; x = $1 * $p_eth * 1.02; scale=0; x / 10^12 + 1")" # whole micro-ETH, rounded up
  echo "≈ $(amt "$(calc "$e * 10^12")" 6) ETH$(usd "$(calc "$e * 10^12")")"
}
if [[ "$p_eth" == "unknown" ]]; then
  est_note="no price, so no ETH estimate; set IMD_PRICE_ETH=<ETH per IMD> to get one"
else
  est_note="estimate: spot $p_eth ETH/IMD + 2 % for the 1 % pool fee and slippage"
fi

targets="1020000000000000000:launch + 1 chapter
1520000000000000000:launch + retry + 1 chapter
1540000000000000000:launch + 2 chapters
2040000000000000000:launch + retry + 2 chapters"
tops=""
while IFS=: read -r t label; do
  if ! ge "$imd" "$t"; then
    tops="${tops}$(printf '  %-5s IMD  %-28s needs %-11s swap %s' "$(amt "$t")" "$label" "+$(amt "$(calc "$t - $imd")") IMD" "$(swap_est "$(calc "$t - $imd")")")
"
  fi
done <<<"$targets"
if [[ -n "$tops" ]]; then
  echo "top-ups (swap ETH -> IMD on Uniswap in MetaMask, then send the IMD here; $est_note):"
  printf '%s' "$tops"
fi
echo

# verdict
eth_ok=1
ge "$eth" "$min_eth" || eth_ok=0
imd_ok=1
ge "$imd" "$((LAUNCH + CHAPTER))" || imd_ok=0
if [[ $eth_ok == 1 && $imd_ok == 1 ]]; then
  if ge "$imd" "$((2 * LAUNCH + CHAPTER))"; then
    echo "READY (launch + retry + $(plural "$b"))"
  else
    echo "READY (launch + $(plural "$a"))"
  fi
else
  echo "NOT READY"
  if [[ $eth_ok == 0 ]]; then
    short="$(calc "$min_eth - $eth")"
    echo "  ETH: have $(amt "$eth" 18), need $(amt "$min_eth" 18): short by exactly $(amt "$short" 18) ETH ($short wei)$(usd "$short")."
    echo "       Send at least that much ETH on Robinhood Chain to $addr."
  fi
  if [[ $imd_ok == 0 ]]; then
    short="$(calc "$LAUNCH + $CHAPTER - $imd")"
    echo "  IMD: have $(amt "$imd" 18), need 1.02 (launch + 1 chapter): short by exactly $(amt "$short" 18) IMD ($short wei);"
    if [[ "$p_eth" == "unknown" ]]; then
      echo "       swap amount unknown: no IMD price (set IMD_PRICE_ETH=<ETH per IMD> for an estimate)."
    else
      echo "       swap $(swap_est "$short") for IMD ($est_note)."
    fi
  fi
fi
exit 0
