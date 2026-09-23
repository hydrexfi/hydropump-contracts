// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFeeUse} from "../interfaces/IFeeUse.sol";
import {IHydropumpLocker} from "../interfaces/IHydropumpLocker.sol";
import {IAlgebraPool} from "../interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {HydropumpAddresses} from "../libraries/HydropumpAddresses.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @notice Compounds fees into the original curve, burns leftover launch tokens, and places leftover
///         quote in a separate one-tick-spacing range below the launch token's spot price.
/// @dev Execution is permissionless and uses spot, with no oracle or MEV protection. Original locked
///      positions are only increased. The strategy owns at most one supplemental NFT per launch;
///      refreshing it burns acquired launch tokens and redeposits quote, never paying a caller.
contract AutoLpFeeUse is IFeeUse, ReentrancyGuard {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public constant nonfungiblePositionManager =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);
    IHydropumpLocker public immutable locker;
    uint256 private constant Q96 = 1 << 96;

    /// @notice Liquidity compounded into the original locked bands (not the supplemental position).
    mapping(address token => uint128 liquidity) public lifetimeLiquidityAdded;
    mapping(address token => uint256 amount) public lifetimeBurned;
    mapping(address token => uint256 id) public quotePosition;
    mapping(address token => bool exists) public hasQuotePosition;
    /// @notice Quote dust, or quote with no valid below-spot range, reserved for this launch only.
    mapping(address token => uint256 amount) public quoteCarry;

    event LiquidityAdded(
        address indexed token, uint256 indexed positionId, uint128 liquidity, uint256 amount0, uint256 amount1
    );
    event QuoteLiquidityAdded(
        address indexed token,
        uint256 indexed positionId,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint256 quoteUsed
    );
    event TokensBurned(address indexed token, uint256 amount);

    error NotLocker();
    error UnknownLaunch();
    error ZeroAddress();
    error InvalidAssets();
    error UnexpectedTokenUsage();

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
        _burn(token, tokenLeft);
        _refreshQuotePosition(token, quote, quoteLeft);
    }

    /// @notice Refresh supplemental liquidity even when no new fees are booked at the locker.
    /// @dev Anyone can call, but cannot choose a range or recipient or withdraw any funds.
    function refreshQuotePosition(address token) external nonReentrant {
        if (locker.poolOf(token) == address(0)) revert UnknownLaunch();
        _refreshQuotePosition(token, locker.quoteTokenOf(token), 0);
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
        // Check real liquidity math, including rounding to zero and exact range boundaries.
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

    function _refreshQuotePosition(address token, address quote, uint256 quoteAmount) internal {
        bool tokenIs0 = token < quote;
        if (hasQuotePosition[token]) {
            uint256 oldId = quotePosition[token];
            delete hasQuotePosition[token];
            delete quotePosition[token];
            (,,,,,,, uint128 oldLiquidity,,,,) = nonfungiblePositionManager.positions(oldId);
            if (oldLiquidity != 0) {
                nonfungiblePositionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(oldId, oldLiquidity, 0, 0, block.timestamp)
                );
            }
            (uint256 recovered0, uint256 recovered1) = nonfungiblePositionManager.collect(
                INonfungiblePositionManager.CollectParams(oldId, address(this), type(uint128).max, type(uint128).max)
            );
            nonfungiblePositionManager.burn(oldId);
            _burn(token, tokenIs0 ? recovered0 : recovered1);
            quoteAmount += tokenIs0 ? recovered1 : recovered0;
        }
        quoteAmount += quoteCarry[token];
        quoteCarry[token] = quoteAmount;
        if (quoteAmount == 0) return;
        address pool = locker.poolOf(token);
        (uint160 price, int24 tick,,,,) = IAlgebraPool(pool).globalState();
        (int24 lower, int24 upper, bool valid) = _quoteRange(tick, IAlgebraPool(pool).tickSpacing(), tokenIs0);
        (uint256 amount0, uint256 amount1) = tokenIs0 ? (uint256(0), quoteAmount) : (quoteAmount, uint256(0));
        // At extreme ticks there may be no valid range; dust may also buy zero liquidity.
        // Keep it attributed to this launch rather than reverting fee routing or mixing balances.
        if (!valid || _liquidity(price, lower, upper, amount0, amount1) == 0) return;
        IERC20(quote).forceApprove(address(nonfungiblePositionManager), quoteAmount);
        (uint256 id, uint128 added, uint256 used0, uint256 used1) = nonfungiblePositionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: tokenIs0 ? token : quote,
                token1: tokenIs0 ? quote : token,
                deployer: address(0),
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        IERC20(quote).forceApprove(address(nonfungiblePositionManager), 0);
        if ((tokenIs0 ? used0 : used1) != 0) revert UnexpectedTokenUsage();
        quotePosition[token] = id;
        hasQuotePosition[token] = true;
        uint256 used = tokenIs0 ? used1 : used0;
        quoteCarry[token] = quoteAmount - used;
        emit QuoteLiquidityAdded(token, id, lower, upper, added, used);
    }

    function _burn(address token, uint256 amount) internal {
        if (amount == 0) return;
        lifetimeBurned[token] += amount;
        ERC20Burnable(token).burn(amount);
        emit TokensBurned(token, amount);
    }

    /// @dev Negative ticks require floor division, not Solidity's truncation towards zero.
    ///      Token1 launches reverse the pool's tick direction relative to the launch token price.
    function _quoteRange(int24 tick, int24 spacing, bool tokenIs0)
        internal
        pure
        returns (int24 lower, int24 upper, bool valid)
    {
        if (spacing <= 0) return (0, 0, false);
        int256 floor = int256(tick) / spacing;
        if (tick < 0 && tick % spacing != 0) floor--;
        int256 near = tokenIs0 ? floor * spacing : (floor + 1) * spacing;
        int256 lo = tokenIs0 ? near - spacing : near;
        int256 hi = tokenIs0 ? near : near + spacing;
        if (lo < TickMath.MIN_TICK || hi > TickMath.MAX_TICK) return (0, 0, false);
        return (int24(lo), int24(hi), true);
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
