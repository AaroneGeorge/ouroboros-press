// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 18-decimal stand-in for IMD on Robinhood Chain, with test knobs: anyone can mint and
///         burn, transfers can be blocked (the real IMD's owner can block transfers), and every
///         balance update can be made to burn a chosen amount of gas (an expensive token).
contract MockIMD is ERC20 {
    bool public blocked;
    uint256 public gasBurn;

    constructor() ERC20("Identity MD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setBlocked(bool b) external {
        blocked = b;
    }

    function setGasBurn(uint256 g) external {
        gasBurn = g;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked || from == address(0) || to == address(0), "MockIMD: blocked");
        uint256 g = gasBurn;
        if (g != 0) {
            uint256 start = gasleft();
            while (start - gasleft() < g) {}
        }
        super._update(from, to, value);
    }
}
