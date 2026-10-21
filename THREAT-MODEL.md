# Threat model: Ouroboros Press

`src/OuroborosPress.sol` holds IMD on Robinhood Chain (4663) and spends it on one thing: chapters of a book about itself, bought from IMD's Intake v2. This page lists who can do what to it, what each attack costs, and what is impossible by construction.

## What the contract holds, and the only ways out

| Flow | Path | Amount | Who triggers it |
|---|---|---|---|
| In | `donate(amount)` or a plain `IMD.transfer(press, amount)` | any | anyone |
| Out | the Intake pulls the price inside `commission()` | exactly `PRICE` = 0.5 IMD per chapter | anyone, when the press is idle, past its cool-down, and the previous chapter is inscribed |
| Out | the bounty inside `onResult` | exactly `BOUNTY` = 0.02 IMD, to that chapter's commissioner | only the Intake's delivery callback for the pending request |

There is no third path. `commission()` approves exactly `PRICE` (with `forceApprove`), and the Intake pulls that amount in the same call, so no allowance is left after the transaction. The press accepts no ETH: `receive()` reverts and there is no fallback.

## What is impossible

- **No admin and no owner.** The contract has no `Ownable`, no roles, and no privileged address that can sign anything.
- **No withdraw, sweep or rescue.** IMD cannot be taken out except by the two paths above.
- **No upgrade.** There is no proxy, no `delegatecall` and no `selfdestruct`, and the constructor takes zero arguments and makes no external calls.
- **No pause or blocklist** in the press. (The IMD token itself has an owner. See "Trusted parties".)
- **The intake address cannot change.** `setIntake` can be called only by `STEWARD`, which is `address(0)`. No transaction or call has `msg.sender == address(0)`. On Robinhood Chain (Arbitrum Orbit), L1-to-L2 messages arrive from aliased addresses (sender + `0x1111000000000000000000000000000000001111`). Only an L1 contract at `0xeeeeffffffffffffffffffffffffffffffffeeef` would alias to address(0), and finding a creation path to that address is a 2^160 search.

### Why the intake cannot be changed

BUILD-PLAN.md first proposed letting only the current Intake re-point `intake`. The docs rule that out:

1. Intake v2 never calls such a function. "Addresses are fixed: a new version lands at a new address with the same functions, and the old one stays served" (https://imd.fun/docs/, Intake v2). The Intake calls a contract only through the callback a request names, with fixed argument types: `(bytes32, bytes32, string)` for a result and `(bytes32, uint8, bytes32, uint16, uint16, bytes)` for a failure.
2. That gate would be an attack surface. "Anyone can pay for work of their own and name your contract as its callback" (docs, "What a callback proves"). An attacker could pay 0.5 IMD for a job naming `(press, setIntake.selector)` as its callback. The Intake would then call `setIntake` with `msg.sender == intake` and the attacker's request id as the first word. If that id ever fit in 160 bits, the press would be re-pointed. `test_spoofedCallbacksThroughIntakeAreRefused` sends exactly this call with an id that decodes as an address, and shows it is refused.

So the plan's fallback applies: a `STEWARD` constant set to `address(0)`, meaning nobody. Version 2 stays served after a v3 ships, so the press keeps working. If v2 were ever retired, the book would end at its last chapter. Every chapter is permanent on chain, and a new press could cite the old one.

## Who can grief, and what it costs

| Actor | What they can do | Cost to them | Effect on the press |
|---|---|---|---|
| Anyone | Call `commission()` as soon as the press is idle and funded | gas (sub-cent on Robinhood Chain) | Spends 0.5 IMD on the next chapter. That is the intended use, and it earns them 0.02 IMD on delivery. Only one chapter can be pending at a time, and each takes the swarm 10 to 60 minutes. The body is fixed by the contract, so a commissioner cannot change what is asked. |
| Anyone | Pay for their own Intake job naming the press and any selector as callback | 0.5 IMD per attempt | None. `onResult`/`onFailure` refuse a request id that is not the pending one (`UnknownRequest`). `commission()` refuses the Intake as caller (`IntakeCannotCommission`). `setIntake` refuses everyone (`NotSteward`). Tested. |
| Anyone | `reset()` a commission after 6 hours without a callback | gas | Frees the press. The 0.5 IMD paid is spent, and a late result for it is refused. Before 6 hours `reset()` reverts (`TooEarly`). |
| Anyone | `inscribe(n, uri)` | gas | Only the uri whose keccak-256 equals the delivered `uriHash` is accepted, once. A forged uri reverts (`UriMismatch`). |
| Anyone | Donate dust or odd amounts | the dust | Changes the balance quoted in the next objective. That is digits only, so it cannot break the JSON or steer the prompt. |
| A hostile Intake (hypothetical; the address is fixed) | Re-enter during `commission()` | n/a | Every state-changing entry point is `nonReentrant`, and `busy` is set before the external call. `test_reentrancyFromMaliciousIntakeFails` tries `commission`, `onResult` (with the id it is about to return, and with zero), `onFailure`, `reset` and `donate` from inside `requestWithFailure`. All of them fail. |

### Drain by repeated failure

A refused body is a spent payment. Suppose the plane someday refused every press body, for example because the `research-report` skill or the `ipfs` field was retired. Anyone could then keep commissioning, and each refusal would burn 0.5 IMD. The press limits this:

- Each miss (refusal, no result, or `reset()` timeout) starts a cool-down of 1 hour, doubling per consecutive miss up to 128 hours (`BASE_COOLDOWN << (streak - 1)`, `MAX_STREAK` = 8).
- A delivered chapter resets the streak.
- Worst case: 8 misses over about 255 hours (4 IMD), then at most one 0.5 IMD attempt per 128 hours, about 0.66 IMD a week. That leaves time for donors to stop funding it.

`07-commission.sh` also runs the free `POST /requests/check` on the exact on-chain `previewBody()` and will not send if `blockers` is not empty.

## Trusted parties (outside the press's control)

- **The Intake's writer key** (IMD's control plane). It can withhold a result, so the payment is spent and `reset()` frees the press after 6 hours. It can send a false failure, so the payment is spent and a cool-down starts. It can also pair the wrong result with the press's request: a job result "is not signed by the oracle. The hash fixes the bytes; that they describe your work is the writer's word" (docs). The press records `resultHash` and the uri as reported and moves no value on a failure. The worst the writer can take is the 0.5 IMD already paid for a chapter, plus the 0.02 IMD bounty paid to the press's own commissioner.
- **The IMD token and Intake owner key.** Per the Sinopia README (launch #1942), "the Intake and the IMD token share an owner key, which can change Intake settings and block token transfers". If transfers to or from the press were blocked, or the Intake price rose above 0.5 IMD (`PriceNotMet`), `commission()` would revert and the IMD in the press would be frozen. With no admin, nobody could rescue it. This is the accepted cost of having no human key. Hold only the IMD the next few chapters need. A blocked bounty transfer does not block delivery: the bounty is skipped (`BountySkipped`) and the chapter is still recorded. Tested with a blocking mock.
- **Robinhood Chain's sequencer**, for liveness and timestamps. A few seconds of timestamp skew does not matter against 1 to 128 hour windows.

## The 200,000 gas callback

The Intake calls back "once, inside a try" with 200,000 gas (docs). If the callback reverts, the result is lost to the contract (it stays readable by transaction hash), and the press waits for `reset()`. So `onResult` writes only fixed-size words: the result hash, the uri hash, the delivery time, and the packed state slot. It does not store the uri string, because a 200-byte uri would be about 8 fresh slots, roughly 177k gas. The uri is emitted in `Chapter` and stored later by anyone through `inscribe`.

- Measured with the mock token: 109,491 gas with a 200-byte uri on the first chapter (bounty to a fresh holder), 111,984 gas with a 512-byte uri. With the real IMD on a Robinhood Chain fork (VERIFY.md): the bounty `transfer` costs 38,861 gas and `onResult` about 132,000 to 136,000 gas with a 79-byte uri, and still succeeds with a 3 KiB uri; a uri of 4 KiB or more runs out of the 200,000 and the chapter is lost (the press then waits for `reset()`). The plane's uris are under 100 bytes.
- The bounty transfer gets at most 80,000 gas, reads at most 32 bytes of return data, and never reverts. With a token that burns more than that (`test_expensiveTokenSkipsBountyButKeepsChapterUnderStipend`), `onResult` still completes in 155,146 gas, skips the bounty, and records the chapter.
- `onFailure` takes 63,862 gas on the first failure, which is the cold case.

## What reaches the swarm's prompt

The job body is onchain forever and "reaches the workers' prompts" (docs). `previewBody()` is built only from:

- decimal digits (chapter number, balance)
- the press's own address in lowercase hex
- the previous chapter's uri as the plane delivered it

The uri is quoted only if it is at most 256 bytes of printable ASCII with no `"` or `\`. Otherwise the objective says "unquotable here (its result hash is 0x...)". A relative `/intake-results/:id` uri is prefixed with `https://api.imd.fun`. The JSON cannot be broken whatever the plane delivers (`testFuzz_bodyStaysValidJsonForAnyUri`, `test_unquotableUriKeepsBodyValidJson`), and the body always has exactly three fields: `objective`, `skill`, `ipfs`.

## Ways out of every stuck state

| Stuck state | Way out |
|---|---|
| Pending, no callback ever | `reset()` by anyone after 6 hours |
| Callback reverted (should not happen; gas-tested) | Same: still pending, `reset()` after 6 hours |
| Refused or failed | `onFailure` clears it; commission again after the cool-down |
| Previous chapter not inscribed | Anyone calls `inscribe(n, uri)` with the uri from the `Chapter` event or `GET /intake/4663/<commission tx>` |
| Delivered with an empty uri | Counts as inscribed automatically |
| Balance below 0.52 IMD | Anyone donates or transfers IMD |
| IMD blocks the press, or the Intake price rises | **No way out.** Funds are frozen. This is the trade-off of no admin; keep the balance small |
