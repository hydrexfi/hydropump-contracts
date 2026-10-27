// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpLocker} from "../contracts/core/HydropumpLocker.sol";
import {HydropumpRotator} from "../contracts/core/HydropumpRotator.sol";
import {PairDirectory} from "../contracts/helpers/PairDirectory.sol";
import {ISwapRouter} from "../contracts/interfaces/ISwapRouter.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebra.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Retiring a dead launch: the locker's release, the rotator's eligibility, the buy and redemption.
/// @dev Written against launches on the token0 side; `HydropumpRotatorMirroredTest` re-runs it on token1.
contract HydropumpRotatorTest is HydropumpFixture {
    /// @dev ln(4) / ln(1.0001): the tick distance that quadruples a price, i.e. $20k on a $5k open.
    int24 internal constant CAP_TICKS = 13_863;

    HydropumpRotator internal rotator;
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// @dev Launched before the rotator existed, so it must stay locked for good.
    address internal legacy;

    function _quote() internal view virtual returns (address) {
        return HIGH_QUOTE;
    }

    function setUp() public override {
        super.setUp();
        (legacy,,) = _launch(_quote());

        rotator = new HydropumpRotator(owner, operator, address(locker));
        vm.prank(owner);
        locker.setRotator(address(rotator));
    }

    // ---------------------------------------------------------------- helpers

    /// @dev A launch past its tax window, so ordinary buys are not taxed.
    function _launchLive() internal returns (address token, address pool) {
        (token, pool,) = _launch(_quote());
        vm.roll(vm.getBlockNumber() + 10);
    }

    function _setTarget(address target) internal {
        address[] memory quotes = new address[](1);
        address[] memory targets = new address[](1);
        (quotes[0], targets[0]) = (_quote(), target);
        vm.prank(operator);
        rotator.setTargets(quotes, targets);
    }

    function _buy(address who, address token, uint256 quoteIn) internal returns (uint256 out) {
        MockERC20(_quote()).mint(who, quoteIn);
        vm.startPrank(who);
        IERC20(_quote()).approve(ROUTER, quoteIn);
        out = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: _quote(),
                tokenOut: token,
                deployer: address(0),
                recipient: who,
                deadline: block.timestamp,
                amountIn: quoteIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    /// @dev Makes the bands' principal add up to what the pool holds, as real liquidity would after trades.
    ///      The mock router fills out of the pool's balance without touching any band, so this puts the
    ///      difference on band 0.
    function _syncPrincipal(address token) internal {
        address pool = locker.poolOf(token);
        uint256[] memory ids = locker.getPositions(token);
        bool isToken0 = token < _quote();

        uint256 otherTokens;
        for (uint256 i = 1; i < ids.length; i++) {
            (uint256 principal0, uint256 principal1) = npm.principalOf(ids[i]);
            otherTokens += isToken0 ? principal0 : principal1;
        }
        uint256 band0Tokens = IERC20(token).balanceOf(pool) - otherTokens;
        uint256 band0Quote = IERC20(_quote()).balanceOf(pool);
        if (isToken0) npm.setPrincipal(ids[0], band0Tokens, band0Quote);
        else npm.setPrincipal(ids[0], band0Quote, band0Tokens);
    }

    /// @dev A dead launch two holders bought into, a live target, and seven days gone by.
    function _deadWithHolders() internal returns (address dead, address target) {
        (dead,) = _launchLive();
        _buy(alice, dead, 0.01e18);
        _buy(bob, dead, 0.03e18);
        _syncPrincipal(dead);

        (target,) = _launchLive();
        _setTarget(target);
        vm.warp(vm.getBlockTimestamp() + 7 days);
    }

    function _setSpotOffset(address token, int24 ticksAboveOpen) internal {
        int24 open = directory.poolStartTick(token, _quote());
        _setSpot(locker.poolOf(token), open + _launchPriceOffset(token, ticksAboveOpen));
    }

    // ---------------------------------------------------------------- locker

    function test_OnlyRotatorReleases() public {
        (address token,) = _launchLive();
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotRotator.selector);
        locker.releaseLiquidity(token);
    }

    function test_LaunchesBeforeTheRotatorAreNeverReleased() public {
        vm.prank(address(rotator));
        vm.expectRevert(HydropumpLocker.NotRotatable.selector);
        locker.releaseLiquidity(legacy);

        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(HydropumpRotator.PredatesRotation.selector);
        rotator.checkRotatable(legacy);
    }

    function test_ARotatorChangeKeepsTheOriginalStart() public {
        uint64 start = locker.rotationStart();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(owner);
        locker.setRotator(makeAddr("next"));
        assertEq(locker.rotationStart(), start);

        vm.prank(stranger);
        vm.expectRevert();
        locker.setRotator(stranger);
    }

    function test_ReleaseSplitsFeesFirstAndPaysTheCreatorOut() public {
        (address token,) = _launchLive();
        _buy(alice, token, 0.01e18);
        _accrueFees(token, 4e18, 8e18);
        _syncPrincipal(token);
        uint256 poolTokens = IERC20(token).balanceOf(locker.poolOf(token));
        uint256 poolQuote = IERC20(_quote()).balanceOf(locker.poolOf(token));
        uint256 protocolQuoteBefore = locker.protocolOwed(_quote());

        vm.prank(address(rotator));
        (uint256 launchTokenAmount, uint256 quoteAmount) = locker.releaseLiquidity(token);

        // Principal plus the protocol's launch-token fee share, which has nowhere left to sell.
        assertEq(launchTokenAmount, poolTokens + 1e18, "principal and protocol token share");
        assertEq(quoteAmount, poolQuote, "principal only");
        assertEq(IERC20(token).balanceOf(address(rotator)), launchTokenAmount);
        assertEq(IERC20(_quote()).balanceOf(address(rotator)), quoteAmount);

        assertEq(IERC20(token).balanceOf(creator), 3e18, "creator's token share paid out");
        assertEq(IERC20(_quote()).balanceOf(creator), 6e18, "creator's quote share paid out");
        assertEq(locker.creatorOwed(token, token), 0);
        assertEq(locker.creatorOwed(token, _quote()), 0);
        assertEq(locker.protocolOwed(token), 0);
        assertEq(locker.protocolOwed(_quote()), protocolQuoteBefore + 2e18, "protocol quote share stays booked");

        uint256[] memory ids = locker.getPositions(token);
        for (uint256 i = 0; i < ids.length; i++) {
            assertEq(npm.liquidityOf(ids[i]), 0, "every band emptied");
            assertEq(npm.ownerOf(ids[i]), address(locker), "positions stay in the locker");
        }
        assertTrue(locker.released(token));
    }

    /// A recipient the quote refuses (a blocklisted address, say) must not block rotation. The share stays
    /// booked, where the creator can still reach it after moving the recipient.
    function test_AnUnpayableCreatorDoesNotBlockRelease() public {
        (address token,) = _launchLive();
        _accrueFees(token, 0, 8e18);
        vm.mockCallRevert(_quote(), abi.encodeWithSelector(IERC20.transfer.selector, creator), "blocked");

        vm.prank(address(rotator));
        locker.releaseLiquidity(token);
        assertTrue(locker.released(token));
        assertEq(locker.creatorOwed(token, _quote()), 6e18, "left booked");
    }

    function test_CannotReleaseTwice() public {
        (address token,) = _launchLive();
        vm.startPrank(address(rotator));
        locker.releaseLiquidity(token);
        vm.expectRevert(HydropumpLocker.AlreadyReleased.selector);
        locker.releaseLiquidity(token);
        vm.stopPrank();
    }

    /// The fee paths every launch goes through keep working on a released one, and on the legacy one.
    function test_FeeCallsStillWorkAfterRelease() public {
        (address token,) = _launchLive();
        vm.prank(address(rotator));
        locker.releaseLiquidity(token);

        locker.splitRewards(token);
        locker.handleAllRewards(token);
        locker.handleCreatorRewards(token);

        _accrueFees(legacy, 4e18, 8e18);
        locker.handleCreatorRewards(legacy);
        assertEq(IERC20(_quote()).balanceOf(creator), 6e18);
    }

    // ---------------------------------------------------------------- eligibility

    function test_LaunchSupplyMatchesTheLauncher() public view {
        assertEq(rotator.LAUNCH_SUPPLY(), launcher.SUPPLY());
    }

    function test_NotRotatableBeforeSevenDays() public {
        (address token,) = _launchLive();
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(HydropumpRotator.TooYoung.selector);
        rotator.checkRotatable(token);

        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(rotator.isRotatable(token));
    }

    function test_ValuationCapIsFourTimesTheOpen() public {
        (address token,) = _launchLive();
        vm.warp(vm.getBlockTimestamp() + 7 days);

        _setSpotOffset(token, CAP_TICKS - 10);
        assertTrue(rotator.isRotatable(token), "just under $20k");

        _setSpotOffset(token, CAP_TICKS + 10);
        vm.expectRevert(HydropumpRotator.ValuationTooHigh.selector);
        rotator.checkRotatable(token);
    }

    /// The open is today's start tick, so a quote that has doubled in USD halves the price a launch needs.
    function test_CapFollowsTheDirectorysCurrentPrice() public {
        (address token,) = _launchLive();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _setSpotOffset(token, CAP_TICKS - 3_000);
        assertTrue(rotator.isRotatable(token));

        // The quote's USD price doubles: $5k now takes 6,932 fewer ticks of it.
        _registerQuote(_quote(), WETH_START_TICK - 6_932);
        vm.expectRevert(HydropumpRotator.ValuationTooHigh.selector);
        rotator.checkRotatable(token);
    }

    function test_AnHourAboveTheCapInTheLastDayBlocksRotation() public {
        (address token, address pool) = _launchLive();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        int24 above = directory.poolStartTick(token, _quote()) + _launchPriceOffset(token, CAP_TICKS + 500);

        MockAlgebraPool(pool).setSpike(above, 10 hours, 9 hours);
        vm.expectRevert(HydropumpRotator.ValuationTooHigh.selector);
        rotator.checkRotatable(token);

        // The same hour, a day and more ago, no longer counts.
        MockAlgebraPool(pool).setSpike(above, 26 hours, 25 hours);
        assertTrue(rotator.isRotatable(token));
    }

    /// Market cap, not price: burnt supply counts. 5x the open on 70% of the supply is a 3.5x valuation.
    function test_CapIsOnMarketCapNotPrice() public {
        (address token, address pool) = _launchLive();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        _setSpotOffset(token, 16_095); // 5x

        vm.expectRevert(HydropumpRotator.ValuationTooHigh.selector);
        rotator.checkRotatable(token);

        deal(token, pool, IERC20(token).balanceOf(pool) - 3_000_000_000e18, true);
        assertTrue(rotator.isRotatable(token));
    }

    function test_DisabledQuoteIsNotRotatable() public {
        (address token,) = _launchLive();
        vm.warp(vm.getBlockTimestamp() + 7 days);

        address[] memory tokens = new address[](1);
        bool[] memory enabled = new bool[](1);
        int24[] memory ticks = new int24[](1);
        (tokens[0], enabled[0], ticks[0]) = (_quote(), false, WETH_START_TICK);
        vm.prank(owner);
        directory.configureQuoteTokens(tokens, enabled, ticks);

        vm.expectRevert(PairDirectory.QuoteTokenNotEnabled.selector);
        rotator.checkRotatable(token);
    }

    // ---------------------------------------------------------------- targets

    function test_OnlyOperatorSetsTargets() public {
        (address target,) = _launchLive();
        address[] memory quotes = new address[](1);
        address[] memory targets = new address[](1);
        (quotes[0], targets[0]) = (_quote(), target);

        vm.prank(stranger);
        vm.expectRevert(HydropumpRotator.NotOperator.selector);
        rotator.setTargets(quotes, targets);
    }

    function test_TargetMustShareTheQuote() public {
        address otherQuote = _quote() == HIGH_QUOTE ? LOW_QUOTE : HIGH_QUOTE;
        (address target,,) = _launch(otherQuote);

        vm.expectRevert(HydropumpRotator.InvalidTarget.selector);
        _setTarget(target);
    }

    function test_NoRotationWithoutATarget() public {
        (address dead,) = _launchLive();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(HydropumpRotator.NoTarget.selector);
        rotator.rotate(dead);
    }

    function test_TargetInItsTaxWindowIsRefused() public {
        (address dead,) = _launchLive();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (address target,,) = _launch(_quote());
        _setTarget(target);

        vm.expectRevert(HydropumpRotator.InvalidTarget.selector);
        rotator.rotate(dead);
    }

    // ---------------------------------------------------------------- rotate and redeem

    function test_RotateBurnsUnsoldSupplyAndBuysTheTarget() public {
        (address dead, address target) = _deadWithHolders();
        uint256 held = IERC20(dead).balanceOf(alice) + IERC20(dead).balanceOf(bob);
        uint256 poolQuote = IERC20(_quote()).balanceOf(locker.poolOf(dead));

        vm.prank(stranger);
        (uint256 quoteSpent, uint256 bought) = rotator.rotate(dead);

        assertEq(IERC20(dead).totalSupply(), held, "only what holders bought is left");
        assertEq(IERC20(dead).balanceOf(locker.poolOf(dead)), 0, "pool emptied");
        assertEq(quoteSpent, poolQuote, "every wei of quote spent on the target");
        assertGt(bought, 0);

        (address storedTarget, uint256 targetHeld) = rotator.rotations(dead);
        assertEq(storedTarget, target);
        assertEq(targetHeld, bought);
        assertEq(IERC20(target).balanceOf(address(rotator)), bought);
        assertEq(IERC20(_quote()).balanceOf(address(rotator)), 0, "no quote left behind");
        assertEq(IERC20(_quote()).balanceOf(stranger), 0, "no bounty");

        vm.expectRevert(HydropumpRotator.AlreadyRotated.selector);
        rotator.rotate(dead);
    }

    /// One buy spends it all, even one that moves the target about 22%, inside the 25% cap.
    function test_ABuyWithinTheCapSpendsAllTheQuoteInOneGo() public {
        (address dead,) = _deadWithHolders();
        uint256 poolQuote = IERC20(_quote()).balanceOf(locker.poolOf(dead));
        router.configure(3_000, 2_000);

        (uint256 quoteSpent, uint256 bought) = rotator.rotate(dead);
        assertEq(quoteSpent, poolQuote, "all of it, in one buy");
        assertGt(bought, 0);
    }

    function test_RedemptionIsProRataWhateverTheOrder() public {
        (address dead, address target) = _deadWithHolders();
        rotator.rotate(dead);
        (, uint256 targetHeld) = rotator.rotations(dead);

        uint256 aliceHeld = IERC20(dead).balanceOf(alice);
        uint256 bobHeld = IERC20(dead).balanceOf(bob);
        uint256 supply = IERC20(dead).totalSupply();

        vm.startPrank(bob);
        IERC20(dead).approve(address(rotator), bobHeld);
        uint256 bobOut = rotator.redeem(dead, bobHeld);
        vm.stopPrank();

        vm.startPrank(alice);
        IERC20(dead).approve(address(rotator), aliceHeld);
        uint256 aliceOut = rotator.redeem(dead, aliceHeld);
        vm.stopPrank();

        assertEq(bobOut, targetHeld * bobHeld / supply);
        assertApproxEqAbs(aliceOut, targetHeld * aliceHeld / supply, 1, "second redeemer loses nothing to the first");
        assertEq(IERC20(target).balanceOf(alice), aliceOut);
        assertEq(IERC20(dead).totalSupply(), 0, "redeeming burns");
        assertLe(IERC20(target).balanceOf(address(rotator)), 1, "nothing left but rounding");
    }

    function test_RedeemNeedsARotation() public {
        (address token,) = _launchLive();
        vm.expectRevert(HydropumpRotator.NotRotated.selector);
        rotator.redeem(token, 1);
    }

    function test_RedeemNeedsAnAllowance() public {
        (address dead,) = _deadWithHolders();
        rotator.rotate(dead);
        vm.prank(alice);
        vm.expectRevert();
        rotator.redeem(dead, 1);
    }

    /// A buy that would have to run past 25% over the target's average reverts the whole rotation, so
    /// nothing is released and the launch can be rotated later.
    function test_ABuyPastTheCapRevertsTheWholeRotation() public {
        (address dead,) = _deadWithHolders();
        router.configure(3_000, 3_000); // the one buy would need 3,000 ticks; the cap is 2,231

        vm.expectRevert(HydropumpRotator.SlippageTooHigh.selector);
        rotator.rotate(dead);
        assertFalse(locker.released(dead), "nothing released");
        assertTrue(rotator.isRotatable(dead), "still waiting to rotate");
    }

    /// A target pumped just before the rotation starts the buy past its last-hour average. Pumped past
    /// the cap, the rotation waits; back near the average, it goes through.
    function test_TargetPumpedPastTheCapIsNotBought() public {
        (address dead, address target) = _deadWithHolders();
        address targetPool = locker.poolOf(target);
        int24 fair = _currentTick(targetPool);
        _setSpot(targetPool, fair + _launchPriceOffset(target, 5_000));
        MockAlgebraPool(targetPool).setSpike(fair, 1 hours, 0);

        vm.expectRevert(HydropumpRotator.SlippageTooHigh.selector);
        rotator.rotate(dead);

        _setSpot(targetPool, fair);
        (uint256 spent,) = rotator.rotate(dead);
        assertGt(spent, 0);
    }

    /// A target rotated away since it was set has no pool left to buy from.
    function test_ARotatedTargetIsRefused() public {
        (address dead, address target) = _deadWithHolders();
        vm.prank(address(rotator));
        locker.releaseLiquidity(target);

        vm.expectRevert(HydropumpRotator.InvalidTarget.selector);
        rotator.rotate(dead);
    }
}

/// @notice The same cases with every launch on the token1 side of its pool.
contract HydropumpRotatorMirroredTest is HydropumpRotatorTest {
    function _quote() internal pure override returns (address) {
        return LOW_QUOTE;
    }

    function test_SuiteRunsMirrored() public {
        (address token,) = _launchLive();
        assertFalse(locker.launchIsToken0(token));
    }
}
