// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {OuroborosPress} from "../src/OuroborosPress.sol";
import {MockIMD} from "../test/mocks/MockIMD.sol";
import {MockIntake} from "../test/mocks/MockIntake.sol";

/// @notice Returns the job body `commission()` would send, computed offline (no RPC, nothing
///         broadcast). The real body depends on the deployed address and the balance:
///           PRESS_AT=0x... PRESS_BALANCE=520000000000000000 forge script script/PreviewBody.s.sol --json
///         With PREV_URI set it first simulates chapter 1 (commissioned, delivered with that uri,
///         inscribed), so the result is chapter 2's body.
///         After deployment, read the exact body from chain instead: scripts/02b-check-job-body.sh.
contract PreviewBody is Script {
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;

    function run() external returns (bytes memory body) {
        address at = vm.envOr("PRESS_AT", address(0x1111111111111111111111111111111111111111));
        uint256 balance = vm.envOr("PRESS_BALANCE", uint256(0.52e18));
        string memory prevUri = vm.envOr("PREV_URI", string(""));
        bool second = bytes(prevUri).length != 0;

        // A token at the real IMD address that reports the balance for the press.
        vm.etch(IMD, address(new MockIMD()).code);
        MockIMD(IMD).mint(at, second ? balance + 0.52e18 : balance);

        // The real press runtime (immutables filled in) at `at`, with its constructor's storage.
        OuroborosPress built = new OuroborosPress();
        vm.etch(at, address(built).code);
        vm.store(at, bytes32(uint256(0)), vm.load(address(built), bytes32(uint256(0))));
        vm.store(at, bytes32(uint256(1)), vm.load(address(built), bytes32(uint256(1))));
        OuroborosPress press = OuroborosPress(payable(at));

        if (second) {
            vm.etch(INTAKE, address(new MockIntake()).code);
            bytes32 id = press.commission();
            (bool ok,) = MockIntake(INTAKE).deliver(at, id, keccak256("result.json"), prevUri);
            require(ok, "simulated delivery failed");
            press.inscribe(1, prevUri);
        }
        body = press.previewBody();
    }
}
