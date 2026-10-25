// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeeUse} from "../interfaces/IFeeUse.sol";
import {IHydropumpLocker} from "../interfaces/IHydropumpLocker.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "../libraries/HydropumpAddresses.sol";
import {SwapPriceLimit} from "../libraries/SwapPriceLimit.sol";

/// @title BuybackBurnFeeUse
/// @notice Spends a launch's fees buying its own token back and destroying it.
/// @dev Buys only within `SwapPriceLimit`; unspent quote goes back to the locker, which rebooks it.
contract BuybackBurnFeeUse is IFeeUse {
    using SafeERC20 for IERC20;

    ISwapRouter public constant swapRouter = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    IHydropumpLocker public immutable locker;

    mapping(address token => uint256) public lifetimeBurned;

    event BoughtAndBurned(address indexed token, uint256 quoteSpent, uint256 bought, uint256 burned);
    event QuoteReturned(address indexed token, uint256 amount);

    error NotLocker();
    error ZeroAddress();

    constructor(address _locker) {
        if (_locker == address(0)) revert ZeroAddress();
        locker = IHydropumpLocker(_locker);
    }

    function onFees(address token, address[] calldata assets, uint256[] calldata amounts) external virtual {
        if (msg.sender != address(locker)) revert NotLocker();
        _handleFees(token, assets, amounts);
    }

    function _handleFees(address token, address[] calldata assets, uint256[] calldata amounts) internal {
        address quoteToken = locker.quoteTokenOf(token);

        uint256 quoteAmount;
        uint256 burned;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == quoteToken) quoteAmount += amounts[i];
            else if (assets[i] == token) burned += amounts[i];
        }

        uint256 bought;
        uint256 quoteSpent;
        if (quoteAmount > 0) (quoteSpent, bought) = _buy(token, quoteToken, quoteAmount);

        burned += bought;
        if (burned == 0) return;

        lifetimeBurned[token] += burned;

        ERC20Burnable(token).burn(burned);

        emit BoughtAndBurned(token, quoteSpent, bought, burned);
    }

    function _buy(address token, address quoteToken, uint256 quoteAmount)
        internal
        virtual
        returns (uint256 quoteSpent, uint256 bought)
    {
        (quoteSpent, bought) = _swapQuote(token, quoteToken, quoteAmount);
        _returnQuote(token, quoteToken, quoteAmount - quoteSpent);
    }

    function _swapQuote(address token, address quoteToken, uint256 quoteAmount)
        internal
        returns (uint256 quoteSpent, uint256 bought)
    {
        (uint160 limitSqrtPrice, bool room) = SwapPriceLimit.get(locker.poolOf(token), quoteToken < token);
        if (room) {
            uint256 held = IERC20(quoteToken).balanceOf(address(this));
            uint256 heldToken = IERC20(token).balanceOf(address(this));
            IERC20(quoteToken).forceApprove(address(swapRouter), quoteAmount);
            swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: quoteToken,
                    tokenOut: token,
                    deployer: address(0),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: quoteAmount,
                    amountOutMinimum: 0,
                    limitSqrtPrice: limitSqrtPrice
                })
            );
            IERC20(quoteToken).forceApprove(address(swapRouter), 0);
            // A delta, so quote donated here is never rebooked to the creator.
            quoteSpent = held - IERC20(quoteToken).balanceOf(address(this));
            // What arrived, not the router's figure: in the launch window the token taxes the buy.
            bought = IERC20(token).balanceOf(address(this)) - heldToken;
        }
    }

    function _returnQuote(address token, address quoteToken, uint256 unspent) internal {
        if (unspent > 0) {
            IERC20(quoteToken).safeTransfer(address(locker), unspent);
            emit QuoteReturned(token, unspent);
        }
    }
}
