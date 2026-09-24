// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title HydropumpToken
/// @notice The ERC20 every Hydropump launch deploys.
/// @dev For `TAX_WINDOW` blocks after deployment, tokens leaving the launch pool are taxed and the tax is
///      burnt: 99% in the launch block, falling linearly to zero. The whole supply starts in that pool, so
///      every buy pays it. Tokens entering the pool are never taxed, since Algebra reverts a swap whose
///      input arrives short.
contract HydropumpToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant TAX_WINDOW = 10;
    uint256 internal constant MAX_TAX_BPS = 9_900;

    address public immutable launcher;
    uint256 public immutable launchBlock;

    /// @notice The launch pool, whose outgoing transfers are taxed during the window.
    address public pool;
    /// @notice Receives from the pool untaxed, so collecting LP fees in the window burns nothing.
    address public taxExempt;

    error NotLauncher();
    error PoolAlreadySet();

    constructor(string memory name_, string memory symbol_, uint256 supply) ERC20(name_, symbol_) ERC20Permit(name_) {
        launcher = msg.sender;
        launchBlock = block.number;
        _mint(msg.sender, supply);
    }

    /// @notice Tax on a buy in the current block, in basis points.
    function currentTaxBps() public view returns (uint256) {
        uint256 end = launchBlock + TAX_WINDOW;
        if (block.number >= end) return 0;
        return MAX_TAX_BPS * (end - block.number) / TAX_WINDOW;
    }

    /// @notice Starts taxing buys from `pool_`. The launcher calls it once, after the creator's buy.
    function setPool(address pool_, address taxExempt_) external {
        if (msg.sender != launcher) revert NotLauncher();
        if (pool != address(0)) revert PoolAlreadySet();
        pool = pool_;
        taxExempt = taxExempt_;
    }

    function _update(address from, address to, uint256 value) internal override {
        // The block check comes first so that after the window no storage is read.
        if (block.number < launchBlock + TAX_WINDOW && from != address(0) && from == pool && to != taxExempt) {
            uint256 tax = value * currentTaxBps() / 10_000;
            super._update(from, address(0), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}
