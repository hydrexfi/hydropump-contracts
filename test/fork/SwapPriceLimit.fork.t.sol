// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {SwapPriceLimit} from "../../contracts/libraries/SwapPriceLimit.sol";
import {TickMath} from "../../contracts/libraries/TickMath.sol";
import {IAlgebraPlugin} from "../../contracts/interfaces/IAlgebraPlugin.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";

/// @notice `SwapPriceLimit` against live Hydrex: the real plugin, the real router's partial fill, and a
///         push on both fee swaps. Launch token as token0; the mirrored suite runs token1.
contract SwapPriceLimitForkTest is ForkFixture {
    using stdStorage for StdStorage;

    function _wantToken0() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev Real fees split, `bob` holding launch tokens to push with, and the price settled for the window.
    function _tradedLaunch(bytes32 feeUse) internal returns (address token, address pool) {
        (token, pool,,) = _launchOnSide(WETH, _wantToken0(), feeUse);
        _passLaunchWindow();
        _tradeBothWaysAndAge(token, WETH, 2 ether);
        _swapIn(bob, WETH, token, 1 ether);
        locker.splitRewards(token);
        vm.warp(vm.getBlockTimestamp() + SwapPriceLimit.AVERAGE_WINDOW);
        vm.roll(vm.getBlockNumber() + SwapPriceLimit.AVERAGE_WINDOW / 2);
    }

    function _nextBlock() internal {
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _limit(address token, int24 open, bool launchPriceDown) internal pure returns (uint160) {
        bool tickDown = (token < WETH) == launchPriceDown;
        return
            TickMath.getSqrtRatioAtTick(
                tickDown ? open - SwapPriceLimit.BUFFER_TICKS : open + SwapPriceLimit.BUFFER_TICKS
            );
    }

    function _sqrtPrice(address pool) internal view returns (uint160 price) {
        (price,,,,,) = IAlgebraPool(pool).globalState();
    }

    function _averageTick(address pool) internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = SwapPriceLimit.AVERAGE_WINDOW;
        (int56[] memory cumulatives,) = IAlgebraPlugin(IAlgebraPool(pool).plugin()).getTimepoints(secondsAgos);
        return int24((cumulatives[1] - cumulatives[0]) / int56(uint56(SwapPriceLimit.AVERAGE_WINDOW)));
    }

    /// The assumption the limit rests on: the timepoint holds the tick from before the block's first swap.
    function test_PluginRecordsWhereTheBlockOpened() public onlyForked {
        (address token, address pool) = _tradedLaunch(FeeUses.CREATOR_BALANCE);
        IAlgebraPlugin plugin = IAlgebraPlugin(IAlgebraPool(pool).plugin());
        int24 open = _currentTick(pool);

        _sell(bob, token, WETH, IERC20(token).balanceOf(bob) / 2);
        _sell(bob, token, WETH, IERC20(token).balanceOf(bob));

        assertEq(plugin.lastTimepointTimestamp(), uint32(vm.getBlockTimestamp()), "written this block");
        (,,,, int24 recorded,,) = plugin.timepoints(plugin.timepointIndex());
        assertEq(recorded, open, "holding the tick from before the first swap");
        assertTrue(_currentTick(pool) != open, "while spot moved on");
    }

    function test_ConversionSellsNothingIntoASameBlockPush() public onlyForked {
        (address token, address pool) = _tradedLaunch(FeeUses.CREATOR_BALANCE);
        uint256 owed = locker.protocolOwed(token);
        assertGt(owed, 0);
        uint160 limit = _limit(token, _currentTick(pool), true);

        _sell(bob, token, WETH, IERC20(token).balanceOf(bob));
        uint160 pushed = _sqrtPrice(pool);
        assertTrue(token < WETH ? pushed < limit : pushed > limit, "the push went past the buffer");

        vm.prank(alice);
        assertEq(locker.convertProtocolShare(token), 0, "nothing sold into the push");
        assertEq(locker.protocolOwed(token), owed, "the share stays booked");
        assertEq(_sqrtPrice(pool), pushed, "and the pool was not touched");
    }

    /// The real router stops at the limit and pulls only what filled.
    function test_ALargeConversionStopsAtTheLimit() public onlyForked {
        (address token, address pool) = _tradedLaunch(FeeUses.CREATOR_BALANCE);
        uint256 large = IERC20(token).balanceOf(bob);
        deal(token, address(locker), IERC20(token).balanceOf(address(locker)) + large);
        stdstore.target(address(locker)).sig("protocolOwed(address)").with_key(token).checked_write(large);

        uint160 limit = _limit(token, _currentTick(pool), true);
        uint256 lockerBefore = IERC20(token).balanceOf(address(locker));

        uint256 quoteOut = locker.convertProtocolShare(token);

        uint256 left = locker.protocolOwed(token);
        assertGt(quoteOut, 0);
        assertGt(left, 0, "the rest stays booked");
        assertLt(left, large);
        assertEq(_sqrtPrice(pool), limit, "stopped exactly at the limit");
        assertEq(lockerBefore - IERC20(token).balanceOf(address(locker)), large - left, "pulled only what filled");

        _nextBlock();
        locker.convertProtocolShare(token);
        assertLt(locker.protocolOwed(token), left, "a later block drains more");
    }

    function test_BuybackBuysNothingIntoASameBlockPush() public onlyForked {
        (address token, address pool) = _tradedLaunch(FeeUses.BUYBACK_BURN);
        uint256 owedQuote = locker.creatorOwed(token, WETH);
        uint256 owedToken = locker.creatorOwed(token, token);
        assertGt(owedQuote, 0);
        uint160 limit = _limit(token, _currentTick(pool), false);

        _swapIn(alice, WETH, token, 1 ether);
        uint160 pushed = _sqrtPrice(pool);
        assertTrue(token < WETH ? pushed > limit : pushed < limit, "the push went past the buffer");

        vm.prank(alice);
        locker.spendCreatorShare(token);

        assertEq(buybackBurn.lifetimeBurned(token), owedToken, "only the launch-token fees burned");
        assertEq(locker.creatorOwed(token, WETH), owedQuote, "the quote is booked back");
        assertEq(IERC20(WETH).balanceOf(address(buybackBurn)), 0, "and none left in the fee use");
        assertEq(_sqrtPrice(pool), pushed, "and the pool was not touched");
    }

    function test_ConversionSellsNothingIntoAPushHeldAcrossABlock() public onlyForked {
        (address token, address pool) = _tradedLaunch(FeeUses.CREATOR_BALANCE);
        uint256 owed = locker.protocolOwed(token);
        assertGt(owed, 0);

        // Half as much again as bob bought: past the average's buffer, but still inside the pool's liquidity.
        deal(token, bob, IERC20(token).balanceOf(bob) * 3 / 2);
        _sell(bob, token, WETH, IERC20(token).balanceOf(bob));
        _nextBlock();
        int24 averageLimit =
            _averageTick(pool) + (token < WETH ? -SwapPriceLimit.BUFFER_TICKS : SwapPriceLimit.BUFFER_TICKS);
        assertTrue(
            token < WETH ? _currentTick(pool) < averageLimit : _currentTick(pool) > averageLimit,
            "the push held past the buffer from the average"
        );

        assertEq(locker.convertProtocolShare(token), 0, "nothing sold into the held push");
        assertEq(locker.protocolOwed(token), owed, "the share stays booked");
    }

    /// The live plugin refuses an average older than the pool, so the buyback uses the open alone.
    function test_AYoungPoolsBuybackFallsBackToTheBlockOpen() public onlyForked {
        (address token, address pool,,) = _launchOnSide(WETH, _wantToken0(), FeeUses.BUYBACK_BURN);
        _passLaunchWindow();
        _swapIn(alice, WETH, token, 1 ether);
        locker.splitRewards(token);
        _nextBlock();
        uint256 owedQuote = locker.creatorOwed(token, WETH);
        assertGt(owedQuote, 0);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = SwapPriceLimit.AVERAGE_WINDOW;
        IAlgebraPlugin plugin = IAlgebraPlugin(IAlgebraPool(pool).plugin());
        vm.expectRevert();
        plugin.getTimepoints(secondsAgos);

        locker.spendCreatorShare(token);
        assertLt(locker.creatorOwed(token, WETH), owedQuote, "the buyback went ahead");
    }

    function test_ConversionSkipsAfterTheAverageWasDragged() public onlyForked {
        (address token, address pool) = _tradedLaunch(FeeUses.CREATOR_BALANCE);
        uint256 owed = locker.protocolOwed(token);
        assertGt(owed, 0);

        // Three times what bob bought takes the price past all the liquidity, towards the bottom tick.
        deal(token, bob, IERC20(token).balanceOf(bob) * 3);
        uint256 quoteBack = _sell(bob, token, WETH, IERC20(token).balanceOf(bob));
        _nextBlock();
        _swapIn(bob, WETH, token, quoteBack / 2);

        int24 draggedLimit =
            _averageTick(pool) + (token < WETH ? SwapPriceLimit.BUFFER_TICKS : -SwapPriceLimit.BUFFER_TICKS);
        assertTrue(
            token < WETH ? _currentTick(pool) > draggedLimit : _currentTick(pool) < draggedLimit,
            "the average was dragged more than the buffer below spot"
        );

        assertEq(locker.convertProtocolShare(token), 0, "nothing sold");
        assertEq(locker.protocolOwed(token), owed, "the share stays booked");
    }

    function test_BuybackSpendsEverythingWhenUnpushed() public onlyForked {
        (address token,) = _tradedLaunch(FeeUses.BUYBACK_BURN);
        uint256 owedToken = locker.creatorOwed(token, token);

        locker.spendCreatorShare(token);

        assertGt(buybackBurn.lifetimeBurned(token), owedToken, "the quote bought more to burn");
        assertEq(locker.creatorOwed(token, WETH), 0, "all of it spent");
    }
}

contract SwapPriceLimitMirroredForkTest is SwapPriceLimitForkTest {
    function _wantToken0() internal pure override returns (bool) {
        return false;
    }
}
