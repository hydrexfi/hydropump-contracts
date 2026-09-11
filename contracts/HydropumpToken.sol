// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {ITokenParams} from "./interfaces/ITokenParams.sol";

/// @title HydropumpToken
/// @notice The ERC20 every Hydropump launch deploys. Constructed to have deterministic address.
contract HydropumpToken is ERC20, ERC20Burnable, ERC20Permit {
    constructor() ERC20(_pendingName(), _pendingSymbol()) ERC20Permit(_pendingName()) {
        (,, uint256 supply, address recipient) = _pending();
        _mint(recipient, supply);
    }
}

function _pending() view returns (string memory, string memory, uint256, address) {
    return ITokenParams(msg.sender).pendingToken();
}

function _pendingName() view returns (string memory name) {
    (name,,,) = _pending();
}

function _pendingSymbol() view returns (string memory symbol) {
    (, symbol,,) = _pending();
}
