// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

interface IERC20Burnable {
    function mint(address recipient, uint256 amount) external returns (bool);

    function burn(uint256 amount) external;

    function burnFrom(address from, uint256 amount) external;

    function isAdmin(address account) external returns (bool);
}
