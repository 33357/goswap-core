// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import '../GoSwapERC20.sol';

contract MockERC20 is GoSwapERC20 {
    constructor(uint _totalSupply) public {
        _mint(msg.sender, _totalSupply);
    }
}