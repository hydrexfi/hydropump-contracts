// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title HydropumpGaugeToken
/// @notice Placeholder ERC20 for the pair that carries the Hydropump gauge. Fixed supply of 1, no mint path.
contract HydropumpGaugeToken is ERC20 {
    constructor(string memory name_, string memory symbol_, address recipient) ERC20(name_, symbol_) {
        _mint(recipient, 1e18);
    }
}
