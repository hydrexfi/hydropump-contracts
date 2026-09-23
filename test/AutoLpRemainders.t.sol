// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";
import {AutoLpFeeUse} from "../contracts/feeuses/AutoLpFeeUse.sol";
import {TickMath} from "../contracts/libraries/TickMath.sol";

contract AutoLpRangeHarness is AutoLpFeeUse {
    constructor(address locker_) AutoLpFeeUse(locker_) {}

    function range(int24 tick, int24 spacing, bool tokenIs0) external pure returns (int24, int24, bool) {
        return _quoteRange(tick, spacing, tokenIs0);
    }
}

contract AutoLpRemaindersTest is HydropumpFixture {
    function _quote() internal pure virtual returns (address) {
        return HIGH_QUOTE;
    }

    function test_UnpairableLaunchFeesAreBurned() public {
        (address token, address pool,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        // Inside a launch band, token-only fees cannot compound without quote.
        _setSpot(pool, _currentTick(pool) + (token < _quote() ? int24(100) : int24(-100)));
        _accrueFees(token, 40_000e18, 0);
        uint256 supplyBefore = IERC20(token).totalSupply();
        vm.prank(stranger);
        locker.handleCreatorRewards(token);
        assertEq(IERC20(token).totalSupply(), supplyBefore - 30_000e18);
        assertEq(locker.creatorOwed(token, token), 0);
        assertEq(IERC20(token).balanceOf(stranger), 0);
    }

    function test_UnpairableQuoteCreatesOneSidedLiquidityBelowSpot() public {
        (address token, address pool,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        _setSpot(pool, _currentTick(pool) + (token < _quote() ? int24(100) : int24(-100)));
        _accrueFees(token, 0, 1 ether);
        uint256 nextId = npm.nextId();
        vm.prank(stranger);
        locker.handleCreatorRewards(token);
        assertEq(npm.nextId(), nextId + 1, "a separate quote-only position is created");
        (,, address token0, address token1,, int24 lower, int24 upper, uint128 liquidity,,,,) = npm.positions(nextId);
        assertGt(liquidity, 0);
        assertEq(token0, token < _quote() ? token : _quote());
        assertEq(token1, token < _quote() ? _quote() : token);
        if (token < _quote()) assertLe(upper, _currentTick(pool));
        else assertGt(lower, _currentTick(pool));
        assertEq(upper - lower, 200);
        assertEq(locker.creatorOwed(token, _quote()), 0);
        assertEq(IERC20(_quote()).balanceOf(stranger), 0);
    }

    function test_CompoundFirstThenBurnAndPlaceOnlyRemainders() public {
        (address token, address pool, uint256[] memory ids) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        _setSpot(pool, _currentTick(pool) + (token < _quote() ? int24(100) : int24(-100)));
        _accrueFees(token, 40_000e18, 1 ether);
        // Mock a ratio-limited fill; the real position-manager calculation is tested on fork.
        npm.setUsageCaps(token < _quote() ? 20_000e18 : 0.5 ether, token < _quote() ? 0.5 ether : 20_000e18);
        uint128 original = npm.liquidityOf(ids[0]);
        uint256 supplyBefore = IERC20(token).totalSupply();
        vm.prank(stranger);
        locker.handleCreatorRewards(token);
        assertGt(npm.liquidityOf(ids[0]), original);
        assertEq(IERC20(token).totalSupply(), supplyBefore - 10_000e18);
        assertEq(autoLp.lifetimeBurned(token), 10_000e18);
        uint256 id = autoLp.quotePosition(token);
        assertTrue(autoLp.hasQuotePosition(token));
        assertEq(npm.ownerOf(id), address(autoLp));
        assertEq(token < _quote() ? npm.principal1(id) : npm.principal0(id), 0.25 ether);
        for (uint256 i; i < ids.length; i++) {
            assertEq(npm.ownerOf(ids[i]), address(locker));
        }
        assertEq(IERC20(token).allowance(address(autoLp), NPM), 0);
        assertEq(IERC20(_quote()).allowance(address(autoLp), NPM), 0);
        assertEq(IERC20(token).balanceOf(address(autoLp)), 0);
        assertEq(IERC20(_quote()).balanceOf(stranger), 0);
        assertEq(locker.protocolOwed(token), 10_000e18);
        assertEq(locker.protocolOwed(_quote()), 0.25 ether);
    }

    function test_RefreshWithoutNewFeesBurnsCollectedTokensAndPreservesQuote() public {
        (address token, address pool, uint256[] memory ids) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        _setSpot(pool, _currentTick(pool) + (token < _quote() ? int24(100) : int24(-100)));
        _accrueFees(token, 0, 1 ether);
        locker.handleCreatorRewards(token);
        uint256 oldId = autoLp.quotePosition(token);
        uint128 original = npm.liquidityOf(ids[0]);
        vm.prank(pool);
        IERC20(token).transfer(NPM, 100e18);
        npm.setOwed(oldId, token < _quote() ? uint128(100e18) : 0, token < _quote() ? 0 : uint128(100e18));
        uint256 supplyBefore = IERC20(token).totalSupply();
        _setSpot(pool, _currentTick(pool) + 400);
        vm.prank(stranger);
        autoLp.refreshQuotePosition(token);
        assertEq(IERC20(token).totalSupply(), supplyBefore - 100e18);
        assertEq(npm.ownerOf(oldId), address(0), "old NFT burned");
        uint256 newId = autoLp.quotePosition(token);
        assertTrue(newId != oldId);
        assertEq(token < _quote() ? npm.principal1(newId) : npm.principal0(newId), 0.75 ether);
        assertEq(npm.liquidityOf(ids[0]), original, "refresh never removes original liquidity");
        assertEq(IERC20(token).balanceOf(stranger), 0);
        assertEq(IERC20(_quote()).balanceOf(stranger), 0);
    }

    function test_SharedQuoteBalancesStayAttributedAcrossLaunches() public {
        (address a, address poolA,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        (address b, address poolB,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        // Too little quote to buy liquidity at these extreme prices; each launch retains its own carry.
        int24 extreme = a < _quote() ? TickMath.MAX_TICK - 1 : TickMath.MIN_TICK + 1;
        _setSpot(poolA, extreme);
        _setSpot(poolB, extreme);
        _accrueFees(a, 0, 4);
        _accrueFees(b, 0, 8);
        locker.handleCreatorRewards(a);
        locker.handleCreatorRewards(b);
        assertEq(autoLp.quoteCarry(a), 3);
        assertEq(autoLp.quoteCarry(b), 6);
        assertEq(IERC20(_quote()).balanceOf(address(autoLp)), 9);
        _setSpot(poolA, a < _quote() ? int24(-228_200) : int24(228_200));
        autoLp.refreshQuotePosition(a);
        assertEq(autoLp.quoteCarry(b), 6, "other launch's carry cannot fund this position");
        assertEq(IERC20(_quote()).balanceOf(address(autoLp)), 6 + autoLp.quoteCarry(a));
    }

    function test_NoBelowSpotRangeRetainsQuoteUntilPriceMoves() public {
        (address token, address pool,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        int24 opening = _currentTick(pool);
        _setSpot(pool, token < _quote() ? TickMath.MIN_TICK + 1 : TickMath.MAX_TICK - 1);
        _accrueFees(token, 0, 1 ether);
        locker.handleCreatorRewards(token);
        assertEq(autoLp.quoteCarry(token), 0.75 ether);
        assertFalse(autoLp.hasQuotePosition(token));
        _setSpot(pool, opening);
        autoLp.refreshQuotePosition(token);
        assertTrue(autoLp.hasQuotePosition(token));
        assertEq(autoLp.quoteCarry(token), 0);
    }

    function test_ExactOpeningBoundaryCompoundsTokenOnly() public {
        (address token,, uint256[] memory ids) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        uint128 before = npm.liquidityOf(ids[0]);
        _accrueFees(token, 40_000e18, 0);
        locker.handleCreatorRewards(token);
        assertGt(npm.liquidityOf(ids[0]), before);
        assertEq(autoLp.lifetimeBurned(token), 0, "compound usable tokens before burning leftovers");
    }

    function test_UnknownLaunchRefreshReverts() public {
        vm.expectRevert(AutoLpFeeUse.UnknownLaunch.selector);
        autoLp.refreshQuotePosition(address(123));
    }

    function test_NoFeesAndNoSupplementalPositionIsANoop() public {
        (address token,,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        uint256 nextId = npm.nextId();
        vm.prank(stranger);
        autoLp.refreshQuotePosition(token);
        assertFalse(autoLp.hasQuotePosition(token));
        assertEq(npm.nextId(), nextId);
    }

    function test_InvalidAssetsAreRejectedEvenFromLocker() public {
        (address token,,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        address[] memory assets = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (assets[0], assets[1]) = (_quote(), token);
        vm.prank(address(locker));
        vm.expectRevert(AutoLpFeeUse.InvalidAssets.selector);
        autoLp.onFees(token, assets, amounts);
    }

    function test_FailedMintRestoresBookedFeesAndApprovals() public {
        (address token, address pool,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        _setSpot(pool, _currentTick(pool) + (token < _quote() ? int24(100) : int24(-100)));
        _accrueFees(token, 0, 1 ether);
        locker.splitRewards(token);
        npm.setPhantomUsage(token < _quote() ? 1 : 0, token < _quote() ? 0 : 1);
        vm.expectRevert(AutoLpFeeUse.UnexpectedTokenUsage.selector);
        locker.spendCreatorShare(token);
        assertEq(locker.creatorOwed(token, _quote()), 0.75 ether);
        assertEq(IERC20(_quote()).allowance(address(autoLp), NPM), 0);
        assertEq(IERC20(_quote()).balanceOf(address(autoLp)), 0);
        assertEq(autoLp.quoteCarry(token), 0);
        assertFalse(autoLp.hasQuotePosition(token));
    }

    function test_NewFeesCombineWithExistingSupplementalQuote() public {
        (address token, address pool,) = _launch(_quote(), FeeUses.AUTO_LP, 0);
        _setSpot(pool, _currentTick(pool) + (token < _quote() ? int24(100) : int24(-100)));
        _accrueFees(token, 0, 1 ether);
        locker.handleCreatorRewards(token);
        uint256 oldId = autoLp.quotePosition(token);
        _accrueFees(token, 0, 2 ether);
        locker.handleCreatorRewards(token);
        uint256 id = autoLp.quotePosition(token);
        assertEq(npm.ownerOf(oldId), address(0));
        assertEq(token < _quote() ? npm.principal1(id) : npm.principal0(id), 2.25 ether);
        assertEq(locker.creatorOwed(token, _quote()), 0);
        assertEq(autoLp.quoteCarry(token), 0);
    }

    function testFuzz_RangeIsAlignedAndOnQuoteOnlySide(int24 tick, int24 spacing) public {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        spacing = int24(bound(int256(spacing), 1, 16384));
        AutoLpRangeHarness harness = new AutoLpRangeHarness(address(locker));
        bool tokenIs0 = _quote() == HIGH_QUOTE;
        (int24 lower, int24 upper, bool valid) = harness.range(tick, spacing, tokenIs0);
        if (!valid) return;
        assertEq(lower % spacing, 0);
        assertEq(upper % spacing, 0);
        assertEq(upper - lower, spacing);
        assertGe(lower, TickMath.MIN_TICK);
        assertLe(upper, TickMath.MAX_TICK);
        if (tokenIs0) {
            assertLe(upper, tick);
            assertLt(int256(tick) - upper, spacing);
        } else {
            assertGt(lower, tick);
            assertLe(int256(lower) - tick, spacing);
        }
    }
}

contract AutoLpRemaindersMirroredTest is AutoLpRemaindersTest {
    function _quote() internal pure override returns (address) {
        return LOW_QUOTE;
    }
}
