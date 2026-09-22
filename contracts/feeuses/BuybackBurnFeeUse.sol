// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeeUse} from "../interfaces/IFeeUse.sol";
import {IHydropumpLocker} from "../interfaces/IHydropumpLocker.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "../libraries/HydropumpAddresses.sol";
import {FeeSwapProtection} from "../libraries/FeeSwapProtection.sol";

/// @title BuybackBurnFeeUse
/// @notice Spends a launch's fees buying its own token back and destroying it.
/// @dev The quote side is swapped in the launch's own pool and burned with whatever launch token arrived
///      directly. Swaps require a historical oracle floor; unsafe fills leave fees booked in the locker.
contract BuybackBurnFeeUse is IFeeUse {
    using SafeERC20 for IERC20;

    ISwapRouter public constant swapRouter = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    IHydropumpLocker public immutable locker;

    mapping(address token => uint256) public lifetimeBurned;

    event BoughtAndBurned(address indexed token, uint256 quoteSpent, uint256 bought, uint256 burned);

    error NotLocker();
    error ZeroAddress();

    constructor(address _locker) {
        if (_locker == address(0)) revert ZeroAddress();
        locker = IHydropumpLocker(_locker);
    }

    function onFees(address token, address[] calldata assets, uint256[] calldata amounts) external {
        if (msg.sender != address(locker)) revert NotLocker();

        address quoteToken = locker.quoteTokenOf(token);

        uint256 quoteAmount;
        uint256 burned;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == quoteToken) quoteAmount += amounts[i];
            else if (assets[i] == token) burned += amounts[i];
        }

        uint256 bought;
        if (quoteAmount > 0) {
            uint256 minimum = FeeSwapProtection.minimumOutput(locker.poolOf(token), quoteToken, token, quoteAmount);
            IERC20(quoteToken).forceApprove(address(swapRouter), quoteAmount);
            bought = swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: quoteToken,
                    tokenOut: token,
                    deployer: address(0),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: quoteAmount,
                    amountOutMinimum: minimum,
                    limitSqrtPrice: 0
                })
            );
            IERC20(quoteToken).forceApprove(address(swapRouter), 0);
        }

        burned += bought;
        if (burned == 0) return;

        lifetimeBurned[token] += burned;

        // Burnt, not sent to a dead address: every launch token is a HydropumpToken and so ERC20Burnable,
        // and destroying the supply is what makes this irreversible rather than merely inaccessible.
        ERC20Burnable(token).burn(burned);

        emit BoughtAndBurned(token, quoteAmount, bought, burned);
    }
}
