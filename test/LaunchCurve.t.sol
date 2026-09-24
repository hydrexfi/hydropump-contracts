// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../contracts/core/HydropumpLocker.sol";
import {HydropumpToken} from "../contracts/core/HydropumpToken.sol";
import {TickMath} from "../contracts/libraries/TickMath.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {MockAlgebra, MockAlgebraPool} from "./mocks/MockAlgebra.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The launch curve seeded on either side of the pair, against a stand-in Algebra.
/// @dev The launch token's address comes out of CREATE2 and cannot be chosen, so the orientation is forced
///      from the other end: a quote etched near the bottom of the address space can never be sorted below,
///      and one near the top can never be sorted above. Those two quotes are the whole fixture.
///
///      What is asserted here is the shape of the curve — direction, alignment, contiguity, and that no band
///      ever straddles the opening price — across tick spacings and every start tick the generator produces.
///      The fork suites price the same launches against real Algebra.
contract LaunchCurveTest is HydropumpFixture {
    /// @dev Quote raw units per one whole (1e18) launch token, scaled by 1e18. A pool quotes token1 in
    ///      token0, so reading the launch token's price off one means inverting when it is token1. Squaring
    ///      goes through mulDiv because a mirrored tick can be large and positive, where sqrtPriceX96 squared
    ///      overflows a uint256 outright.
    function _priceE18(address pool, address token, address quoteToken) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,) = MockAlgebraPool(pool).globalState();
        uint256 priceQ96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        return token < quoteToken ? Math.mulDiv(priceQ96, 1e36, 1 << 96) : Math.mulDiv(1e36, 1 << 96, priceQ96);
    }

    struct Band {
        int24 lower;
        int24 upper;
    }

    function _bands(uint256[] memory positionIds) internal view returns (Band[] memory bands) {
        bands = new Band[](positionIds.length);
        for (uint256 i = 0; i < positionIds.length; i++) {
            (int24 lower, int24 upper) = npm.range(positionIds[i]);
            bands[i] = Band(lower, upper);
        }
    }

    /// @dev The shape every launch must have, whichever side of the pair it landed on: bands on the launch
    ///      token's side of the price, aligned, contiguous, running away from it, band 0 nearest.
    function _assertCurveShape(address token, address quoteToken, address pool, uint256[] memory positionIds)
        internal
        view
    {
        bool isToken0 = token < quoteToken;
        int24 spacing = MockAlgebraPool(pool).tickSpacing();
        int24 tick = _currentTick(pool);
        Band[] memory bands = _bands(positionIds);

        assertEq(bands.length, launcher.bandCount(), "band count");

        int24 edge;
        for (uint256 i = 0; i < bands.length; i++) {
            assertLt(bands[i].lower, bands[i].upper, "band must be non-empty");
            assertEq(bands[i].lower % spacing, 0, "lower must align to spacing");
            assertEq(bands[i].upper % spacing, 0, "upper must align to spacing");
            assertGt(npm.liquidityOf(positionIds[i]), 0, "band must hold liquidity");
            assertEq(npm.ownerOf(positionIds[i]), address(locker), "band must be locked");

            if (isToken0) {
                // Token0 liquidity lives above the price, so the ladder climbs.
                assertGe(bands[i].lower, tick, "token0 band must sit at or above the price");
                if (i > 0) assertEq(bands[i].lower, edge, "bands must be contiguous");
                edge = bands[i].upper;
            } else {
                // Token1 liquidity lives below it, so the same ladder descends.
                assertLe(bands[i].upper, tick, "token1 band must sit at or below the price");
                if (i > 0) assertEq(bands[i].upper, edge, "bands must be contiguous");
                edge = bands[i].lower;
            }
        }
    }

    // ---------------------------------------------------------------- direction

    function test_Token0LaunchRunsTheCurveUpFromTheStartTick() public {
        (address token, address pool, uint256[] memory positionIds) = _launch(HIGH_QUOTE);

        assertTrue(token < HIGH_QUOTE, "fixture: this quote forces the token0 side");
        assertEq(MockAlgebraPool(pool).token0(), token);
        assertEq(MockAlgebraPool(pool).token1(), HIGH_QUOTE);
        assertEq(_currentTick(pool), WETH_START_TICK, "pool opens at the configured tick");

        _assertCurveShape(token, HIGH_QUOTE, pool, positionIds);

        Band[] memory bands = _bands(positionIds);
        assertEq(bands[0].lower, -228_200, "band 0 starts at the price");
        assertEq(bands[0].upper, -214_200, "and reaches 14,000 ticks above it");
        assertEq(bands[4].upper, -228_200 + 887_200, "the tail runs the full span up");
    }

    function test_Token1LaunchRunsTheSameCurveDownFromTheMirroredTick() public {
        (address token, address pool, uint256[] memory positionIds) = _launch(LOW_QUOTE);

        assertTrue(token > LOW_QUOTE, "fixture: this quote forces the token1 side");
        assertEq(MockAlgebraPool(pool).token0(), LOW_QUOTE);
        assertEq(MockAlgebraPool(pool).token1(), token);
        assertEq(_currentTick(pool), -WETH_START_TICK, "pool opens at the negated tick");

        _assertCurveShape(token, LOW_QUOTE, pool, positionIds);

        Band[] memory bands = _bands(positionIds);
        assertEq(bands[0].upper, 228_200, "band 0 starts at the price");
        assertEq(bands[0].lower, 214_200, "and reaches 14,000 ticks below it");
        assertEq(bands[4].lower, 228_200 - 887_200, "the tail runs the full span down");
    }

    /// The two orientations have to be the same ladder, reflected. Band for band, the distance from the
    /// start tick and the width of the range must match — only the sign differs.
    function test_TheTwoOrientationsAreTheSameLadderReflected() public {
        (address up, address upPool, uint256[] memory upIds) = _launch(HIGH_QUOTE);
        (address down, address downPool, uint256[] memory downIds) = _launch(LOW_QUOTE);

        Band[] memory upBands = _bands(upIds);
        Band[] memory downBands = _bands(downIds);
        int24 upBase = _currentTick(upPool);
        int24 downBase = _currentTick(downPool);
        assertEq(downBase, -upBase, "the opening prices are reciprocal");

        for (uint256 i = 0; i < upBands.length; i++) {
            assertEq(
                upBands[i].lower - upBase,
                downBase - downBands[i].upper,
                "band i must start the same distance from the price on both sides"
            );
            assertEq(
                upBands[i].upper - upBands[i].lower, downBands[i].upper - downBands[i].lower, "and be the same width"
            );
        }

        // Which means a launch token opens at the same price in quote terms whichever side it landed on.
        assertApproxEqRel(
            _priceE18(upPool, up, HIGH_QUOTE),
            _priceE18(downPool, down, LOW_QUOTE),
            0.0002e18,
            "opening price must survive the mirror"
        );
    }

    // ---------------------------------------------------------------- purity

    function test_NeitherSideConsumesAWeiOfQuote() public {
        (address token0Launch,,) = _launch(HIGH_QUOTE);
        (address token1Launch,,) = _launch(LOW_QUOTE);

        // `QuoteConsumed` would have reverted the launch outright, so reaching here is most of the proof.
        // The balances close it: nothing was pulled, and nothing is stranded.
        assertEq(IERC20(HIGH_QUOTE).balanceOf(address(launcher)), 0);
        assertEq(IERC20(LOW_QUOTE).balanceOf(address(launcher)), 0);
        assertEq(IERC20(HIGH_QUOTE).balanceOf(address(locker)), 0);
        assertEq(IERC20(LOW_QUOTE).balanceOf(address(locker)), 0);
        assertEq(IERC20(token0Launch).balanceOf(address(launcher)), 0, "launcher holds no launch token either");
        assertEq(IERC20(token1Launch).balanceOf(address(launcher)), 0);
    }

    function test_FullSupplyReachesThePoolOnBothSides() public {
        (address token, address pool,) = _launch(HIGH_QUOTE);
        assertEq(IERC20(token).totalSupply(), launcher.SUPPLY());
        assertEq(IERC20(token).balanceOf(pool), launcher.SUPPLY(), "token0 side");

        (address mirrored, address mirroredPool,) = _launch(LOW_QUOTE);
        assertEq(IERC20(mirrored).balanceOf(mirroredPool), launcher.SUPPLY(), "token1 side");
    }

    /// Whatever rounding leaves behind is burnt, so nobody walks away from a launch already holding some.
    function test_LaunchLeavesTheCreatorHoldingNothing() public {
        (address token,,) = _launch(HIGH_QUOTE);

        assertEq(IERC20(token).balanceOf(creator), 0, "the launcher must not be paid in its own token");
        assertEq(IERC20(token).balanceOf(address(launcher)), 0, "and must keep none of it");
        assertEq(IERC20(token).totalSupply(), launcher.SUPPLY(), "this launch happened to round clean");
    }

    /// The burn is real when there is something to burn: supply falls by exactly what did not reach the
    /// pool, rather than that amount landing on whoever launched.
    function test_RoundingDustIsBurntNotPaidOut() public {
        uint256 supply = launcher.SUPPLY();
        (address token, address pool,) = _launch(HIGH_QUOTE);

        uint256 inPool = IERC20(token).balanceOf(pool);
        assertEq(IERC20(token).totalSupply(), inPool, "supply is exactly what the pool holds");
        assertEq(IERC20(token).balanceOf(creator), 0);
        assertLe(inPool, supply, "and never more than was minted");
    }

    function test_SupplyIsSplitByTheSameSharesOnBothSides() public {
        (address token, address pool, uint256[] memory ids) = _launch(HIGH_QUOTE);
        (address mirrored, address mirroredPool, uint256[] memory mirroredIds) = _launch(LOW_QUOTE);

        assertEq(IERC20(token).balanceOf(pool), IERC20(mirrored).balanceOf(mirroredPool));
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(npm.liquidityOf(ids[i]), npm.liquidityOf(mirroredIds[i]), "band i takes the same share");
        }
    }

    /// A pool opened before the launch, at a price the launcher did not choose, is the one way the bands can
    /// end up on the wrong side of the price. `createAndInitializePoolIfNecessary` is a no-op against an
    /// existing pool, so the curve would be seeded against someone else's price.
    ///
    /// It fails closed. Every band is minted with zero desired on the quote side, so a band that needs quote
    /// is a zero-liquidity position, which the position manager rejects. The launch reverts and the
    /// creator's quote is never touched.
    function test_APoolOpenedBeforeTheLaunchMakesItRevertWithoutTouchingTheQuote() public {
        address predicted = _nextToken(creator, "Alpha", "ALPHA");

        (address token0, address token1) = predicted < HIGH_QUOTE ? (predicted, HIGH_QUOTE) : (HIGH_QUOTE, predicted);
        npm.createAndInitializePoolIfNecessary(token0, token1, address(0), TickMath.getSqrtRatioAtTick(0), "");

        uint256 buyAmount = 1e18;
        MockERC20(HIGH_QUOTE).mint(creator, buyAmount);
        vm.startPrank(creator);
        IERC20(HIGH_QUOTE).approve(address(launcher), buyAmount);
        vm.expectRevert(MockAlgebra.ZeroLiquidity.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: creator,
                buyAmount: buyAmount,
                feeUse: bytes32(0)
            })
        );
        vm.stopPrank();

        assertEq(IERC20(HIGH_QUOTE).balanceOf(creator), buyAmount, "the creator keeps their quote");
    }

    /// The launcher's nonce no longer predicts the next launch, so a pool opened there blocks nothing.
    function test_APoolOpenedAtTheNonceAddressDoesNotBlockALaunch() public {
        address byNonce = vm.computeCreateAddress(address(launcher), vm.getNonce(address(launcher)));
        (address token0, address token1) = byNonce < HIGH_QUOTE ? (byNonce, HIGH_QUOTE) : (HIGH_QUOTE, byNonce);
        npm.createAndInitializePoolIfNecessary(token0, token1, address(0), TickMath.getSqrtRatioAtTick(0), "");

        (address token,,) = _launch(HIGH_QUOTE);
        assertTrue(token != byNonce);
    }

    function _nextToken(address sender, string memory name, string memory symbol) internal returns (address) {
        vm.warp(vm.getBlockTimestamp() + 1);
        bytes memory initCode =
            abi.encodePacked(type(HydropumpToken).creationCode, abi.encode(name, symbol, launcher.SUPPLY()));
        bytes32 salt = keccak256(abi.encode(sender, vm.getBlockTimestamp()));
        return vm.computeCreate2Address(salt, keccak256(initCode), address(launcher));
    }

    /// `QuoteConsumed` cannot fire through the position manager — every mint passes zero on the quote side,
    /// so a band that wanted quote reverts as zero liquidity first. It is a backstop against a position
    /// manager that reports otherwise, and it has to work on both sides of the pair.
    function test_QuoteConsumedFiresOnEitherSideIfAMintEverReportsQuoteUsed() public {
        npm.setPhantomUsage(0, 1); // token1 side reports a wei used

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.QuoteConsumed.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: creator,
                buyAmount: 0,
                feeUse: bytes32(0)
            })
        );

        npm.setPhantomUsage(1, 0); // and the token0 side, for a mirrored launch
        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.QuoteConsumed.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: LOW_QUOTE,
                creatorRecipient: creator,
                buyAmount: 0,
                feeUse: bytes32(0)
            })
        );
    }

    /// The mirror image: a phantom on the launch token's own side is not quote, so it must not trip the
    /// guard. A guard that fired on either side would be checking the wrong thing.
    function test_QuoteConsumedIgnoresUsageOnTheLaunchTokensOwnSide() public {
        npm.setPhantomUsage(1, 0); // token0 is the launch token here
        (address token,,) = _launch(HIGH_QUOTE);
        assertTrue(token < HIGH_QUOTE);

        npm.setPhantomUsage(0, 1); // and token1 is, here
        (address mirrored,,) = _launch(LOW_QUOTE);
        assertTrue(mirrored > LOW_QUOTE);
    }

    // ---------------------------------------------------------------- spacing

    /// The curve is expressed in offsets and aligned to whatever spacing the pool reports, so it has to hold
    /// at every spacing Algebra might hand back — not just the 200 the live pools use today.
    function test_BandsAlignAndStayPureAcrossTickSpacings() public {
        int24[5] memory spacings = [int24(1), int24(10), int24(60), int24(200), int24(2_000)];

        for (uint256 i = 0; i < spacings.length; i++) {
            npm.setTickSpacing(spacings[i]);

            (address token, address pool, uint256[] memory ids) = _launch(HIGH_QUOTE);
            assertEq(MockAlgebraPool(pool).tickSpacing(), spacings[i]);
            _assertCurveShape(token, HIGH_QUOTE, pool, ids);

            (address mirrored, address mirroredPool, uint256[] memory mirroredIds) = _launch(LOW_QUOTE);
            _assertCurveShape(mirrored, LOW_QUOTE, mirroredPool, mirroredIds);

            console2.log("spacing ok", int256(spacings[i]));
        }
    }

    // ---------------------------------------------------------------- the dev buy

    function test_TheDevBuyFillsAndMovesThePriceUpOnBothSides() public {
        uint256 buyAmount = 1e18;

        (address token, address pool,) = _launch(HIGH_QUOTE, bytes32(0), buyAmount);
        assertGt(IERC20(token).balanceOf(creator), 0, "buyer receives tokens");
        assertEq(IERC20(HIGH_QUOTE).balanceOf(creator), 0, "full amount spent");
        assertEq(IERC20(HIGH_QUOTE).balanceOf(address(launcher)), 0, "no quote stranded in the launcher");
        assertGt(_currentTick(pool), WETH_START_TICK, "buying token0 raises token1/token0");

        (address mirrored, address mirroredPool,) = _launch(LOW_QUOTE, bytes32(0), buyAmount);
        assertGt(IERC20(mirrored).balanceOf(creator), 0);
        assertEq(IERC20(LOW_QUOTE).balanceOf(creator), 0);
        assertEq(IERC20(LOW_QUOTE).balanceOf(address(launcher)), 0);
        assertLt(_currentTick(mirroredPool), -WETH_START_TICK, "buying token1 lowers it");

        // Opposite tick directions, same thing happening: the launch token got more expensive in quote terms.
        assertGt(_priceE18(pool, token, HIGH_QUOTE), _priceE18(mirroredPool, mirrored, LOW_QUOTE) / 2);
    }

    function test_ZeroBuyAmountSkipsTheSwapOnBothSides() public {
        (, address pool,) = _launch(HIGH_QUOTE);
        assertEq(_currentTick(pool), WETH_START_TICK);

        (, address mirroredPool,) = _launch(LOW_QUOTE);
        assertEq(_currentTick(mirroredPool), -WETH_START_TICK);
    }

    // ---------------------------------------------------------------- the real list

    /// Every start tick the generator emits, launched both ways. The generator only ever computed one
    /// number per quote — the token0-side reading — so this is what proves its output is still complete now
    /// that half of all launches will use the mirror of it.
    function test_EveryGeneratedStartTickWorksOnBothSides() public {
        int256[] memory startTicks = vm.parseJsonIntArray(vm.readFile("script/quotes/quote-tokens.json"), ".startTicks");
        assertGt(startTicks.length, 20, "sanity: the generated list should not be nearly empty");

        for (uint256 i = 0; i < startTicks.length; i++) {
            int24 startTick = int24(startTicks[i]);

            vm.startPrank(owner);
            int24[] memory ticks = new int24[](1);
            ticks[0] = startTick;
            address[] memory one = new address[](1);
            one[0] = HIGH_QUOTE;
            directory.setStartTicks(one, ticks);
            one[0] = LOW_QUOTE;
            directory.setStartTicks(one, ticks);
            vm.stopPrank();

            (address token, address pool, uint256[] memory ids) = _launch(HIGH_QUOTE);
            assertEq(_currentTick(pool), startTick);
            _assertCurveShape(token, HIGH_QUOTE, pool, ids);

            (address mirrored, address mirroredPool, uint256[] memory mirroredIds) = _launch(LOW_QUOTE);
            assertEq(_currentTick(mirroredPool), -startTick);
            _assertCurveShape(mirrored, LOW_QUOTE, mirroredPool, mirroredIds);
        }

        console2.log("start ticks exercised on both sides:", startTicks.length);
    }

    // ---------------------------------------------------------------- edges

    /// A start tick so close to the usable edge that the tail has nowhere to go. Accepted at configuration
    /// time, because how far a band can actually reach depends on the pool's spacing, and caught at launch.
    function test_AStartTickAtTheVeryEdgeCollapsesABandAndReverts() public {
        _registerQuote(HIGH_QUOTE, TickMath.MAX_TICK);

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.BandOutOfRange.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: creator,
                buyAmount: 0,
                feeUse: bytes32(0)
            })
        );
    }

    /// The mirrored tail is the band that can run off the bottom of the range, and it clamps rather than
    /// collapsing. Reaching that needs a small positive start tick — the mirror of a launch token worth
    /// slightly more than one raw quote unit — which is the far end of what the registry accepts.
    function test_TheMirroredTailClampsToTheLowestUsableTick() public {
        _registerQuote(LOW_QUOTE, 72);

        (address token, address pool, uint256[] memory ids) = _launch(LOW_QUOTE);
        _assertCurveShape(token, LOW_QUOTE, pool, ids);

        Band[] memory bands = _bands(ids);
        assertEq(bands[4].lower, -887_200, "the tail clamps to the lowest usable tick");
        assertLt(bands[4].lower, bands[4].upper, "and still leaves a real range");
    }

    /// And at the very top of the tick range a launch is impossible either way round: the token0 tail runs
    /// off the top, and the mirrored base is already below the bottom. Better a named revert than a
    /// zero-liquidity failure from inside the position manager.
    function test_AStartTickAtTheVeryEdgeCollapsesABandOnBothSides() public {
        _registerQuote(LOW_QUOTE, TickMath.MAX_TICK);

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.BandOutOfRange.selector);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: LOW_QUOTE,
                creatorRecipient: creator,
                buyAmount: 0,
                feeUse: bytes32(0)
            })
        );
    }

    function test_LaunchRegistersWithTheLockerOnBothSides() public {
        (address token, address pool, uint256[] memory ids) = _launch(HIGH_QUOTE);
        HydropumpLocker.Launch memory launch = locker.getLaunch(token);
        assertEq(launch.pool, pool);
        assertEq(launch.quoteToken, HIGH_QUOTE);
        assertEq(launch.positionIds.length, ids.length);

        (address mirrored, address mirroredPool, uint256[] memory mirroredIds) = _launch(LOW_QUOTE);
        HydropumpLocker.Launch memory mirroredLaunch = locker.getLaunch(mirrored);
        assertEq(mirroredLaunch.pool, mirroredPool);
        assertEq(mirroredLaunch.quoteToken, LOW_QUOTE);
        assertEq(mirroredLaunch.positionIds.length, mirroredIds.length);
    }

    // ---------------------------------------------------------------- fuzz

    /// The invariant the mirroring exists to preserve, over the whole configurable tick range and every
    /// plausible spacing: no band ever straddles the opening price, so no band ever needs quote.
    function testFuzz_NoBandStraddlesTheOpeningPrice(int24 startTick, uint8 spacingPick, bool mirror) public {
        startTick = int24(bound(startTick, TickMath.MIN_TICK, 72));
        int24[5] memory spacings = [int24(1), int24(10), int24(60), int24(200), int24(2_000)];
        npm.setTickSpacing(spacings[spacingPick % 5]);

        address quoteToken = mirror ? LOW_QUOTE : HIGH_QUOTE;
        _registerQuote(quoteToken, startTick);

        (address token, address pool, uint256[] memory ids) = _launch(quoteToken);

        assertEq(_currentTick(pool), mirror ? -startTick : startTick);
        _assertCurveShape(token, quoteToken, pool, ids);
        assertEq(IERC20(quoteToken).balanceOf(pool), 0, "not a wei of quote entered the pool");
        assertEq(IERC20(token).balanceOf(pool), launcher.SUPPLY(), "and the whole supply did");
    }

    /// Band 0 opens flush against the price. Rounding the base the wrong way would put it one spacing on the
    /// wrong side, which is the mistake that silently turns the first band into a two-sided position.
    function testFuzz_BandZeroSitsFlushAgainstThePrice(int24 startTick, uint8 spacingPick, bool mirror) public {
        startTick = int24(bound(startTick, TickMath.MIN_TICK, 72));
        int24[5] memory spacings = [int24(1), int24(10), int24(60), int24(200), int24(2_000)];
        int24 spacing = spacings[spacingPick % 5];
        npm.setTickSpacing(spacing);

        address quoteToken = mirror ? LOW_QUOTE : HIGH_QUOTE;
        _registerQuote(quoteToken, startTick);
        (,, uint256[] memory ids) = _launch(quoteToken);

        int24 openingTick = mirror ? -startTick : startTick;
        (int24 lower, int24 upper) = npm.range(ids[0]);
        int24 edge = mirror ? upper : lower;

        // Within one spacing of the price, and on the launch token's side of it.
        assertLe(_abs(edge - openingTick), spacing, "band 0 must open flush against the price");
        if (mirror) assertLe(edge, openingTick);
        else assertGe(edge, openingTick);
    }

    function _abs(int24 value) internal pure returns (int24) {
        return value < 0 ? -value : value;
    }
}
