// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title HydropumpToken
/// @notice ERC20 deployed by the Hydropump launchpad for every launch
/// @dev Fixed supply minted once in the constructor; includes burn and permit
contract HydropumpToken is ERC20Permit, ERC20Burnable {
    constructor(string memory _name, string memory _symbol, address[] memory _recipients, uint256[] memory _amounts)
        ERC20(_name, _symbol)
        ERC20Permit(_name)
    {
        require(_recipients.length == _amounts.length, "Length mismatch");
        require(_recipients.length > 0, "Empty arrays");

        for (uint256 i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0), "Invalid recipient");
            require(_amounts[i] > 0, "Invalid amount");
            _mint(_recipients[i], _amounts[i]);
        }
    }
}
