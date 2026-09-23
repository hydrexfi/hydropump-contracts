// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFeeUse} from "../interfaces/IFeeUse.sol";
import {IHydropumpLocker} from "../interfaces/IHydropumpLocker.sol";
import {IAlgebraPool} from "../interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {HydropumpAddresses} from "../libraries/HydropumpAddresses.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @notice Compounds fees into the original locked curve and returns unused assets to the locker.
/// @dev The locker rebooks both remainders per launch. Later permissionless calls can retry them,
///      together with new fees, when the pool ratio permits. No tokens are burned and no new position
///      is created. Execution uses spot without an oracle or MEV protection.
contract AutoLpFeeUse is IFeeUse, ReentrancyGuard {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);
    IHydropumpLocker public immutable locker;
    uint256 private constant Q96 = 1 << 96;

    mapping(address token => uint128 liquidity) public lifetimeLiquidityAdded;

    event LiquidityAdded(
        address indexed token, uint256 indexed positionId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event RemainderReturned(address indexed token, address indexed asset, uint256 amount);

    error NotLocker();
    error UnknownLaunch();
    error ZeroAddress();
    error InvalidAssets();

    constructor(address _locker) {
        if (_locker == address(0)) revert ZeroAddress();
        locker = IHydropumpLocker(_locker);
    }

    /// @notice Existing launch band containing spot, or the closest band when spot lies outside all bands.
    function targetBand(address token) public view returns (uint256 positionId, bool found) {
        address pool = locker.poolOf(token);
        if (pool == address(0)) revert UnknownLaunch();
        (, int24 tick,,,,) = IAlgebraPool(pool).globalState();
        uint256[] memory ids = locker.getPositions(token);
        uint256 bestDistance = type(uint256).max;
        for (uint256 i; i < ids.length; i++) {
            (,,,,, int24 lower, int24 upper,,,,,) = nonfungiblePositionManager.positions(ids[i]);
            if (tick >= lower && tick < upper) return (ids[i], true);
            uint256 distance = tick < lower ? uint256(int256(lower) - tick) : uint256(int256(tick) - upper);
            if (distance < bestDistance) {
                bestDistance = distance;
                positionId = ids[i];
                found = true;
            }
        }
    }

    function onFees(address token, address[] calldata assets, uint256[] calldata amounts) external nonReentrant {
        if (msg.sender != address(locker)) revert NotLocker();
        address quote = locker.quoteTokenOf(token);
        if (assets.length != 2 || amounts.length != 2 || assets[0] != token || assets[1] != quote) {
            revert InvalidAssets();
        }
        (uint256 tokenLeft, uint256 quoteLeft) = _compound(token, quote, amounts[0], amounts[1]);
        _returnToLocker(token, token, tokenLeft);
        _returnToLocker(token, quote, quoteLeft);
    }

    function _compound(address token, address quote, uint256 tokenAmount, uint256 quoteAmount)
        internal
        returns (uint256 tokenLeft, uint256 quoteLeft)
    {
        (uint256 id, bool found) = targetBand(token);
        if (!found) return (tokenAmount, quoteAmount);
        bool tokenIs0 = token < quote;
        (uint256 amount0, uint256 amount1) = tokenIs0 ? (tokenAmount, quoteAmount) : (quoteAmount, tokenAmount);
        (,,,,, int24 lower, int24 upper,,,,,) = nonfungiblePositionManager.positions(id);
        (uint160 price,,,,,) = IAlgebraPool(locker.poolOf(token)).globalState();
        // Check actual liquidity math, including rounding to zero and exact range boundaries.
        // Retain dust rather than allowing a zero-liquidity deposit to revert the whole route.
        if (_liquidity(price, lower, upper, amount0, amount1) == 0) return (tokenAmount, quoteAmount);
        IERC20(token).forceApprove(address(nonfungiblePositionManager), tokenAmount);
        IERC20(quote).forceApprove(address(nonfungiblePositionManager), quoteAmount);
        (uint128 added, uint256 used0, uint256 used1) = nonfungiblePositionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams(id, amount0, amount1, 0, 0, block.timestamp)
        );
        IERC20(token).forceApprove(address(nonfungiblePositionManager), 0);
        IERC20(quote).forceApprove(address(nonfungiblePositionManager), 0);
        lifetimeLiquidityAdded[token] += added;
        emit LiquidityAdded(token, id, added, used0, used1);
        return tokenIs0 ? (amount0 - used0, amount1 - used1) : (amount1 - used1, amount0 - used0);
    }

    function _returnToLocker(address token, address asset, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(asset).safeTransfer(address(locker), amount);
        emit RemainderReturned(token, asset, amount);
    }

    function _liquidity(uint160 price, int24 lower, int24 upper, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint256)
    {
        uint160 a = TickMath.getSqrtRatioAtTick(lower);
        uint160 b = TickMath.getSqrtRatioAtTick(upper);
        if (price <= a) return Math.mulDiv(amount0, Math.mulDiv(a, b, Q96), b - a);
        if (price >= b) return Math.mulDiv(amount1, Q96, b - a);
        return
            Math.min(Math.mulDiv(amount0, Math.mulDiv(price, b, Q96), b - price), Math.mulDiv(amount1, Q96, price - a));
    }
}
