// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {HydropumpRotator} from "../../contracts/core/HydropumpRotator.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";

/// @notice Rotation against live Hydrex: real liquidity coming out, the real oracle deciding eligibility,
///         and the real router buying the target.
contract RotationForkTest is ForkFixture {
    /// @dev ln(4) / ln(1.0001): the ticks that quadruple a price, $20k on a $5k open.
    int24 internal constant CAP_TICKS = 13_863;

    /// @dev The production locker and one launch it held before rotation existed.
    HydropumpLocker internal constant LIVE_LOCKER = HydropumpLocker(0x9c11834644C91A73AA959b01Bb7F1E148AF40D43);
    address internal constant LIVE_LAUNCH = 0x156CEAfAbE9aE050Debee750cCF9C580f68b4906;

    HydropumpRotator internal rotator;
    address internal operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        rotator = new HydropumpRotator(owner, operator, address(locker));
        vm.prank(owner);
        locker.setRotator(address(rotator));
    }

    // ---------------------------------------------------------------- helpers

    function _setTarget(address target) internal {
        address[] memory quotes = new address[](1);
        address[] memory targets = new address[](1);
        (quotes[0], targets[0]) = (WETH, target);
        vm.prank(operator);
        rotator.setTargets(quotes, targets);
    }

    /// @dev Ticks the launch token's price sits above today's open, whichever side of the pair it is on.
    function _ticksAboveOpen(address token, address pool) internal view returns (int24) {
        int24 fromOpen = _currentTick(pool) - directory.poolStartTick(token, WETH);
        return token < WETH ? fromOpen : -fromOpen;
    }

    function _nextBlock(uint256 seconds_) internal {
        vm.roll(vm.getBlockNumber() + seconds_ / 2);
        vm.warp(vm.getBlockTimestamp() + seconds_);
    }

    function _redeemAll(address who, address dead) internal returns (uint256 targetOut, uint256 quoteOut) {
        uint256 held = IERC20(dead).balanceOf(who);
        vm.startPrank(who);
        IERC20(dead).approve(address(rotator), held);
        (targetOut, quoteOut) = rotator.redeem(dead, held);
        vm.stopPrank();
    }

    function _rotateDeadLaunch(bool deadIsToken0) internal {
        (address dead, address deadPool, uint256[] memory ids,) = _launchOnSide(WETH, deadIsToken0, bytes32(0));
        _passLaunchWindow();
        _swapIn(alice, WETH, dead, 0.02 ether);
        _swapIn(bob, WETH, dead, 0.06 ether);

        (address target,,,) = _launchOnSide(WETH, !deadIsToken0, bytes32(0));
        _passLaunchWindow();
        _swapIn(poker, WETH, target, 0.05 ether);
        _setTarget(target);

        _nextBlock(7 days);
        assertTrue(rotator.isRotatable(dead), "a week old and never above $20k");

        uint256 poolWeth = IERC20(WETH).balanceOf(deadPool);
        vm.prank(makeAddr("anyone"));
        rotator.rotate(dead);

        for (uint256 i = 0; i < ids.length; i++) {
            (,,,,,,, uint128 liquidity,,,,) = NPM.positions(ids[i]);
            assertEq(liquidity, 0, "every band emptied");
        }
        // What stays is rounding and the pool's community fee, which no position owns.
        assertLt(IERC20(dead).balanceOf(deadPool), 1e9, "unsold supply out of the pool");
        assertLt(IERC20(WETH).balanceOf(deadPool), poolWeth / 1_000, "and the quote with it");

        // Each buy stops 5% past the target's last-hour average. With nobody selling in between, the rest
        // fills as that average catches up, an hour at a time.
        (,,, uint256 quoteHeld) = rotator.rotations(dead);
        uint256 hoursTaken;
        for (; hoursTaken < 72 && quoteHeld > 0; hoursTaken++) {
            _nextBlock(1 hours);
            rotator.buy(dead);
            (,,, quoteHeld) = rotator.rotations(dead);
        }
        console2.log("hours to spend the quote", hoursTaken);
        (,, uint256 targetHeld, uint256 quoteLeft) = rotator.rotations(dead);
        assertEq(quoteLeft, 0, "every wei of quote eventually spent");
        assertGt(targetHeld, 0);

        // Pro rata by tokens held, not quote paid: bob bought later and higher, as a sale into the curve
        // would also have priced him.
        uint256 supply = IERC20(dead).totalSupply();
        uint256 aliceShare = IERC20(dead).balanceOf(alice);
        uint256 bobShare = IERC20(dead).balanceOf(bob);
        (uint256 aliceOut,) = _redeemAll(alice, dead);
        assertEq(aliceOut, targetHeld * aliceShare / supply, "pro rata");
        assertEq(IERC20(target).balanceOf(alice), aliceOut);

        (uint256 bobOut,) = _redeemAll(bob, dead);
        assertApproxEqAbs(bobOut, targetHeld * bobShare / supply, 1, "the second redeemer is not diluted");
        assertLt(poolWeth, 0.08 ether, "pool held what they paid, less fees");
    }

    // ---------------------------------------------------------------- tests

    function test_RotatesADeadToken0LaunchIntoTheTarget() public onlyForked {
        _rotateDeadLaunch(true);
    }

    function test_RotatesADeadToken1LaunchIntoTheTarget() public onlyForked {
        _rotateDeadLaunch(false);
    }

    /// A launch that held above $20k inside the last day is not dead, wherever spot is when rotate is called.
    function _aboveTheCapInTheLastDayBlocksRotation(bool deadIsToken0) internal {
        (address dead, address pool,,) = _launchOnSide(WETH, deadIsToken0, bytes32(0));
        _passLaunchWindow();
        _nextBlock(7 days);

        uint256 bought;
        for (uint256 i = 0; i < 100 && _ticksAboveOpen(dead, pool) < CAP_TICKS + 1_000; i++) {
            bought += _swapIn(alice, WETH, dead, 0.1 ether);
        }
        assertGe(_ticksAboveOpen(dead, pool), CAP_TICKS + 1_000, "pumped past $20k");
        _nextBlock(3 hours);

        // Dumped back under the cap; the hours above it still count.
        _sell(alice, dead, WETH, bought);
        assertLt(_ticksAboveOpen(dead, pool), CAP_TICKS);
        _nextBlock(1 hours);
        vm.expectRevert(HydropumpRotator.ValuationTooHigh.selector);
        rotator.checkRotatable(dead);

        _nextBlock(24 hours);
        assertTrue(rotator.isRotatable(dead), "a full day under the cap");
    }

    function test_AToken0LaunchAboveTheCapInTheLastDayIsNotRotatable() public onlyForked {
        _aboveTheCapInTheLastDayBlocksRotation(true);
    }

    function test_AToken1LaunchAboveTheCapInTheLastDayIsNotRotatable() public onlyForked {
        _aboveTheCapInTheLastDayBlocksRotation(false);
    }

    /// A target pumped at the end of one block opens the next one high. The buy holds to the target's
    /// last-hour average instead, so nothing is spent until the price comes back.
    function test_ATargetPumpedInTheBlockBeforeIsNotBoughtHigh() public onlyForked {
        (address dead,,,) = _launchOnSide(WETH, true, bytes32(0));
        _passLaunchWindow();
        _swapIn(alice, WETH, dead, 0.05 ether);

        (address target, address targetPool,,) = _launchOnSide(WETH, false, bytes32(0));
        _passLaunchWindow();
        _setTarget(target);
        _nextBlock(7 days);

        int24 fair = _currentTick(targetPool);
        uint256 pumped = _swapIn(bob, WETH, target, 0.5 ether);
        int24 moved = _currentTick(targetPool) - fair;
        assertGt(moved < 0 ? -moved : moved, 1_000, "pumped well past the 5% buffer");
        _nextBlock(2);

        (uint256 spent,) = rotator.rotate(dead);
        assertEq(spent, 0, "nothing bought at the pumped open");

        _sell(bob, target, WETH, pumped);
        _nextBlock(2);
        (spent,) = rotator.buy(dead);
        assertGt(spent, 0, "bought once the price is back");
    }

    /// The production locker upgraded to this code: what it holds is unchanged, its launches keep paying
    /// fees, and none of them can be released.
    function test_UpgradingTheLiveLockerLeavesExistingLaunchesLocked() public onlyForked {
        HydropumpLocker.Launch memory before = LIVE_LOCKER.getLaunch(LIVE_LAUNCH);
        require(before.pool != address(0), "fixture: live launch missing");
        (uint128 feesToken, uint128 feesQuote) = LIVE_LOCKER.lifetimeFees(LIVE_LAUNCH);
        uint256 creatorOwedQuote = LIVE_LOCKER.creatorOwed(LIVE_LAUNCH, before.quoteToken);
        address launcherBefore = LIVE_LOCKER.launcher();
        address registryBefore = LIVE_LOCKER.feeUseRegistry();
        (uint64 creatorFee, uint64 protocolFee) = (LIVE_LOCKER.creatorFee(), LIVE_LOCKER.protocolFee());

        address liveOwner = LIVE_LOCKER.owner();
        address implementation = address(new HydropumpLocker());
        vm.prank(liveOwner);
        LIVE_LOCKER.upgradeToAndCall(implementation, "");

        HydropumpLocker.Launch memory afterUpgrade = LIVE_LOCKER.getLaunch(LIVE_LAUNCH);
        assertEq(abi.encode(afterUpgrade), abi.encode(before), "launch record unchanged");
        (uint128 feesTokenAfter, uint128 feesQuoteAfter) = LIVE_LOCKER.lifetimeFees(LIVE_LAUNCH);
        assertEq(feesTokenAfter, feesToken);
        assertEq(feesQuoteAfter, feesQuote);
        assertEq(LIVE_LOCKER.creatorOwed(LIVE_LAUNCH, before.quoteToken), creatorOwedQuote);
        assertEq(LIVE_LOCKER.launcher(), launcherBefore);
        assertEq(LIVE_LOCKER.feeUseRegistry(), registryBefore);
        assertEq(LIVE_LOCKER.creatorFee(), creatorFee);
        assertEq(LIVE_LOCKER.protocolFee(), protocolFee);
        assertEq(LIVE_LOCKER.rotator(), address(0));
        assertEq(LIVE_LOCKER.rotationStart(), 0);

        LIVE_LOCKER.splitRewards(LIVE_LAUNCH);

        HydropumpRotator liveRotator = new HydropumpRotator(liveOwner, operator, address(LIVE_LOCKER));
        vm.prank(liveOwner);
        LIVE_LOCKER.setRotator(address(liveRotator));

        _nextBlock(365 days);
        vm.expectRevert(HydropumpRotator.PredatesRotation.selector);
        liveRotator.checkRotatable(LIVE_LAUNCH);

        vm.prank(address(liveRotator));
        vm.expectRevert(HydropumpLocker.NotRotatable.selector);
        LIVE_LOCKER.releaseLiquidity(LIVE_LAUNCH);
    }
}
