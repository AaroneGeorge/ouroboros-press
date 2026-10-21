// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IIntakeV2, IIntakeReceiver} from "./interfaces/IIntakeV2.sol";

/// @title  Ouroboros Press
/// @notice A contract on Robinhood Chain that pays IMD's agent swarm to write a book about itself.
///         Anyone may call `commission()`. The contract then pays IMD's Intake v2 0.5 IMD from its
///         own balance for one `research-report` job: "write chapter N of the book this contract is
///         writing about itself". The swarm delivers the chapter by callback, and the contract records
///         the result hash on chain and emits `Chapter`. The book is the product, and the contract is
///         the author's only employer.
///
///         No owner, admin, upgrade, pause, withdraw or selfdestruct exists. IMD that reaches this
///         contract can leave only as the 0.5 IMD price of a chapter (pulled by the Intake) or as the
///         0.02 IMD bounty paid to whoever commissioned a chapter that was delivered.
///
/// @dev    Launch constraints (IMD imported-repo `evm_contracts`): zero-argument, nonpayable
///         constructor with no external calls; chain constants are hardcoded for Robinhood Chain (4663).
///
///         Callback gas: the Intake calls back once, with 200,000 gas, inside a try. So `onResult`
///         writes only fixed-size words (result hash, uri hash, timestamp). It does not store the uri
///         string, which is ~22k gas per 32 bytes. The uri goes out in full in the `Chapter` event, and
///         anyone can copy it into storage later with `inscribe`, which checks it against the stored
///         hash. The draft record (request id, commissioner, time) is written by `commission`, which
///         is not gas-limited.
contract OuroborosPress is IIntakeReceiver, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;
    using Strings for address;

    // ------------------------------------------------------------------ constants

    /// @notice IMD Intake v2, the same address on every chain (https://imd.fun/docs/, "Intake v2").
    address public constant INTAKE_V2 = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    /// @notice IMD on Robinhood Chain (18 decimals, symbol "IMD").
    address public constant IMD_TOKEN = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    /// @notice The only address allowed to re-point `intake`. It is address(0), so nobody can do it.
    ///         See THREAT-MODEL.md, "Why the intake cannot be changed".
    address public constant STEWARD = address(0);

    /// @notice "job.open@job-1", right-padded to 32 bytes (== `cast format-bytes32-string`).
    bytes32 public constant ACTION_JOB_OPEN = "job.open@job-1";
    /// @notice Intake v2's price per action: 0.5 IMD.
    uint256 public constant PRICE = 0.5e18;
    /// @notice Paid from this contract's balance to the commissioner of a delivered chapter.
    uint256 public constant BOUNTY = 0.02e18;
    /// @notice After this long without a callback anyone may `reset()` a pending commission.
    uint64 public constant TIMEOUT = 6 hours;
    /// @notice Cool-down after the first consecutive miss (refusal, no result or timeout). It doubles
    ///         with each further miss, up to `BASE_COOLDOWN << (MAX_STREAK - 1)` (128 hours).
    uint64 public constant BASE_COOLDOWN = 1 hours;
    uint8 public constant MAX_STREAK = 8;
    /// @notice A previous-chapter uri longer than this is not quoted in the next objective.
    uint256 public constant MAX_QUOTED_URI = 256;

    /// @dev Gas forwarded to the IMD transfer that pays the bounty inside the 200k callback.
    uint256 private constant BOUNTY_GAS = 80_000;
    /// @dev keccak256("") (an empty delivered uri counts as inscribed).
    bytes32 private constant EMPTY_HASH = keccak256("");

    // ------------------------------------------------------------------ types

    /// @notice One chapter. `requestId`, `commissioner` and `requestedAt` are written by
    ///         `commission`; `resultHash`, `uriHash` and `deliveredAt` by `onResult`; `uri` by `inscribe`.
    struct ChapterRecord {
        bytes32 requestId; //    the Intake's request id
        bytes32 resultHash; //   keccak-256 of the bytes at `uri` (result.json), as the Intake's writer reported
        bytes32 uriHash; //      keccak-256 of `uri`
        address commissioner; // who called commission(); receives the bounty
        uint48 requestedAt; //   block.timestamp of commission()
        uint48 deliveredAt; //   block.timestamp of onResult()
        string uri; //           ipfs://CID/result.json (or the plane's /intake-results/:id), once inscribed
    }

    // ------------------------------------------------------------------ storage

    /// @notice The Intake this contract buys from and accepts callbacks from.
    address public intake;
    /// @notice True while a commission is waiting for its callback.
    bool public busy;
    /// @notice Consecutive refusals, no-results and timeouts since the last delivered chapter.
    uint8 public failureStreak;
    /// @notice No commission before this time (set after a miss).
    uint48 public cooldownUntil;
    /// @dev Published chapters; chapter numbers start at 1.
    uint32 private _published;

    /// @notice Every paid request that produced no chapter: refusals, no-results and timeouts.
    uint256 public failures;
    /// @notice The reason code of the last miss ("timeout" for a reset()).
    bytes32 public lastFailureReason;

    /// @dev 1-based. Index `_published + 1` holds the draft of the chapter being written.
    mapping(uint256 => ChapterRecord) private _chapters;

    /// @notice The token the contract pays with.
    IERC20 public immutable imd;

    // ------------------------------------------------------------------ events

    event Commissioned(uint256 indexed chapter, bytes32 indexed requestId, address indexed commissioner, bytes body);
    event Chapter(uint256 indexed chapter, bytes32 indexed requestId, bytes32 resultHash, string uri);
    event Inscribed(uint256 indexed chapter, string uri);
    event Failed(bytes32 indexed requestId, uint8 status, bytes32 reason);
    event TimedOut(bytes32 indexed requestId);
    event Donated(address indexed from, uint256 amount);
    event BountyPaid(address indexed to, uint256 amount);
    event BountySkipped(address indexed to, uint256 amount);
    event IntakeChanged(address indexed previous, address indexed next);

    // ------------------------------------------------------------------ errors

    error Busy();
    error NotBusy();
    error CoolingDown(uint256 until);
    error InsufficientBalance(uint256 have, uint256 need);
    error PreviousNotInscribed(uint256 chapter);
    error IntakeCannotCommission();
    error ZeroRequestId();
    error NotIntake();
    error UnknownRequest(bytes32 requestId);
    error TooEarly(uint256 at);
    error NoSuchChapter(uint256 chapter);
    error AlreadyInscribed(uint256 chapter);
    error UriMismatch(uint256 chapter);
    error ZeroAmount();
    error NotSteward();
    error NoEther();

    // ------------------------------------------------------------------ constructor

    /// @dev Static, nonpayable, no external calls.
    constructor() {
        imd = IERC20(IMD_TOKEN);
        intake = INTAKE_V2;
        emit IntakeChanged(address(0), INTAKE_V2);
    }

    // ------------------------------------------------------------------ the press

    /// @notice Order the next chapter. Anyone may call this when no chapter is pending, the cool-down
    ///         has passed, the previous chapter is inscribed, and the contract holds at least
    ///         PRICE + BOUNTY. Pays the Intake exactly PRICE. The body is `previewBody()`.
    /// @return requestId The Intake's request id.
    function commission() external nonReentrant returns (bytes32 requestId) {
        address intake_ = intake;
        // Anyone can pay for their own job and name this contract and any selector as its callback.
        // This stops such a callback from ordering chapters with the intake as commissioner.
        if (msg.sender == intake_) revert IntakeCannotCommission();
        if (busy) revert Busy();
        if (block.timestamp < cooldownUntil) revert CoolingDown(cooldownUntil);

        uint256 n = uint256(_published) + 1;
        if (n > 1 && !_isInscribed(_chapters[n - 1])) revert PreviousNotInscribed(n - 1);

        uint256 balance = imd.balanceOf(address(this));
        if (balance < PRICE + BOUNTY) revert InsufficientBalance(balance, PRICE + BOUNTY);

        bytes memory body = _body(n, balance);
        busy = true;

        imd.forceApprove(intake_, PRICE);
        requestId = IIntakeV2(intake_)
            .requestWithFailure(
                ACTION_JOB_OPEN,
                body,
                IIntakeV2.Callback({target: address(this), selector: this.onResult.selector}),
                this.onFailure.selector,
                address(imd),
                PRICE
            );

        // After the call: only checks on the return value, storage writes and the event.
        if (requestId == bytes32(0)) revert ZeroRequestId();
        ChapterRecord storage c = _chapters[n];
        c.requestId = requestId;
        c.commissioner = msg.sender;
        c.requestedAt = uint48(block.timestamp);
        emit Commissioned(n, requestId, msg.sender, body);
    }

    /// @notice Status 0 callback from the Intake. Records the chapter and pays the bounty.
    ///         Callable only by `intake`, only for the pending request, only once.
    /// @dev    Runs under the Intake's 200,000 gas: fixed-size writes, one capped token transfer, no loops.
    function onResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external nonReentrant {
        uint256 n = _settle(requestId);

        ChapterRecord storage c = _chapters[n];
        c.resultHash = resultHash;
        c.uriHash = keccak256(bytes(uri));
        c.deliveredAt = uint48(block.timestamp);
        _published = uint32(n);
        failureStreak = 0;
        address commissioner = c.commissioner;

        emit Chapter(n, requestId, resultHash, uri);

        if (_tryPayBounty(commissioner)) emit BountyPaid(commissioner, BOUNTY);
        else emit BountySkipped(commissioner, BOUNTY);
    }

    /// @notice Status 1 (refused) or 2 (no result) callback from the Intake. Clears the pending
    ///         commission and counts the miss. Moves no value: a failure is unsigned (see the docs).
    function onFailure(
        bytes32 requestId,
        uint8 status,
        bytes32 reason,
        uint16, /* agreed */
        uint16, /* answered */
        bytes calldata /* signature: empty for now */
    )
        external
        nonReentrant
    {
        _settle(requestId);
        _recordMiss(reason);
        emit Failed(requestId, status, reason);
    }

    /// @notice Anyone may clear a commission that has had no callback for longer than TIMEOUT.
    ///         This is the way out of every stuck state. A late callback for it is then refused.
    function reset() external nonReentrant {
        if (!busy) revert NotBusy();
        ChapterRecord storage c = _chapters[uint256(_published) + 1];
        uint256 deadline = uint256(c.requestedAt) + TIMEOUT;
        if (block.timestamp <= deadline) revert TooEarly(deadline);
        busy = false;
        _recordMiss("timeout");
        emit TimedOut(c.requestId);
    }

    /// @notice Copy a delivered chapter's uri into storage. Anyone may call this. The uri must hash
    ///         to the `uriHash` the Intake delivered. The uri is in the `Chapter` event and on
    ///         GET https://api.imd.fun/intake/4663/<commission tx hash> (completion.uri).
    function inscribe(uint256 n, string calldata uri) external {
        if (n == 0 || n > _published) revert NoSuchChapter(n);
        ChapterRecord storage c = _chapters[n];
        if (bytes(c.uri).length != 0) revert AlreadyInscribed(n);
        if (keccak256(bytes(uri)) != c.uriHash) revert UriMismatch(n);
        c.uri = uri;
        emit Inscribed(n, uri);
    }

    /// @notice Fund future chapters. Pulls `amount` IMD from the caller (approve first). A plain
    ///         `IMD.transfer(press, amount)` funds the press too, without the event.
    function donate(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        imd.safeTransferFrom(msg.sender, address(this), amount);
        emit Donated(msg.sender, amount);
    }

    /// @notice Re-point the Intake. Only STEWARD may call this, and STEWARD is address(0), so
    ///         nobody can. It is kept so the setting the docs ask for is visibly present and visibly
    ///         locked. If the gate were "only the current intake", anyone who pays for a job naming
    ///         this contract and this selector as the callback could make the Intake call it.
    function setIntake(address next) external {
        if (msg.sender != STEWARD) revert NotSteward();
        emit IntakeChanged(intake, next);
        intake = next;
    }

    /// @notice The press takes no ETH.
    receive() external payable {
        revert NoEther();
    }

    // ------------------------------------------------------------------ views

    /// @notice The exact job body `commission()` would send now.
    function previewBody() external view returns (bytes memory) {
        return _body(uint256(_published) + 1, imd.balanceOf(address(this)));
    }

    /// @notice Number of delivered chapters.
    function chapterCount() external view returns (uint256) {
        return _published;
    }

    /// @notice Delivered chapter `n`, 1 <= n <= chapterCount().
    function chapter(uint256 n) external view returns (ChapterRecord memory) {
        if (n == 0 || n > _published) revert NoSuchChapter(n);
        return _chapters[n];
    }

    /// @notice Whether chapter `n` has its uri in storage (or was delivered with an empty uri).
    function isInscribed(uint256 n) external view returns (bool) {
        if (n == 0 || n > _published) revert NoSuchChapter(n);
        return _isInscribed(_chapters[n]);
    }

    /// @notice The Intake request id being waited on, or zero.
    function pendingRequest() external view returns (bytes32) {
        return busy ? _chapters[uint256(_published) + 1].requestId : bytes32(0);
    }

    /// @notice When the pending commission was made, or zero.
    function pendingSince() external view returns (uint64) {
        return busy ? uint64(_chapters[uint256(_published) + 1].requestedAt) : 0;
    }

    /// @notice Who made the pending commission, or zero.
    function pendingCommissioner() external view returns (address) {
        return busy ? _chapters[uint256(_published) + 1].commissioner : address(0);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Only the intake, only while busy, only for the pending request id. Clears busy.
    function _settle(bytes32 requestId) private returns (uint256 n) {
        if (msg.sender != intake) revert NotIntake();
        if (!busy) revert NotBusy();
        n = uint256(_published) + 1;
        if (requestId == bytes32(0) || requestId != _chapters[n].requestId) revert UnknownRequest(requestId);
        busy = false;
    }

    /// @dev A paid request that produced no chapter. Starts or doubles the cool-down.
    function _recordMiss(bytes32 reason) private {
        failures += 1;
        lastFailureReason = reason;
        uint8 streak = failureStreak < MAX_STREAK ? failureStreak + 1 : MAX_STREAK;
        failureStreak = streak;
        cooldownUntil = uint48(block.timestamp + (uint256(BASE_COOLDOWN) << (streak - 1)));
    }

    /// @dev Transfers BOUNTY to `to` with at most BOUNTY_GAS and never reverts. Reads at most 32
    ///      bytes of return data (the same acceptance rule as SafeERC20.trySafeTransfer).
    function _tryPayBounty(address to) private returns (bool ok) {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, BOUNTY));
        address token = address(imd);
        uint256 size;
        uint256 value;
        assembly ("memory-safe") {
            ok := call(BOUNTY_GAS, token, 0, add(data, 0x20), mload(data), 0, 0x20)
            size := returndatasize()
            value := mload(0)
        }
        ok = ok && (size == 0 ? token.code.length > 0 : value == 1);
    }

    function _isInscribed(ChapterRecord storage c) private view returns (bool) {
        return bytes(c.uri).length != 0 || c.uriHash == EMPTY_HASH;
    }

    /// @dev Compact JSON: {"objective":"...","skill":"research-report","ipfs":true}. Every interpolated
    ///      value is digits, lowercase hex, or a uri that passed `_quotable`, so it needs no escaping.
    function _body(uint256 n, uint256 balance) private view returns (bytes memory) {
        string memory head = string.concat(
            '{"objective":"Write chapter ',
            n.toString(),
            " of The Ouroboros Press, a book that a smart contract on Robinhood Chain (chain id 4663) is writing about itself. The contract is at ",
            address(this).toHexString(),
            ". It holds ",
            balance.toString(),
            " IMD in wei (18 decimals). Chapters published before this one: "
        );
        string memory tail = string.concat(
            (n - 1).toString(),
            ". The previous chapter is at ",
            _previous(n),
            ". Describe what this contract is, what it has done so far, what a reader should know about a machine that pays agents to document itself, and end with one question the next chapter should answer. 300 to 600 words, plain prose, no headings.",
            '","skill":"research-report","ipfs":true}'
        );
        return bytes(string.concat(head, tail));
    }

    /// @dev Where the previous chapter is, as safe text for the objective.
    function _previous(uint256 n) private view returns (string memory) {
        if (n == 1) return "none";
        ChapterRecord storage p = _chapters[n - 1];
        string memory uri = p.uri;
        if (bytes(uri).length == 0) return "none (it was delivered without a uri)";
        if (!_quotable(bytes(uri))) {
            return string.concat("unquotable here (its result hash is ", uint256(p.resultHash).toHexString(32), ")");
        }
        // The plane's fallback is the relative path /intake-results/:id on its API.
        if (bytes(uri)[0] == "/") return string.concat("https://api.imd.fun", uri);
        return uri;
    }

    /// @dev Printable ASCII without quote or backslash, at most MAX_QUOTED_URI bytes.
    function _quotable(bytes memory s) private pure returns (bool) {
        if (s.length > MAX_QUOTED_URI) return false;
        for (uint256 i; i < s.length; ++i) {
            bytes1 b = s[i];
            if (b < 0x20 || b > 0x7e || b == '"' || b == "\\") return false;
        }
        return true;
    }
}
