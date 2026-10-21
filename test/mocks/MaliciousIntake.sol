// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntakeV2} from "../../src/interfaces/IIntakeV2.sol";
import {OuroborosPress} from "../../src/OuroborosPress.sol";

/// @notice An intake that, inside requestWithFailure, tries to re-enter every state-changing
///         function of the press before returning. Records which attempts succeeded.
contract MaliciousIntake is IIntakeV2 {
    bool public commissionReentered;
    bool public onResultReentered;
    bool public onFailureReentered;
    bool public resetReentered;
    bool public donateReentered;
    bytes32 public constant ID = keccak256("malicious");

    function request(bytes32, bytes calldata, Callback calldata, address, uint256) external pure returns (bytes32) {
        revert("unused");
    }

    function requestWithFailure(bytes32, bytes calldata, Callback calldata, bytes4, address asset, uint256 amount)
        external
        returns (bytes32)
    {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "pull failed");
        OuroborosPress press = OuroborosPress(payable(msg.sender));
        try press.commission() {
            commissionReentered = true;
        } catch {}
        // Try the id it is about to return, and zero (the draft is not written yet).
        try press.onResult(ID, keccak256("x"), "ipfs://evil") {
            onResultReentered = true;
        } catch {}
        try press.onResult(bytes32(0), keccak256("x"), "ipfs://evil") {
            onResultReentered = true;
        } catch {}
        try press.onFailure(bytes32(0), 2, "failed", 0, 0, "") {
            onFailureReentered = true;
        } catch {}
        try press.reset() {
            resetReentered = true;
        } catch {}
        try press.donate(1) {
            donateReentered = true;
        } catch {}
        return ID;
    }
}
