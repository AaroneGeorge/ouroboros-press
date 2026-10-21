// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntakeV2} from "../../src/interfaces/IIntakeV2.sol";

/// @notice Stand-in for IMD Intake v2, after https://imd.fun/docs/: pulls the price from the caller
///         in the same call (less reverts PriceNotMet), records the request, and later calls back
///         like the plane's writer does: once, with exactly 200,000 gas, without reverting itself.
contract MockIntake is IIntakeV2 {
    error PriceNotMet();
    error FailureHookWithoutTarget();

    uint256 public constant PRICE = 0.5e18;
    uint256 public constant CALLBACK_GAS = 200_000;
    address public constant TREASURY = address(0x7EA5);
    bytes4 public constant ON_RESULT = 0x4374622e;

    struct Req {
        address payer;
        bytes32 action;
        bytes32 bodyHash; // the real Intake emits the body (about 8 gas a byte); it does not store it
        address target;
        bytes4 selector;
        bytes4 onFailure;
        address asset;
        uint256 amount;
    }

    mapping(bytes32 => Req) internal _requests;
    bytes32 public lastRequestId;
    uint256 public nonce;
    uint256 public requestCount;

    bool public lastDelivered;
    uint256 public lastCallbackGas;

    event Requested(bytes32 indexed requestId, address indexed payer, bytes32 action, bytes body);
    event Completed(bytes32 indexed requestId, uint8 status, bool delivered);

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        returns (bytes32)
    {
        return _request(action, body, callback, bytes4(0), asset, amount);
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32) {
        return _request(action, body, callback, onFailure, asset, amount);
    }

    function _request(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) internal returns (bytes32 id) {
        if (amount < PRICE) revert PriceNotMet();
        if (onFailure != bytes4(0) && callback.target == address(0)) revert FailureHookWithoutTarget();
        pullsPayment(asset, amount);
        id = keccak256(abi.encode(block.chainid, address(this), ++nonce, msg.sender));
        _requests[id] =
            Req(msg.sender, action, keccak256(body), callback.target, callback.selector, onFailure, asset, amount);
        lastRequestId = id;
        requestCount++;
        emit Requested(id, msg.sender, action, body);
    }

    /// @dev "forwarded whole to the treasury in the same call".
    function pullsPayment(address asset, uint256 amount) internal {
        require(IERC20(asset).transferFrom(msg.sender, TREASURY, amount), "pull failed");
    }

    function getRequest(bytes32 id) external view returns (Req memory) {
        return _requests[id];
    }

    // ------------------------------------------------------------ writer side

    /// @notice Status 0: calls `target.onResult(requestId, resultHash, uri)` with 200k gas.
    function deliver(address target, bytes32 requestId, bytes32 resultHash, string calldata uri)
        external
        returns (bool delivered, uint256 gasUsed)
    {
        return deliverWith(target, ON_RESULT, requestId, resultHash, uri);
    }

    /// @notice Status 0 with any selector: what happens when someone pays for their own job and
    ///         names `target` and `selector` as its callback.
    function deliverWith(address target, bytes4 selector, bytes32 requestId, bytes32 resultHash, string calldata uri)
        public
        returns (bool delivered, uint256 gasUsed)
    {
        bytes memory data = abi.encodeWithSelector(selector, requestId, resultHash, uri);
        (delivered, gasUsed) = _call(target, data);
        emit Completed(requestId, 0, delivered);
    }

    /// @notice Status 1 or 2: calls the failure function with (requestId, status, reason, agreed, answered, "").
    function fail(address target, bytes4 onFailure, bytes32 requestId, uint8 status, bytes32 reason)
        external
        returns (bool delivered, uint256 gasUsed)
    {
        bytes memory data =
            abi.encodeWithSelector(onFailure, requestId, status, reason, uint16(0), uint16(0), bytes(""));
        (delivered, gasUsed) = _call(target, data);
        emit Completed(requestId, status, delivered);
    }

    function _call(address target, bytes memory data) internal returns (bool ok, uint256 used) {
        uint256 before = gasleft();
        (ok,) = target.call{gas: CALLBACK_GAS}(data);
        used = before - gasleft();
        lastDelivered = ok;
        lastCallbackGas = used;
    }
}
