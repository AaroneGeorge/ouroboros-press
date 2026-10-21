// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OuroborosPress} from "../../src/OuroborosPress.sol";

/// @notice Runs against live Robinhood Chain state; broadcasts nothing.
///           FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/*' -vv
///         Uses forge-std `deal` to give the press IMD on the fork (works if IMD keeps balances in
///         a standard mapping; if `deal` fails, that is a test-harness limit, not a press bug).
contract OuroborosPressForkTest is Test {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;

    OuroborosPress press;

    function setUp() public {
        vm.createSelectFork("robinhood");
        assertEq(block.chainid, 4663);
        press = new OuroborosPress();
    }

    function test_fork_liveAddresses() public view {
        assertGt(INTAKE.code.length, 0, "Intake v2 has code");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
    }

    /// The real requestWithFailure accepts the press's call and pulls exactly 0.5 IMD.
    function test_fork_commissionAgainstLiveIntake() public {
        deal(IMD, address(press), 1e18);
        bytes memory body = press.previewBody();
        console2.log(string(body));
        uint256 g = gasleft();
        bytes32 id = press.commission();
        console2.log("commission() gas on the live Intake:", g - gasleft());
        console2.logBytes32(id);
        assertTrue(id != bytes32(0));
        assertEq(IERC20Metadata(IMD).balanceOf(address(press)), 1e18 - 0.5e18, "pulled exactly PRICE");
        assertEq(IERC20Metadata(IMD).allowance(address(press), INTAKE), 0);
        assertTrue(press.busy());
    }

    /// The callback with the real IMD as bounty token, under the 200k stipend, as the Intake calls it.
    function test_fork_onResultUnderStipendWithRealIMD() public {
        deal(IMD, address(press), 1e18);
        address commissioner = makeAddr("commissioner");
        vm.prank(commissioner);
        bytes32 id = press.commission();
        string memory uri = "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/result.json";
        vm.prank(INTAKE);
        uint256 g = gasleft();
        (bool ok,) =
            address(press).call{gas: 200_000}(abi.encodeCall(OuroborosPress.onResult, (id, keccak256("result"), uri)));
        uint256 used = g - gasleft();
        console2.log("onResult gas with the real IMD bounty transfer:", used);
        assertTrue(ok);
        assertEq(press.chapterCount(), 1);
        assertEq(IERC20Metadata(IMD).balanceOf(commissioner), 0.02e18, "bounty paid with real IMD");
        assertLt(used, 150_000);
    }
}
