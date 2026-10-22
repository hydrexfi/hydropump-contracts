// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {HydropumpLauncher} from "./HydropumpLauncher.sol";
import {HydropumpLocker} from "./HydropumpLocker.sol";
import {HydropumpToken} from "./HydropumpToken.sol";
import {IAlgebraPlugin} from "../interfaces/IAlgebraPlugin.sol";
import {IAlgebraPool} from "../interfaces/IAlgebraPool.sol";
import {IPairDirectory} from "../interfaces/IPairDirectory.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "../libraries/HydropumpAddresses.sol";
import {SwapPriceLimit} from "../libraries/SwapPriceLimit.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @title HydropumpRotator
/// @notice Retires a launch that never took off and moves its holders into the target the operator has
///         set for its quote token. Anyone can rotate an eligible launch. Its liquidity is pulled, the
///         unsold supply burnt and the quote spent on the target. Holders then burn the old token here for
///         a pro-rata share of what the rotation holds, whenever they like.
/// @dev Invariant: a rotation's `targetHeld` and `quoteHeld` belong to the dead token's outstanding supply,
///      so each token redeemed takes `amount / totalSupply` of both. Burning on redeem keeps the ratio fair
///      to everyone who has not redeemed yet, whatever the order.
contract HydropumpRotator is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    ISwapRouter public constant swapRouter = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    uint256 public constant MIN_AGE = 7 days;
    /// @notice The valuation must have stayed under the cap for every hour of this window.
    uint32 public constant HOLD_WINDOW = 24 hours;
    uint32 public constant HOLD_STEP = 1 hours;
    /// @notice Market cap cap as a multiple of the opening valuation: $20k on the $5k every launch opens at.
    uint256 public constant MAX_OPEN_MULTIPLE = 4;
    /// @notice The target buy also stops `SwapPriceLimit.BUFFER_TICKS` past the target's average over this
    ///         window, so a target pumped in an earlier block, which sets this block's open, is not bought high.
    uint32 public constant TARGET_AVERAGE_WINDOW = 1 hours;
    /// @notice `HydropumpLauncher.SUPPLY`, which the open valuation is measured on.
    uint256 public constant LAUNCH_SUPPLY = 10_000_000_000e18;

    HydropumpLocker public immutable locker;

    struct Rotation {
        address target;
        address quoteToken;
        uint256 targetHeld;
        uint256 quoteHeld;
    }

    /// @notice Sets each quote's target. Held apart from the owner, like the directory's daily key.
    address public operator;

    mapping(address quoteToken => address target) public targetOf;
    mapping(address dead => Rotation) public rotations;

    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event TargetUpdated(address indexed quoteToken, address indexed previousTarget, address indexed newTarget);
    event Rotated(
        address indexed dead, address indexed target, address indexed caller, uint256 burned, uint256 quoteReleased
    );
    event TargetBought(address indexed dead, address indexed target, uint256 quoteSpent, uint256 bought);
    event Redeemed(address indexed dead, address indexed holder, uint256 amount, uint256 targetOut, uint256 quoteOut);

    error NotOperator();
    error ZeroAddress();
    error LengthMismatch();
    error UnknownLaunch();
    error AlreadyRotated();
    error PredatesRotation();
    error TooYoung();
    error ValuationTooHigh();
    error NoTarget();
    error InvalidTarget();
    error NotRotated();
    error ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, address _operator, address _locker) Ownable(_owner) {
        if (_operator == address(0) || _locker == address(0)) revert ZeroAddress();
        locker = HydropumpLocker(_locker);
        operator = _operator;
        emit OperatorUpdated(address(0), _operator);
    }

    /*//////////////////////////////////////////////////////////////
                                 READ
    //////////////////////////////////////////////////////////////*/

    /// @notice Reverts with the reason `dead` cannot be rotated now; returns if it can.
    /// @dev Eligible: registered after `rotationStart`, not yet released, at least `MIN_AGE` old, and every
    ///      hourly average price over `HOLD_WINDOW` values it under `MAX_OPEN_MULTIPLE` times the open. The
    ///      open is today's directory start tick, which prices a launch at $5k in today's quote price, so a
    ///      launch on a quote the directory has disabled is not rotatable: its tick is no longer refreshed.
    ///      Hourly averages, not spot, so neither a dump nor a pump in the rotating block decides it.
    function checkRotatable(address dead) public view {
        HydropumpLocker.Launch memory launch = locker.getLaunch(dead);
        if (launch.pool == address(0)) revert UnknownLaunch();
        if (locker.released(dead)) revert AlreadyRotated();
        if (launch.createdAt <= locker.rotationStart()) revert PredatesRotation();
        if (block.timestamp < launch.createdAt + MIN_AGE) revert TooYoung();

        bool isToken0 = dead < launch.quoteToken;
        int24 open = _directory().requirePoolStartTick(dead, launch.quoteToken);
        int256 peak = _peakHourlyTick(launch.pool, isToken0) - (isToken0 ? int256(open) : -int256(open));
        if (!_underCap(peak, IERC20(dead).totalSupply())) revert ValuationTooHigh();
    }

    function isRotatable(address dead) external view returns (bool) {
        try this.checkRotatable(dead) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice What redeeming `amount` of `dead` pays right now.
    function previewRedeem(address dead, uint256 amount) public view returns (uint256 targetOut, uint256 quoteOut) {
        Rotation storage rotation = rotations[dead];
        if (rotation.target == address(0)) revert NotRotated();
        uint256 supply = IERC20(dead).totalSupply();
        if (amount == 0 || supply == 0) return (0, 0);
        targetOut = Math.mulDiv(rotation.targetHeld, amount, supply);
        quoteOut = Math.mulDiv(rotation.quoteHeld, amount, supply);
    }

    /*//////////////////////////////////////////////////////////////
                              USER WRITE
    //////////////////////////////////////////////////////////////*/

    /// @notice Retire `dead` into its quote's current target. Permissionless; nothing is paid to the caller.
    /// @dev Post: `dead`'s positions are empty, its unsold supply is burnt, and `rotations[dead]` holds the
    ///      released quote less whatever `SwapPriceLimit` let this block spend on the target.
    function rotate(address dead) external nonReentrant returns (uint256 quoteSpent, uint256 bought) {
        checkRotatable(dead);

        address quoteToken = locker.quoteTokenOf(dead);
        address target = targetOf[quoteToken];
        if (target == address(0)) revert NoTarget();
        _requireTarget(target, quoteToken);
        if (target == dead) revert InvalidTarget();
        // Bought within the launch tax window, most of the purchase would be burnt.
        if (HydropumpToken(target).currentTaxBps() != 0) revert InvalidTarget();

        uint256 heldDead = IERC20(dead).balanceOf(address(this));
        uint256 heldQuote = IERC20(quoteToken).balanceOf(address(this));
        locker.releaseLiquidity(dead);
        // Measured, not taken from the locker's figures, so the ledger matches what actually arrived.
        uint256 burned = IERC20(dead).balanceOf(address(this)) - heldDead;
        uint256 quoteReleased = IERC20(quoteToken).balanceOf(address(this)) - heldQuote;

        if (burned > 0) ERC20Burnable(dead).burn(burned);
        rotations[dead] = Rotation({target: target, quoteToken: quoteToken, targetHeld: 0, quoteHeld: quoteReleased});
        emit Rotated(dead, target, msg.sender, burned, quoteReleased);

        return _buy(dead);
    }

    /// @notice Spend more of a rotation's quote on its target, within this block's `SwapPriceLimit`.
    ///         Permissionless, for when one block could not fill it all.
    function buy(address dead) external nonReentrant returns (uint256 quoteSpent, uint256 bought) {
        if (rotations[dead].target == address(0)) revert NotRotated();
        return _buy(dead);
    }

    /// @notice Burn `amount` of a rotated token for its share of the target and any unspent quote.
    /// @dev Needs an allowance of `amount` (or a permit): the burn goes through `burnFrom`.
    function redeem(address dead, uint256 amount) external nonReentrant returns (uint256 targetOut, uint256 quoteOut) {
        if (amount == 0) revert ZeroAmount();
        (targetOut, quoteOut) = previewRedeem(dead, amount);

        Rotation storage rotation = rotations[dead];
        rotation.targetHeld -= targetOut;
        rotation.quoteHeld -= quoteOut;
        ERC20Burnable(dead).burnFrom(msg.sender, amount);

        if (targetOut > 0) IERC20(rotation.target).safeTransfer(msg.sender, targetOut);
        if (quoteOut > 0) IERC20(rotation.quoteToken).safeTransfer(msg.sender, quoteOut);
        emit Redeemed(dead, msg.sender, amount, targetOut, quoteOut);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _directory() internal view returns (IPairDirectory) {
        return IPairDirectory(HydropumpLauncher(locker.launcher()).pairDirectory());
    }

    /// @dev Highest hourly average tick over `HOLD_WINDOW`, measured in the launch token's favour: negated
    ///      when it is token1, where a higher price is a lower tick.
    function _peakHourlyTick(address pool, bool isToken0) internal view returns (int256 peak) {
        uint256 steps = HOLD_WINDOW / HOLD_STEP;
        uint32[] memory secondsAgos = new uint32[](steps + 1);
        for (uint256 i = 0; i <= steps; i++) {
            secondsAgos[i] = HOLD_WINDOW - uint32(i) * HOLD_STEP;
        }
        (int56[] memory cumulatives,) = IAlgebraPlugin(IAlgebraPool(pool).plugin()).getTimepoints(secondsAgos);

        peak = type(int256).min;
        for (uint256 i = 0; i < steps; i++) {
            int256 average = int256(cumulatives[i + 1] - cumulatives[i]) / int256(uint256(HOLD_STEP));
            if (!isToken0) average = -average;
            if (average > peak) peak = average;
        }
    }

    /// @dev `ticksAboveOpen` prices the launch token against the open. The cap is on market cap, so the
    ///      price ratio is scaled by the supply still in existence.
    function _underCap(int256 ticksAboveOpen, uint256 supply) internal pure returns (bool) {
        if (ticksAboveOpen > TickMath.MAX_TICK) return false;
        if (ticksAboveOpen < TickMath.MIN_TICK) ticksAboveOpen = TickMath.MIN_TICK;

        uint256 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(int24(ticksAboveOpen));
        uint256 ratioX96 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 96);
        return Math.mulDiv(ratioX96, supply, LAUNCH_SUPPLY) < MAX_OPEN_MULTIPLE << 96;
    }

    function _buy(address dead) internal returns (uint256 quoteSpent, uint256 bought) {
        Rotation storage rotation = rotations[dead];
        (address target, address quoteToken, uint256 amount) =
            (rotation.target, rotation.quoteToken, rotation.quoteHeld);
        // A target rotated out since has no pool to buy from; the quote stays redeemable instead.
        if (amount == 0 || locker.released(target)) return (0, 0);

        address pool = locker.poolOf(target);
        bool zeroToOne = quoteToken < target;
        (uint160 limitSqrtPrice, bool room) = SwapPriceLimit.get(pool, zeroToOne);
        if (!room) return (0, 0);
        (limitSqrtPrice, room) = _withinAverage(pool, zeroToOne, limitSqrtPrice);
        if (!room) return (0, 0);

        uint256 heldQuote = IERC20(quoteToken).balanceOf(address(this));
        uint256 heldTarget = IERC20(target).balanceOf(address(this));
        IERC20(quoteToken).forceApprove(address(swapRouter), amount);
        swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: quoteToken,
                tokenOut: target,
                deployer: address(0),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: 0,
                limitSqrtPrice: limitSqrtPrice
            })
        );
        IERC20(quoteToken).forceApprove(address(swapRouter), 0);
        quoteSpent = heldQuote - IERC20(quoteToken).balanceOf(address(this));
        bought = IERC20(target).balanceOf(address(this)) - heldTarget;

        rotation.quoteHeld = amount - quoteSpent;
        rotation.targetHeld += bought;
        emit TargetBought(dead, target, quoteSpent, bought);
    }

    /// @dev Tightens `limitSqrtPrice` to `BUFFER_TICKS` past the pool's average over `TARGET_AVERAGE_WINDOW`.
    function _withinAverage(address pool, bool zeroToOne, uint160 limitSqrtPrice)
        internal
        view
        returns (uint160, bool room)
    {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TARGET_AVERAGE_WINDOW;
        (int56[] memory cumulatives,) = IAlgebraPlugin(IAlgebraPool(pool).plugin()).getTimepoints(secondsAgos);
        int256 average = int256(cumulatives[1] - cumulatives[0]) / int256(uint256(TARGET_AVERAGE_WINDOW));

        int256 limit = zeroToOne ? average - SwapPriceLimit.BUFFER_TICKS : average + SwapPriceLimit.BUFFER_TICKS;
        if (limit <= TickMath.MIN_TICK) limit = TickMath.MIN_TICK + 1;
        if (limit >= TickMath.MAX_TICK) limit = TickMath.MAX_TICK - 1;
        uint160 averageLimit = TickMath.getSqrtRatioAtTick(int24(limit));

        if (zeroToOne ? averageLimit > limitSqrtPrice : averageLimit < limitSqrtPrice) limitSqrtPrice = averageLimit;
        (uint160 spot,,,,,) = IAlgebraPool(pool).globalState();
        room = zeroToOne ? spot > limitSqrtPrice : spot < limitSqrtPrice;
        return (limitSqrtPrice, room);
    }

    /// @dev A target must be a live Hydropump launch on the same quote, so the buy is one hop on its pool.
    function _requireTarget(address target, address quoteToken) internal view {
        if (locker.quoteTokenOf(target) != quoteToken || locker.released(target)) revert InvalidTarget();
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Point each quote at the launch its dead launches rotate into. Zero clears it.
    /// @dev Only future rotations follow; one already made keeps the target it was made with.
    function setTargets(address[] calldata quoteTokens, address[] calldata targets) external {
        if (msg.sender != operator) revert NotOperator();
        if (quoteTokens.length != targets.length) revert LengthMismatch();
        for (uint256 i = 0; i < quoteTokens.length; i++) {
            if (targets[i] != address(0)) _requireTarget(targets[i], quoteTokens[i]);
            emit TargetUpdated(quoteTokens[i], targetOf[quoteTokens[i]], targets[i]);
            targetOf[quoteTokens[i]] = targets[i];
        }
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }
}
