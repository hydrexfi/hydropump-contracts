// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    /// @dev Models a policy-gated token — a B20, a token with a blocklist — where a transfer to the wrong
    ///      address reverts rather than returning false.
    mapping(address => bool) public blocked;

    error TransferBlocked(address account);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (blocked[from]) revert TransferBlocked(from);
        if (blocked[to]) revert TransferBlocked(to);
        super._update(from, to, value);
    }
}
