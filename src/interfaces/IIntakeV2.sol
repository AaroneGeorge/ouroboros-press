// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IIntakeV2
/// @notice The part of IMD's Intake v2 a buyer calls, as published at https://imd.fun/docs/
///         ("Intake v2", "From a contract"). Same address on every chain:
///         0xa43e6f75ee006411f79ac1c84120606c2330de82.
/// @dev    Selectors (verified against the live Robinhood Chain bytecode):
///         request            0x380c2cda  request(bytes32,bytes,(address,bytes4),address,uint256)
///         requestWithFailure 0x9a78c321  requestWithFailure(bytes32,bytes,(address,bytes4),bytes4,address,uint256)
interface IIntakeV2 {
    /// @notice The contract and function a result is handed to; (address(0), 0x00000000) for none.
    struct Callback {
        address target;
        bytes4 selector;
    }

    /// @notice Pays `amount` of `asset` (the chain's IMD, at least 0.5e18) and asks for `action`.
    /// @param action   The action id right-padded to 32 bytes, e.g. "job.open@job-1".
    /// @param body     The action's body as compact UTF-8 JSON, 1 byte to 16 KiB.
    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        returns (bytes32 requestId);

    /// @notice As `request`, plus `onFailure`, a second function on the callback target called on
    ///         status 1 (refused) or 2 (no result).
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);
}

/// @title IIntakeReceiver
/// @notice The callback shapes Intake v2 calls on a job/launch/workflow result. The names are the
///         receiver's; the parameter types are fixed by the protocol.
interface IIntakeReceiver {
    /// @notice Status 0 for a job: `uri` is ipfs://CID/result.json (or the plane's /intake-results/:id),
    ///         `resultHash` the keccak-256 of the bytes at `uri`. Selector 0x4374622e.
    function onResult(bytes32 requestId, bytes32 resultHash, string calldata uri) external;

    /// @notice Status 1 (refused) or 2 (no result). `signature` is empty for now. Selector 0x5a0df71e.
    function onFailure(
        bytes32 requestId,
        uint8 status,
        bytes32 reason,
        uint16 agreed,
        uint16 answered,
        bytes calldata signature
    ) external;
}
