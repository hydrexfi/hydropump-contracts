// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {LaunchCurveFixture} from "./helpers/LaunchCurveFixture.sol";

/// @notice The launch curve against every quote the generator emits, on both sides of the pair.
/// @dev Start ticks come from script/quotes/quote-tokens.json, so this tests the generator and the
///      launcher together rather than a hand-picked number.
contract LaunchCurveForkTest is LaunchCurveFixture {
    /// What the curve costs to climb, which nothing else here pins.
    ///
    /// The shape tests compare the two orientations against each other, so they hold for any curve — a
    /// reweighting changes what a launch costs to move without failing a single one of them. This is the
    /// assertion that notices.
    ///
    /// Measured in multiples of the opening valuation rather than dollars, so it is independent of the
    /// quote token and its decimals: a launch opens at $5k, and reaching $1m means buying it to 200x.
    function test_ReachingTwoHundredXCostsAboutFourteenTimesTheOpeningValuation() public onlyForked {
        Quote memory q = _quote("WETH");
        _registerQuote(q.token, q.startTick);
        (address token, address pool,,) = _launchOnSide(q.token, true, bytes32(0));

        uint256 openingFdv = _fdvUsdE8(pool, q, token);
        uint256 target = openingFdv * 200;

        // Walked up in slices: one enormous swap pays the whole curve's slippage at once and overstates
        // the cost. A patient buyer is the honest measure of what a market cap costs.
        uint256 spent;
        for (uint256 i = 0; i < 400 && _fdvUsdE8(pool, q, token) < target; i++) {
            uint256 slice = 0.15 ether;
            _swapIn(alice, q.token, token, slice);
            spent += slice;
        }

        assertGe(_fdvUsdE8(pool, q, token), target, "never reached 200x");

        // Spend, expressed in opening valuations. $70k of buying against a $5k opening is 14x.
        uint256 spentUsdE8 = Math.mulDiv(spent, q.priceUsdE8, 10 ** q.decimals);
        uint256 multiple = (spentUsdE8 * 100) / openingFdv;

        console2.log("opening FDV (e8)   ", openingFdv);
        console2.log("quote spent (e8)   ", spentUsdE8);
        console2.log("x opening (hundredths)", multiple);

        // Wide bounds: this is a guard against the curve being reweighted by accident, not a price oracle.
        assertGt(multiple, 1_000, "far cheaper to climb than the curve intends");
        assertLt(multiple, 2_200, "far dearer to climb than the curve intends");
    }

    /// Documents what a launch pool actually charges today. The split is a ratio applied to whatever is
    /// collected, so it holds at any pool fee — but the absolute amounts scale with it.
    function test_EffectivePoolFeeAndSplitAreIndependent() public onlyForked {
        Quote memory q = _quote("WETH");
        (address token, address pool,,) = _launchOnSide(q.token, true, bytes32(0));

        (,,, uint16 pluginConfig,,) = IAlgebraPool(pool).globalState();
        uint256 amountIn = 1 ether;
        _swapIn(alice, q.token, token, amountIn);

        locker.splitRewards(token);
        (, uint128 grossQuote) = locker.lifetimeFees(token);

        // Hundredths of a bip, denominator 1e6 — the same units as the pool fee.
        uint256 effectiveFee = (uint256(grossQuote) * 1e6) / amountIn;
        console2.log("pool.fee() at launch  ", uint256(IAlgebraPool(pool).fee()));
        console2.log("effective fee taken   ", effectiveFee);

        assertEq(pluginConfig & 128, 128, "DYNAMIC_FEE is on, so the plugin owns the fee");
        assertEq(locker.creatorOwed(token, q.token), uint256(grossQuote) - uint256(grossQuote) / 4);
        assertEq(locker.protocolOwed(q.token), uint256(grossQuote) / 4);
    }

    function test_RoundTripSellReturnsQuote() public onlyForked {
        Quote memory q = _quote("WETH");
        (address token,,,) = _launchOnSide(q.token, true, bytes32(0));
        _passLaunchWindow();

        uint256 bought = _swapIn(alice, q.token, token, 1 ether);
        uint256 quoteBefore = IERC20(q.token).balanceOf(alice);

        uint256 back = _sell(alice, token, q.token, bought);

        assertGt(back, 0);
        assertEq(IERC20(q.token).balanceOf(alice), quoteBefore + back);
        // Two fees plus curve movement, so expect a couple of percent of round-trip loss.
        assertLt(back, 1 ether);
        assertGt(back, 0.9 ether, "a round trip should not lose more than a few percent");
    }
}
