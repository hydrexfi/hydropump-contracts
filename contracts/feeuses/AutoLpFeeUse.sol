// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFeeUse} from "../interfaces/IFeeUse.sol";
import {IHydropumpLocker} from "../interfaces/IHydropumpLocker.sol";
import {IAlgebraPool} from "../interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {HydropumpAddresses} from "../libraries/HydropumpAddresses.sol";

/// @title AutoLpFeeUse
/// @notice Puts a launch's fees back into its own curve, permanently.
/// @dev `increaseLiquidity` is not owner-gated on Algebra, so this can grow a band the locker holds
///      without the locker parting with it. The position has no withdraw path, so it is one-way.
///
///      A band takes one ratio, so a remainder happens on nearly every call. It goes back to the locker
///      rather than sitting here — as does the whole amount when no deposit is possible at all, which is
///      what keeps one-sided fees from reverting the caller's entire transaction.
contract AutoLpFeeUse is IFeeUse {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);

    IHydropumpLocker public immutable locker;

    mapping(address token => uint128 liquidity) public lifetimeLiquidityAdded;

    event LiquidityAdded(
        address indexed token, uint256 indexed positionId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event RemainderReturned(address indexed token, address indexed asset, uint256 amount);

    error NotLocker();
    error UnknownLaunch();
    error ZeroAddress();

    constructor(address _locker) {
        if (_locker == address(0)) revert ZeroAddress();
        locker = IHydropumpLocker(_locker);
    }

    /*//////////////////////////////////////////////////////////////
                                 READ
    //////////////////////////////////////////////////////////////*/

    /// @notice The band to deposit into: the one holding the current price, or failing that the nearest.
    /// @dev A straddling band takes both sides, so it is the first choice — but the price is not always
    ///      inside one (a token1 launch opens on band 0's edge, and a run-out launch sits past the tail).
    function targetBand(address token) public view returns (uint256 positionId, bool found) {
        (positionId, found,,) = _targetBand(token);
    }

    /// @dev Also reports where the band sits relative to the price, which decides which sides it can take.
    function _targetBand(address token)
        internal
        view
        returns (uint256 positionId, bool found, bool needs0, bool needs1)
    {
        address pool = locker.poolOf(token);
        if (pool == address(0)) revert UnknownLaunch();
        (, int24 tick,,,,) = IAlgebraPool(pool).globalState();

        uint256[] memory positionIds = locker.getPositions(token);
        uint256 bestDistance = type(uint256).max;
        int24 bestLower;
        int24 bestUpper;

        for (uint256 i = 0; i < positionIds.length; i++) {
            (,,,,, int24 lower, int24 upper,,,,,) = nonfungiblePositionManager.positions(positionIds[i]);
            // A band holding the price takes both sides, and is always the first choice.
            if (tick >= lower && tick < upper) return (positionIds[i], true, true, true);

            uint256 distance = tick < lower ? uint256(int256(lower - tick)) : uint256(int256(tick - upper));
            if (distance < bestDistance) {
                bestDistance = distance;
                positionId = positionIds[i];
                found = true;
                (bestLower, bestUpper) = (lower, upper);
            }
        }

        // A band entirely above the price is pure token0; one entirely below is pure token1.
        if (found) (needs0, needs1) = tick < bestLower ? (true, false) : (false, true);
    }

    /*//////////////////////////////////////////////////////////////
                              USER WRITE
    //////////////////////////////////////////////////////////////*/

    function onFees(address token, address[] calldata assets, uint256[] calldata amounts) external {
        if (msg.sender != address(locker)) revert NotLocker();

        address quoteToken = locker.quoteTokenOf(token);
        (address token0, address token1) = token < quoteToken ? (token, quoteToken) : (quoteToken, token);

        // Whatever arrived, expressed as the pool's two sides.
        uint256 amount0;
        uint256 amount1;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == token0) amount0 += amounts[i];
            else if (assets[i] == token1) amount1 += amounts[i];
        }

        // A deposit needs every side the band is able to take: Algebra sizes liquidity by the smaller of
        // the two, so a straddling band offered only one side computes zero and reverts
        // (`zeroLiquidityDesired`). Checked rather than caught, so the outcome does not depend on how
        // much gas the caller happened to send.
        (uint256 positionId, bool found, bool needs0, bool needs1) = _targetBand(token);
        if (!found || (needs0 && amount0 == 0) || (needs1 && amount1 == 0)) {
            _returnToLocker(token, token0, amount0);
            _returnToLocker(token, token1, amount1);
            return;
        }

        IERC20(token0).forceApprove(address(nonfungiblePositionManager), amount0);
        IERC20(token1).forceApprove(address(nonfungiblePositionManager), amount1);

        (uint128 liquidity, uint256 used0, uint256 used1) = nonfungiblePositionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                // No price to be protected from: this deposits rather than buys, so an adverse price
                // only changes how the two sides pair off.
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        IERC20(token0).forceApprove(address(nonfungiblePositionManager), 0);
        IERC20(token1).forceApprove(address(nonfungiblePositionManager), 0);

        lifetimeLiquidityAdded[token] += liquidity;
        emit LiquidityAdded(token, positionId, liquidity, used0, used1);

        _returnToLocker(token, token0, amount0 - used0);
        _returnToLocker(token, token1, amount1 - used1);
    }

    function _returnToLocker(address token, address asset, uint256 amount) internal {
        if (amount == 0) return;

        IERC20(asset).safeTransfer(address(locker), amount);
        emit RemainderReturned(token, asset, amount);
    }
}
