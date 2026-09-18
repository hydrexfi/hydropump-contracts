// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpLocker} from "../../contracts/HydropumpLocker.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {ForkFixture} from "./helpers/ForkFixture.sol";

/// @notice The whole fee path against live Hydrex: real swaps, a real split, a real conversion, and each of
///         the three things a creator share can be spent on.
/// @dev Written against a launch on the token0 side; `FeeFlowMirroredForkTest` repeats every case with the
///      launch token sorting above its quote.
contract FeeFlowForkTest is ForkFixture {
    /// @dev Overridden by the mirrored suite.
    function _wantToken0() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev A launch with real two-way volume behind it and a price history long enough to price a swap
    ///      against. Everything here needs all three.
    function _tradedLaunch(bytes32 feeUse) internal returns (address token, address pool, address account) {
        uint256[] memory ids;
        (token, pool, ids, account) = _launchOnSide(WETH, _wantToken0(), feeUse);
        _tradeBothWaysAndAge(token, WETH, 2 ether);
    }

    // =============================
    //  THE SPLIT
    // =============================

    /// A real swap leaves fees on the locked positions, and the split sends 75% to the escrow and keeps 25%.
    function test_RealVolumeSplitsSeventyFiveTwentyFive() public onlyForked {
        (address token,,) = _tradedLaunch(FeeUses.CREATOR_BALANCE);

        (uint256 toEscrow, uint256 toProtocol) = locker.splitRewards(token);
        assertGt(toEscrow, 0, "the swaps must have left fees");
        assertGt(toProtocol, 0);

        (uint128 grossLaunch, uint128 grossQuote) = locker.lifetimeFees(token);
        assertGt(grossLaunch, 0, "a sell pays its fee in the launch token");
        assertGt(grossQuote, 0, "and a buy pays its fee in the quote");

        // The split is exact against the gross, whichever side of the pair each asset sits on.
        assertEq(locker.creatorOwed(token, token), uint256(grossLaunch) - uint256(grossLaunch) / 4);
        assertEq(locker.creatorOwed(token, WETH), uint256(grossQuote) - uint256(grossQuote) / 4);
        assertEq(locker.protocolOwed(token), uint256(grossLaunch) / 4);
        assertEq(locker.protocolOwed(WETH), uint256(grossQuote) / 4);

        console2.log("gross launch / quote fees", uint256(grossLaunch), uint256(grossQuote));
    }

    /// Only the quote is supposed to reach the buyback, so the protocol's launch-token share is sold into
    /// the launch's own pool on the way — priced against the pool's own time-weighted tick.
    function test_ConvertingLeavesOnlyQuoteForTheBuyback() public onlyForked {
        (address token,,) = _tradedLaunch(FeeUses.CREATOR_BALANCE);

        locker.splitRewards(token);
        locker.convertProtocolShare(token);

        assertEq(locker.protocolOwed(token), 0, "no launch token is kept back");
        assertGt(locker.protocolOwed(WETH), 0, "it arrived as quote instead");

        address[] memory assets = new address[](1);
        assets[0] = WETH;
        locker.sweepProtocol(assets);

        assertGt(IERC20(WETH).balanceOf(buyback), 0, "and the buyback holds quote");
        assertEq(IERC20(token).balanceOf(buyback), 0, "and only quote");
    }

    /// The split never touches the pool, so a pool that cannot fill a sell cannot stop a creator being
    /// paid. Only `convertProtocolShare` depends on the pool, and only for the launch it is called on.
    function test_TheSplitNeverDependsOnThePool() public onlyForked {
        (address token,,) = _tradedLaunch(FeeUses.CREATOR_BALANCE);

        locker.splitRewards(token);

        assertGt(locker.creatorOwed(token, WETH), 0, "the creator's quote share");
        assertGt(locker.creatorOwed(token, token), 0, "and their launch-token share");
        assertGt(locker.protocolOwed(token), 0, "the protocol share waits in the launch token");
        assertGt(locker.protocolOwed(WETH), 0, "and in the quote");

        // Converting is a separate call against a real pool, and works on its own schedule.
        uint256 quoteOut = locker.convertProtocolShare(token);
        assertGt(quoteOut, 0);
        assertEq(locker.protocolOwed(token), 0);
    }

    /// A pool minutes old converts perfectly well now that nothing asks it for a price history.
    function test_AYoungPoolConvertsFine() public onlyForked {
        (address token,,,) = _launchOnSide(WETH, _wantToken0(), FeeUses.CREATOR_BALANCE);
        uint256 bought = _swapIn(alice, WETH, token, 1 ether);
        _sell(alice, token, WETH, bought / 2); // a sell, so there is a launch-token share to convert

        locker.splitRewards(token);
        assertGt(locker.protocolOwed(token), 0);

        assertGt(locker.convertProtocolShare(token), 0, "no oracle, no waiting");
        assertEq(locker.protocolOwed(token), 0);
    }

    // =============================
    //  THE THREE FEE USES
    // =============================

    function test_CreatorBalancePaysOutBothSides() public onlyForked {
        (address token,, address account) = _tradedLaunch(FeeUses.CREATOR_BALANCE);
        locker.splitRewards(token);

        uint256 tokenBefore = IERC20(token).balanceOf(account);
        uint256 quoteBefore = IERC20(WETH).balanceOf(account);

        vm.prank(bob); // permissionless; the destination is whatever the locker says
        locker.spendCreatorShare(token);

        assertGt(IERC20(token).balanceOf(account) - tokenBefore, 0, "launch-token fees reached the creator");
        assertGt(IERC20(WETH).balanceOf(account) - quoteBefore, 0, "and so did the quote fees");
        assertEq(IERC20(WETH).balanceOf(bob), 0, "the caller took nothing");
        assertEq(IERC20(WETH).balanceOf(address(creatorBalance)), 0, "and nothing stayed behind");
    }

    /// Fees go back into the launch's own curve. The position belongs to the locker and has no withdraw
    /// path, so this is one-way — which is only true because Algebra lets anyone add to anyone's position.
    function test_AutoLpGrowsTheLockedCurve() public onlyForked {
        (address token,,) = _tradedLaunch(FeeUses.AUTO_LP);
        locker.splitRewards(token);

        (uint256 positionId, bool found) = autoLp.targetBand(token);
        assertTrue(found);
        (,,,,,,, uint128 liquidityBefore,,,,) = NPM.positions(positionId);
        assertEq(NPM.ownerOf(positionId), address(locker));

        vm.prank(bob);
        locker.spendCreatorShare(token);

        uint128 added = autoLp.lifetimeLiquidityAdded(token);
        (,,,,,,, uint128 liquidityAfter,,,,) = NPM.positions(positionId);
        assertGt(added, 0, "liquidity was added");
        assertEq(liquidityAfter, liquidityBefore + added);
        assertEq(NPM.ownerOf(positionId), address(locker), "and the position never moved");
        assertEq(IERC20(token).balanceOf(bob), 0, "the caller took nothing");
        assertEq(IERC20(token).balanceOf(address(autoLp)), 0, "and the remainder was forwarded, not held");
        assertEq(IERC20(WETH).balanceOf(address(autoLp)), 0);

        console2.log("auto-LP liquidity added", added);
    }

    function test_BuybackBurnDestroysSupply() public onlyForked {
        (address token,,) = _tradedLaunch(FeeUses.BUYBACK_BURN);
        locker.splitRewards(token);

        uint256 supplyBefore = IERC20(token).totalSupply();

        vm.prank(bob);
        locker.spendCreatorShare(token);

        uint256 burned = buybackBurn.lifetimeBurned(token);
        assertGt(burned, 0);
        assertEq(IERC20(token).totalSupply(), supplyBefore - burned, "supply actually fell");
        assertEq(IERC20(token).balanceOf(address(buybackBurn)), 0, "nothing kept back");
        assertEq(IERC20(token).balanceOf(bob), 0, "the caller took nothing");

        console2.log("burned", burned);
    }

    /// The same split feeds whichever strategy a launch chose, and the three are genuinely different.
    function test_ThreeStrategiesSideBySide() public onlyForked {
        (address paid,, address paidAccount) = _tradedLaunch(FeeUses.CREATOR_BALANCE);
        (address pooled,,) = _tradedLaunch(FeeUses.AUTO_LP);
        (address burned,,) = _tradedLaunch(FeeUses.BUYBACK_BURN);

        locker.splitRewards(paid);
        locker.splitRewards(pooled);
        locker.splitRewards(burned);

        uint256 paidBefore = IERC20(WETH).balanceOf(paidAccount);
        (uint256 pooledPosition,) = autoLp.targetBand(pooled);
        (,,,,,,, uint128 pooledLiquidityBefore,,,,) = NPM.positions(pooledPosition);
        uint256 burnedSupplyBefore = IERC20(burned).totalSupply();

        locker.spendCreatorShare(paid);
        locker.spendCreatorShare(pooled);
        locker.spendCreatorShare(burned);

        (,,,,,,, uint128 pooledLiquidityAfter,,,,) = NPM.positions(pooledPosition);
        assertGt(IERC20(WETH).balanceOf(paidAccount), paidBefore, "one paid its creator");
        assertGt(pooledLiquidityAfter, pooledLiquidityBefore, "one grew its own curve");
        assertLt(IERC20(burned).totalSupply(), burnedSupplyBefore, "one destroyed supply");
    }

    /// One call, real chain: uncollected fees to spent creator share and delivered protocol share, with no
    /// second step. This is what the frontend button does, whatever label it is wearing.
    function test_HandleAllRewardsDoesTheWholeThingInOneCall() public onlyForked {
        (address token,, address account) = _tradedLaunch(FeeUses.CREATOR_BALANCE);

        uint256 quoteBefore = IERC20(WETH).balanceOf(account);

        vm.prank(bob);
        locker.handleAllRewards(token);

        assertGt(IERC20(WETH).balanceOf(account), quoteBefore, "the creator was paid");
        assertEq(locker.creatorOwed(token, WETH), 0, "nothing left booked");
        assertEq(locker.creatorOwed(token, token), 0);
        assertEq(locker.protocolOwed(token), 0, "the protocol share was converted on the way");
        assertEq(locker.protocolOwed(WETH), 0, "and swept, so no keeper has to follow up");
        assertGt(IERC20(WETH).balanceOf(buyback), 0, "it reached the buyback");
    }

    // =============================
    //  THE TAIL
    // =============================

    /// The tail band keeps a pool buyable after the rest of the curve is cleared, in both orientations —
    /// which on the mirrored side means the price walking down towards the bottom of the tick range.
    function test_BuyingThroughEveryBandStillFills() public onlyForked {
        (address token, address pool, uint256[] memory ids,) = _launchOnSide(WETH, _wantToken0(), bytes32(0));
        assertEq(ids.length, 5);

        int24 openingTick = _currentTick(pool);
        assertGt(_swapIn(alice, WETH, token, 6_000 ether), 0);

        int24 deepTick = _currentTick(pool);
        if (_wantToken0()) assertGt(deepTick, openingTick, "a buy walks a token0 pool's tick up");
        else assertLt(deepTick, openingTick, "and a mirrored pool's tick down");

        uint256 fdv = (_priceE18(pool, token, WETH) * 10_000_000_000) / 1e18;
        assertGt(fdv, 0);
        assertGt(_swapIn(bob, WETH, token, 10 ether), 0, "the tail keeps the pool buyable");
    }
}

/// @notice Every case above again, with the launch token sorting ABOVE its quote.
contract FeeFlowMirroredForkTest is FeeFlowForkTest {
    function _wantToken0() internal pure override returns (bool) {
        return false;
    }
}
