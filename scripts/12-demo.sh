#!/usr/bin/env bash
# 12-demo.sh: narrate Ouroboros Press for a judge or a video. Read-only: no key, no transaction,
# and no .env needed when PRESS is given.
#   scripts/12-demo.sh                  the press in .state/press-address (or PRESS in .env)
#   PRESS=0x... scripts/12-demo.sh      any deployed OuroborosPress, from any checkout
#   NO_FETCH=1 scripts/12-demo.sh       skip the IPFS and artifact downloads
# Prints the chain and block; the launch; the press (wiring, price, bounty, balance, chapters); the
# pending request with its age and when reset() opens; every chapter's on-chain record, its
# result.json from IPFS checked against the resultHash on chain, and the first 60 words of the
# chapter; then every transaction recorded in .state/, with explorer links (the commissions part is
# the same as 08-status.sh). Exits 0 when nothing has launched yet.
# IPFS_GATEWAYS="https://a https://b" changes the gateway order (default: ipfs.io, dweb.link, then
# ipfs.imd.fun and gateway.pinata.cloud, because the first two now answer 429 to scripts).
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
need cast jq curl od
load_env
check_chain

WORDS=60
TIMEOUT_S=21600 # OuroborosPress.TIMEOUT, 6 hours
GATEWAYS="${IPFS_GATEWAYS:-https://ipfs.io https://dweb.link https://ipfs.imd.fun https://gateway.pinata.cloud}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT

h() {
  echo
  echo "== $*"
}
unquote() {
  tr -d '"'
}
imd_amt() { # wei -> "0.52"
  fmt18 "$1" | sed -E 's/(\.[0-9]*[1-9])0+$/\1/; s/\.0+$//'
}
sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'
}
keccak_file() {
  cast keccak "0x$(od -An -v -tx1 "$1" | tr -d ' \n')"
}
# first_words FILE: the first $WORDS words, control characters and markdown marks removed, wrapped.
first_words() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' <"$1" | sed -E 's/[*`]+//g; s/[#>|]+/ /g' | tr -s '[:space:]' ' ' |
    awk -v n="$WORDS" '{ for (i = 1; i <= NF && c < n; i++) { out = out (c ? " " : "") $i; c++ } if (NF > n) more = 1 }
      END { print out (more ? " ..." : "") }' | fold -s -w 92 | sed 's/^/      /'
}
# fetch URL FILE: GET with a 15 s timeout; fails on HTTP errors.
fetch() {
  curl -fsSL --max-time 15 --max-filesize 5000000 -o "$2" "$1" 2>/dev/null
}
# ipfs_fetch CID/PATH FILE: tries each gateway; prints the one that answered.
ipfs_fetch() {
  local gw
  for gw in $GATEWAYS; do
    if fetch "$gw/ipfs/$1" "$2"; then
      echo "$gw"
      return 0
    fi
  done
  return 1
}
# log_tx FILE KEY: the tx hash on the last line of .state/FILE whose first field is KEY.
log_tx() {
  awk -v k="$2" '$1 == k { t = $2 } END { print t }' "$STATE_DIR/$1" 2>/dev/null || true
}

# ------------------------------------------------------------------ chain
block="$(cast block latest -f number --rpc-url "$RH_RPC" 2>/dev/null || echo '?')"
now="$(cast block latest -f timestamp --rpc-url "$RH_RPC" 2>/dev/null || date +%s)"
[[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
gas="$(cast gas-price --rpc-url "$RH_RPC" 2>/dev/null || echo 0)"
echo "Ouroboros Press: a contract on Robinhood Chain that pays IMD's agent swarm to write a book about itself."
h "Chain"
echo "  Robinhood Chain, id $CHAIN_ID, block $block at $(utc "$now")  (RPC $RH_RPC)"
echo "  gas price  : $(dec "$gas / 10^9" 6) gwei"
echo "  explorer   : $EXPLORER"
intake_code="$(cast code "$INTAKE" --rpc-url "$RH_RPC" 2>/dev/null || echo 0x)"
echo "  Intake v2  : $INTAKE ($(((${#intake_code} - 2) / 2)) B of code)  $EXPLORER/address/$INTAKE"
echo "  IMD        : $IMD \"$(cast call "$IMD" 'name()(string)' --rpc-url "$RH_RPC" 2>/dev/null | unquote)\" ($(cast call "$IMD" 'symbol()(string)' --rpc-url "$RH_RPC" 2>/dev/null | unquote), $(cast call "$IMD" 'decimals()(uint8)' --rpc-url "$RH_RPC" 2>/dev/null | first) decimals)  $EXPLORER/token/$IMD"
wallet="$( (wallet_address) 2>/dev/null || true)"
if [[ "$wallet" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "  launch wallet (pays the launch = paidBy = payout): $wallet  $EXPLORER/address/$wallet"
fi

# ------------------------------------------------------------------ launch (from .state/)
h "Launch"
if [[ -s "$STATE_DIR/launch-history.log" ]]; then
  while read -r ts tx _; do
    [[ -n "${tx:-}" ]] || continue
    echo "  launch request $ts: $tx  $EXPLORER/tx/$tx"
    echo "    intake record: $IMD_API/intake/$CHAIN_ID/$tx"
  done <"$STATE_DIR/launch-history.log"
elif [[ -s "$STATE_DIR/launch-tx" ]]; then
  tx="$(tr -d '[:space:]' <"$STATE_DIR/launch-tx")"
  echo "  launch request: $tx  $EXPLORER/tx/$tx  (intake record: $IMD_API/intake/$CHAIN_ID/$tx)"
else
  echo "  no launch request recorded in .state/ (04-launch.sh writes it)"
fi
if [[ -s "$STATE_DIR/launch.json" ]]; then
  launch="$(cat "$STATE_DIR/launch.json")"
  id="$(jq -r '.id // empty' <<<"$launch" 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    live="$(api_get "/launches/$id" 2>/dev/null || true)"
    if jq -e '.id' >/dev/null 2>&1 <<<"$live"; then launch="$live"; fi
  fi
  echo "  launch #$(jq -r '.launchNumber // "?"' <<<"$launch")  status $(jq -r '.status // "?"' <<<"$launch")$(jq -r 'if .parkedReason then "  parked: \(.parkedReason)" else "" end' <<<"$launch" 2>/dev/null)"
  [[ -n "$id" ]] && echo "  launch record: $IMD_API/launches/$id"
  for tx in $(jq -r '[(.artifacts, .transactions, .attestation) | .. | strings | select(test("^0x[0-9a-fA-F]{64}$"))] | unique | .[]' <<<"$launch" 2>/dev/null || true); do
    echo "  launch tx    : $tx  $EXPLORER/tx/$tx"
  done
elif [[ -s "$STATE_DIR/launch-number" ]]; then
  echo "  launch #$(cat "$STATE_DIR/launch-number")"
fi

# ------------------------------------------------------------------ evidence (every tx in .state/)
evidence() {
  local ts tx amount n
  h "Transactions recorded in .state/ (each links to the explorer)"
  if [[ -s "$STATE_DIR/approve-tx" ]]; then
    tx="$(tr -d '[:space:]' <"$STATE_DIR/approve-tx")"
    echo "  IMD approve (launch payment): $tx  $EXPLORER/tx/$tx"
  fi
  if [[ -s "$STATE_DIR/fund-history.log" ]]; then
    while read -r ts tx amount; do
      [[ -n "${tx:-}" ]] || continue
      echo "  fund the press $ts, $(imd_amt "${amount:-0}") IMD: $tx  $EXPLORER/tx/$tx"
    done <"$STATE_DIR/fund-history.log"
  fi
  if [[ -s "$STATE_DIR/inscribes.log" ]]; then
    while read -r n tx; do
      [[ -n "${tx:-}" ]] || continue
      echo "  inscribe chapter $n: $tx  $EXPLORER/tx/$tx"
    done <"$STATE_DIR/inscribes.log"
  fi
  if [[ -s "$STATE_DIR/resets.log" ]]; then
    while read -r ts tx; do
      [[ -n "${tx:-}" ]] || continue
      echo "  reset() $ts: $tx  $EXPLORER/tx/$tx"
    done <"$STATE_DIR/resets.log"
  fi
  print_commissions | sed 's/^/  /'
}

footer() {
  echo
  echo "Read live from chain $CHAIN_ID at block $block; nothing was sent. Re-run: scripts/12-demo.sh"
}

# ------------------------------------------------------------------ the press
press=""
if [[ -n "${PRESS:-}" || -s "$STATE_DIR/press-address" ]]; then
  press="$(press_address)"
fi
if [[ -z "$press" ]]; then
  h "Press"
  echo "  not launched yet: no PRESS=0x... given and no .state/press-address (05-watch-launch.sh saves it)."
  echo "  Still readable now: Intake v2 and IMD above, the gas price, and the launch request if any."
  evidence
  footer
  exit 0
fi

h "Press $press"
code="$(cast code "$press" --rpc-url "$RH_RPC" 2>/dev/null)" || die "could not read the code at $press"
[[ ${#code} -gt 2 ]] || die "no contract at $press on chain $CHAIN_ID (wrong address, or not deployed yet)"
rcall() {
  cast call "$press" "$@" --rpc-url "$RH_RPC" 2>/dev/null
}
must() {
  rcall "$@" || die "$press: ${1%%(*}() reverted. Is this an OuroborosPress? (check the address; 05-watch-launch.sh verifies it)"
}
i="$(must 'intake()(address)')"
m="$(must 'imd()(address)')"
[[ "$(lower "$i")" == "$INTAKE" && "$(lower "$m")" == "$IMD" ]] ||
  die "$press: intake() is $i and imd() is $m, expected Intake v2 $INTAKE and IMD $IMD"
steward="$(must 'STEWARD()(address)')"
price="$(must 'PRICE()(uint256)' | first)"
bounty="$(must 'BOUNTY()(uint256)' | first)"
count="$(must 'chapterCount()(uint256)' | first)"
busy="$(must 'busy()(bool)')"
failures="$(must 'failures()(uint256)' | first)"
reason="$(must 'lastFailureReason()(bytes32)')"
cool="$(must 'cooldownUntil()(uint48)' | first)"
bal="$(cast call "$IMD" 'balanceOf(address)(uint256)' "$press" --rpc-url "$RH_RPC" 2>/dev/null | first)" ||
  die "could not read the press's IMD balance"
if [[ -s "$STATE_DIR/press-address" && "$(lower "$(tr -d '[:space:]' <"$STATE_DIR/press-address")")" != "$(lower "$press")" ]]; then
  echo "  note: .state/ belongs to $(cat "$STATE_DIR/press-address"); its transaction logs may not match this press."
fi
echo "  explorer     : $EXPLORER/address/$press  ($(((${#code} - 2) / 2)) B of code)"
echo "  intake()     : $i  (Intake v2: the press buys from it and accepts callbacks only from it)"
echo "  imd()        : $m"
echo "  STEWARD()    : $steward  (address(0): nobody can re-point the intake; no owner, no admin, no withdraw)"
echo "  PRICE()      : $(imd_amt "$price") IMD paid to Intake v2 per chapter"
echo "  BOUNTY()     : $(imd_amt "$bounty") IMD paid to whoever commissioned a delivered chapter"
echo "  IMD balance  : $(imd_amt "$bal") IMD (enough for $(calc "$bal / ($price + $bounty)") more chapter(s))"
echo "  chapters     : $count delivered"
echo "  misses       : $failures$( [[ "$failures" != "0" ]] && echo ", last reason \"$(cast parse-bytes32-string "$reason" 2>/dev/null || echo "$reason")\"")"

# pending request
if [[ "$busy" == "true" ]]; then
  req="$(must 'pendingRequest()(bytes32)')"
  since="$(must 'pendingSince()(uint64)' | first)"
  who="$(must 'pendingCommissioner()(address)')"
  deadline=$((since + TIMEOUT_S))
  echo "  pending      : chapter $((count + 1)), Intake request $req"
  echo "                 commissioned by $who at $(utc "$since") ($(dur $((now - since))) ago)"
  if ((now > deadline)); then
    echo "                 no callback for over 6 h: reset() is open now (since $(utc "$deadline")): scripts/11-reset.sh"
  else
    echo "                 reset() opens in $(dur $((deadline - now))) (after $(utc "$deadline")) if no callback arrives first"
  fi
  tx="$(log_tx commissions.log $((count + 1)))"
  [[ -n "$tx" ]] && echo "                 commission tx: $tx  $EXPLORER/tx/$tx"
else
  echo "  pending      : none"
  if ((cool > now)); then
    echo "  next         : cooling down after a miss until $(utc "$cool") ($(dur $((cool - now))) left)"
  elif ! ge "$bal" "$price + $bounty"; then
    echo "  next         : the press needs 0.52 IMD before the next chapter (anyone can send IMD to it)"
  elif ((count > 0)) && [[ "$(must 'isInscribed(uint256)(bool)' "$count")" != "true" ]]; then
    echo "  next         : chapter $count must be inscribed first (anyone: scripts/09-inscribe.sh $count)"
  else
    echo "  next         : anyone may commission chapter $((count + 1)) now (scripts/07-commission.sh)"
  fi
fi

# ------------------------------------------------------------------ chapters
types="bytes32,bytes32,bytes32,address,uint48,uint48,string"
names='["requestId","resultHash","uriHash","commissioner","requestedAt","deliveredAt","uri"]'
abi="$REPO_DIR/out/OuroborosPress.sol/OuroborosPress.json"
if [[ -f "$abi" ]]; then
  t="$(jq -r '.abi[] | select(.type == "function" and .name == "chapter") | .outputs[0].components | map(.type) | join(",")' "$abi" 2>/dev/null || true)"
  nm="$(jq -c '.abi[] | select(.type == "function" and .name == "chapter") | .outputs[0].components | map(.name)' "$abi" 2>/dev/null || true)"
  if [[ -n "$t" && -n "$nm" ]]; then
    types="$t"
    names="$nm"
  fi
fi

show_text() { # result.json FILE, chapter n, cid
  local f="$1" n="$2" cid="$3" file url want art got
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "    result     : not JSON; first $WORDS words:"
    first_words "$f"
    return 0
  fi
  echo "    job        : $(jq -r '.jobId // "?"' "$f")  state $(jq -r '.state // "?"' "$f")  $IMD_API/jobs/$(jq -r '.jobId // ""' "$f")"
  jq -r '.files[]? | "    file       : \(.name // "?") \(.path // "") (\(.mediaType // "?"), \(.bytes // "?") B)"' "$f" 2>/dev/null || true
  file="$(jq -c '[.files[]? | select((.mediaType // "") | startswith("text/"))]
    | (map(select(.name == "report" or ((.path // "") | endswith("report.md")))) + .) | .[0] // empty' "$f" 2>/dev/null || true)"
  art="$TMP/text.$n"
  if [[ -n "$file" ]]; then
    url="$(jq -r '.url // empty' <<<"$file")"
    want="$(jq -r '.hash // empty' <<<"$file")"
    if [[ "$url" == "$IMD_API/artifacts/"* || "$url" == "https://api.imd.fun/artifacts/"* ]] && fetch "$url" "$art"; then
      echo "    text       : $url"
    elif ipfs_fetch "$cid/$(jq -r '.path // ""' <<<"$file")" "$art" >/dev/null; then
      echo "    text       : ipfs://$cid/$(jq -r '.path // ""' <<<"$file")"
    else
      echo "    text       : could not download $url"
      return 0
    fi
    if [[ -n "$want" ]]; then
      got="$(sha256 "$art")"
      if [[ "$got" == "$want" ]]; then echo "                 sha256 matches result.json: yes"; else echo "                 sha256 matches result.json: NO ($got)"; fi
    fi
  else
    jq -r '[.. | strings | select(length > 200)] | max_by(length) // empty' "$f" >"$art" 2>/dev/null || true
    if [[ ! -s "$art" ]]; then
      echo "    text       : result.json lists no text file"
      return 0
    fi
    echo "    text       : the longest text field of result.json"
  fi
  echo "    first $WORDS words:"
  first_words "$art"
}

if ((count > 0)); then
  h "Chapters (layout $types)"
fi
for ((n = 1; n <= count; n++)); do
  raw="$(must 'chapter(uint256)' "$n")"
  rec="$(cast abi-decode "chapter(uint256)(($types))" "$raw" --json 2>/dev/null |
    jq -c --argjson names "$names" 'if type == "object" and has("data") then .data else . end | .[0]
      | [$names, .] | transpose | map({(.[0]): .[1]}) | add' 2>/dev/null)" || die "could not decode chapter($n)"
  f() { jq -r --arg k "$1" '.[$k] // "" | tostring' <<<"$rec"; }
  req_at="$(f requestedAt)"
  del_at="$(f deliveredAt)"
  uri="$(f uri)"
  echo "  chapter $n"
  echo "    requestId  : $(f requestId)"
  echo "    commission : by $(f commissioner) at $(utc "$req_at"); delivered $(utc "$del_at") ($(dur $((del_at - req_at))) later)"
  tx="$(log_tx commissions.log "$n")"
  [[ -n "$tx" ]] && echo "    request tx : $tx  $EXPLORER/tx/$tx"
  echo "    resultHash : $(f resultHash)  (keccak256 of result.json)"
  echo "    uriHash    : $(f uriHash)"
  if [[ "$(must 'isInscribed(uint256)(bool)' "$n")" == "true" ]]; then
    tx="$(log_tx inscribes.log "$n")"
    echo "    inscribed  : yes${tx:+, tx $tx  $EXPLORER/tx/$tx}"
  else
    echo "    inscribed  : no (anyone may: scripts/09-inscribe.sh $n)"
    tx="$(log_tx commissions.log "$n")"
    if [[ -z "$uri" && -n "$tx" ]]; then
      uri="$(api_get "/intake/$CHAIN_ID/$tx" | jq -r '.entries[0].completion.uri // empty' 2>/dev/null || true)"
      if [[ -n "$uri" ]]; then
        if [[ "$(cast keccak "$uri")" == "$(f uriHash)" ]]; then
          echo "    uri source : the Intake API (keccak matches uriHash on chain)"
        else
          echo "    uri source : the Intake API (keccak does NOT match uriHash; ignored)"
          uri=""
        fi
      fi
    fi
  fi
  echo "    uri        : ${uri:-<not known yet>}"
  [[ -n "$uri" ]] || continue
  if [[ -n "${NO_FETCH:-}" ]]; then
    echo "    (NO_FETCH=1: result.json not downloaded)"
    continue
  fi
  res="$TMP/result.$n"
  cid=""
  if [[ "$uri" =~ ^ipfs://([A-Za-z0-9._/-]+)$ ]]; then
    cid="${BASH_REMATCH[1]%%/*}"
    if gw="$(ipfs_fetch "${BASH_REMATCH[1]}" "$res")"; then
      echo "    result.json: fetched via $gw/ipfs/${BASH_REMATCH[1]} ($(wc -c <"$res" | tr -d ' ') B)"
    else
      echo "    result.json: no gateway answered ($GATEWAYS)"
      continue
    fi
  elif [[ "$uri" =~ ^/[A-Za-z0-9._/-]+$ ]] && fetch "$IMD_API$uri" "$res"; then
    echo "    result.json: fetched from $IMD_API$uri"
  else
    echo "    result.json: not fetched (uri is not ipfs:// or an IMD API path)"
    continue
  fi
  if [[ "$(keccak_file "$res")" == "$(f resultHash)" ]]; then
    echo "                 keccak256 matches resultHash on chain: yes"
  else
    echo "                 keccak256 matches resultHash on chain: NO ($(keccak_file "$res"))"
  fi
  show_text "$res" "$n" "$cid"
done

evidence
footer
exit 0
