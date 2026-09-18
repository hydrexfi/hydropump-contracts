// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title HydropumpToken
/// @notice The ERC20 every Hydropump launch deploys.
contract HydropumpToken is ERC20, ERC20Burnable, ERC20Permit {
    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) ERC20Permit(name_) {
        _mint(msg.sender, supply);
    }
}
