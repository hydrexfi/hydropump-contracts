// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpLocker} from "../contracts/core/HydropumpLocker.sol";
import {SwapPriceLimit} from "../contracts/libraries/SwapPriceLimit.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebra.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The locker's one job: sweep the bands and send each share where it belongs.
/// @dev Written against a launch on the token0 side. `HydropumpLockerMirroredTest` at the bottom re-runs
///      every case with the launch token sorting above its quote instead, because which side a launch lands
///      on is decided by a CREATE2 address and nothing downstream may depend on it.
contract HydropumpLockerTest is HydropumpFixture {
    /// @dev Overridden by the mirrored suite. The high quote puts a launch token on the token0 side.
    function _quote() internal view virtual returns (address) {
        return HIGH_QUOTE;
    }

    function _launchHere() internal returns (address token, address pool) {
        (token, pool,) = _launch(_quote());
    }

    // =============================
    //  ORIENTATION
    // =============================

    function test_SuiteRunsInTheExpectedOrientation() public {
        (address token,) = _launchHere();
        assertEq(locker.launchIsToken0(token), _quote() == HIGH_QUOTE);
    }

    // =============================
    //  REGISTRATION
    // =============================

    function test_RegisterStoresLaunch() public {
        (address token, address pool) = _launchHere();

        HydropumpLocker.Launch memory launch = locker.getLaunch(token);
        assertEq(launch.quoteToken, _quote());
        assertEq(launch.pool, pool);
        assertEq(launch.creator, creator);
        assertEq(launch.creatorRecipient, creator);
        assertEq(locker.positionCount(token), 5);
        assertEq(locker.fullMask(token), 0x1F);

        // The views the fee uses read through, which is what keeps them from holding their own copy.
        assertEq(locker.creatorRecipient(token), creator);
        assertEq(locker.quoteTokenOf(token), _quote());
        assertEq(locker.poolOf(token), pool);
    }

    function test_OnlyLauncherCanRegister() public {
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotLauncher.selector);
        locker.registerLaunch(makeAddr("t"), _quote(), makeAddr("p"), creator, creator, new uint256[](1));
    }

    function test_CannotRegisterTwice() public {
        (address token,) = _launchHere();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(address(launcher));
        vm.expectRevert(HydropumpLocker.AlreadyRegistered.selector);
        locker.registerLaunch(token, _quote(), makeAddr("p"), creator, creator, ids);
    }

    function test_RejectsEmptyOrOversizedPositionSets() public {
        vm.startPrank(address(launcher));
        vm.expectRevert(HydropumpLocker.InvalidPositionCount.selector);
        locker.registerLaunch(makeAddr("a"), _quote(), makeAddr("p"), creator, creator, new uint256[](0));

        vm.expectRevert(HydropumpLocker.InvalidPositionCount.selector);
        locker.registerLaunch(makeAddr("b"), _quote(), makeAddr("p"), creator, creator, new uint256[](33));
        vm.stopPrank();
    }

    // =============================
    //  THE SPLIT
    // =============================

    /// 75% is booked to the creator and 25% to the protocol. The asymmetric amounts are the point: equal
    /// ones would pass even if the two sides of the pair were transposed.
    function test_SplitBooksSeventyFiveToTheCreatorAndTwentyFiveToTheProtocol() public {
        (address token,) = _launchHere();
        _accrueFees(token, 40_000, 8_000);

        locker.splitRewards(token);

        assertEq(locker.creatorOwed(token, token), 30_000, "creator share of the launch token");
        assertEq(locker.creatorOwed(token, _quote()), 6_000, "creator share of the quote");
        assertEq(locker.protocolOwed(token), 10_000, "protocol share, unconverted");
        assertEq(locker.protocolOwed(_quote()), 2_000);

        // Booked, not moved: the split pushes nothing, so nothing here can fail.
        assertEq(IERC20(token).balanceOf(address(locker)), 40_000, "both shares are still in hand");
        assertEq(IERC20(_quote()).balanceOf(address(locker)), 8_000);
    }

    function test_LifetimeTotalsAreGrossAndNamedByAsset() public {
        (address token,) = _launchHere();
        _accrueFees(token, 40_000, 8_000);
        locker.splitRewards(token);

        (uint128 grossLaunch, uint128 grossQuote) = locker.lifetimeFees(token);
        assertEq(grossLaunch, 40_000, "before the split, not after");
        assertEq(grossQuote, 8_000);

        _accrueFees(token, 10_000, 1_000);
        locker.splitRewards(token);
        (grossLaunch, grossQuote) = locker.lifetimeFees(token);
        assertEq(grossLaunch, 50_000);
        assertEq(grossQuote, 9_000);
    }

    /// Rounding goes to the creator: the protocol share is floored and the escrow takes the remainder.
    function test_RoundingDustFollowsTheCreator() public {
        (address token,) = _launchHere();
        _accrueFees(token, 3, 0);

        locker.splitRewards(token);

        assertEq(locker.creatorOwed(token, token), 3, "25% of 3 floors to 0, so the creator takes all of it");
        assertEq(locker.protocolOwed(token), 0);
    }

    function test_SplitIsPermissionlessAndDestinationsAreFixed() public {
        (address token,) = _launchHere();
        _accrueFees(token, 40_000, 8_000);

        vm.prank(stranger);
        locker.splitRewards(token);

        assertEq(IERC20(token).balanceOf(stranger), 0, "a caller receives nothing");
        assertEq(locker.creatorOwed(token, token), 30_000);
    }

    function test_SplitOnlyTouchesMaskedBands() public {
        (address token,) = _launchHere();
        _accrueFeesOn(token, 0, 1_100, 0);
        _accrueFeesOn(token, 2, 2_200, 0);

        // bits 0 and 2 -> bands 0 and 2, skipping the rest
        locker.splitRewards(token, 0x05);
        assertEq(locker.creatorOwed(token, token), 2_475, "75% of 3,300");

        // Nothing else was swept, so a band left out is still holding its fees.
        _accrueFeesOn(token, 1, 400, 0);
        locker.splitRewards(token, 0x02);
        assertEq(locker.creatorOwed(token, token), 2_475 + 300);
    }

    function test_SplitRevertsOnUnknownLaunchOrEmptyMask() public {
        (address token,) = _launchHere();

        vm.expectRevert(HydropumpLocker.UnknownLaunch.selector);
        locker.splitRewards(makeAddr("nope"), 1);

        vm.expectRevert(HydropumpLocker.EmptyMask.selector);
        locker.splitRewards(token, 0);
    }

    function test_SplitWithNothingAccruedIsANoop() public {
        (address token,) = _launchHere();
        (uint256 toEscrow, uint256 toProtocol) = locker.splitRewards(token);

        assertEq(toEscrow, 0);
        assertEq(toProtocol, 0);
        assertEq(locker.creatorOwed(token, token), 0);
    }

    function test_TheEscrowCannotBeUnset() public {
        vm.prank(owner);
        vm.expectRevert(HydropumpLocker.ZeroAddress.selector);
        locker.setFeeUseRegistry(address(0));
    }

    // =============================
    //  CONVERSION
    // =============================

    /// The split itself never swaps, so the protocol share is booked in whatever it was collected in.
    function test_SplitBooksTheProtocolShareInBothAssets() public {
        (address token,) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);

        locker.splitRewards(token);

        assertEq(locker.protocolOwed(token), 10_000e18, "the launch-token quarter, unconverted");
        assertEq(locker.protocolOwed(_quote()), 2_000, "and the quote quarter");
    }

    /// Converting is its own call, so only the quote token ever reaches the buyback.
    function test_ConvertingTurnsTheLaunchTokenShareIntoQuote() public {
        (address token,) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);
        _seedPoolQuote(token, 1e18);
        locker.splitRewards(token);

        vm.prank(stranger);
        uint256 quoteOut = locker.convertProtocolShare(token);

        assertGt(quoteOut, 0);
        assertEq(locker.protocolOwed(token), 0, "no launch token is kept");
        assertEq(locker.protocolOwed(_quote()), 2_000 + quoteOut);
    }

    /// Pushed past the buffer earlier in the block, nothing sells and the share stays booked.
    function test_ConvertingSellsNothingOnceTheBlockMovedPastTheBuffer() public {
        (address token, address pool) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);
        _seedPoolQuote(token, 1e18);
        locker.splitRewards(token);

        int24 pushed = _currentTick(pool) + _launchPriceOffset(token, -600);
        _moveSpotThisBlock(pool, pushed);

        vm.prank(stranger);
        assertEq(locker.convertProtocolShare(token), 0, "nothing sold into the push");
        assertEq(locker.protocolOwed(token), 10_000e18, "the share stays booked");
        assertEq(_currentTick(pool), pushed, "and the pool was not touched");
    }

    /// Pushed part of the way, the sale stops at the buffer and the rest waits for a later block.
    function test_ConvertingStopsFivePercentBelowTheBlockOpen() public {
        (address token, address pool) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);
        _seedPoolQuote(token, 1e18);
        locker.splitRewards(token);

        int24 open = _currentTick(pool);
        _moveSpotThisBlock(pool, open + _launchPriceOffset(token, -300));

        uint256 quoteOut = locker.convertProtocolShare(token);

        uint256 left = locker.protocolOwed(token);
        assertGt(quoteOut, 0, "the room left under the buffer was used");
        assertGt(left, 0, "the rest stays booked");
        assertLt(left, 10_000e18);
        assertEq(_currentTick(pool), open + _launchPriceOffset(token, -513), "stopped at the buffer");

        vm.warp(vm.getBlockTimestamp() + 2);
        locker.convertProtocolShare(token);
        assertLt(locker.protocolOwed(token), left);
    }

    /// Without a usable block-open price the sale is skipped, never reverted.
    function test_ConvertingSkipsWithoutAUsableOracle() public {
        (address token, address pool) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);
        _seedPoolQuote(token, 1e18);
        locker.splitRewards(token);

        address[3] memory plugins = [address(0), _quote(), pool];
        uint16[3] memory configs = [uint16(1), 1, 0];
        for (uint256 i = 0; i < 3; i++) {
            MockAlgebraPool(pool).setPlugin(plugins[i], configs[i]);
            assertEq(locker.convertProtocolShare(token), 0);
            assertEq(locker.protocolOwed(token), 10_000e18, "the share stays booked");
        }
    }

    /// A small held push stays under the skip, so the stricter anchor (the average) sets the limit.
    function test_ConvertingAnchorsToTheAverageAfterASmallHeldPush() public {
        (address token, address pool) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);
        _seedPoolQuote(token, 1e18);
        locker.splitRewards(token);
        router.configure(3_000, 5_000); // a fill big enough that only the limit stops it

        int24 fair = _currentTick(pool);
        _setSpot(pool, fair + _launchPriceOffset(token, -400));
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.roll(vm.getBlockNumber() + 1);

        locker.convertProtocolShare(token);
        assertApproxEqAbs(_currentTick(pool), fair + _launchPriceOffset(token, -520), 2, "stopped 5% below the average");
    }

    function test_ConvertingOnAYoungPoolFallsBackToTheBlockOpen() public {
        (address token, address pool) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);
        _seedPoolQuote(token, 1e18);
        locker.splitRewards(token);
        vm.warp(vm.getBlockTimestamp() - SwapPriceLimit.AVERAGE_WINDOW); // back to the launch's own second

        int24 open = _currentTick(pool);
        _moveSpotThisBlock(pool, open + _launchPriceOffset(token, -600));
        assertEq(locker.convertProtocolShare(token), 0, "the block open still refuses a push");

        _setSpot(pool, open);
        assertGt(locker.convertProtocolShare(token), 0, "and an unpushed sale does not wait");
    }

    /// A deep one-block push, part-restored, leaves the open far from the average.
    function test_ConvertingSkipsAfterTheAverageWasDragged() public {
        (address token, address pool) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);
        _seedPoolQuote(token, 1e18);
        locker.splitRewards(token);

        int24 fair = _currentTick(pool);
        _setSpot(pool, fair + _launchPriceOffset(token, -100_000));
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.roll(vm.getBlockNumber() + 1);
        _moveSpotThisBlock(pool, fair + _launchPriceOffset(token, -1_000));

        assertEq(locker.convertProtocolShare(token), 0, "nothing sold");
        assertEq(locker.protocolOwed(token), 10_000e18, "the share stays booked");
    }

    function test_ConvertingOnAYoungPoolStopsNearSpotAfterADeepPush() public {
        (address token, address pool) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);
        _seedPoolQuote(token, 1e18);
        locker.splitRewards(token);
        vm.warp(vm.getBlockTimestamp() - SwapPriceLimit.AVERAGE_WINDOW); // back to the launch's own second
        router.configure(3_000, 5_000); // a fill big enough that only the limit stops it

        int24 fair = _currentTick(pool);
        _setSpot(pool, fair + _launchPriceOffset(token, -100_000));
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.roll(vm.getBlockNumber() + 1);
        _moveSpotThisBlock(pool, fair);

        locker.convertProtocolShare(token);
        assertEq(_currentTick(pool), fair + _launchPriceOffset(token, -1026), "stopped twice the buffer below spot");
    }

    function test_ConvertingNothingIsANoop() public {
        (address token,) = _launchHere();
        assertEq(locker.convertProtocolShare(token), 0);
    }

    /// The point of separating them. Nothing in the split touches the pool, so a pool that cannot be
    /// traded against — no liquidity, a paused quote, anything — cannot stop a creator being paid.
    /// Only the conversion fails, and only for the launch whose pool is broken.
    function test_ASplitStillPaysCreatorsWhenThePoolCannotBeTradedAgainst() public {
        (address token,) = _launchHere();
        _accrueFees(token, 40_000e18, 8_000);
        // No quote seeded, so the pool has nothing to pay a sell out of.

        locker.splitRewards(token);
        assertEq(locker.creatorOwed(token, token), 30_000e18, "the creator's share went through regardless");
        assertEq(locker.creatorOwed(token, _quote()), 6_000);

        vm.expectRevert();
        locker.convertProtocolShare(token);

        // And it is still there to convert once the pool can fill it.
        assertEq(locker.protocolOwed(token), 10_000e18);
        _seedPoolQuote(token, 1e18);
        assertGt(locker.convertProtocolShare(token), 0);
    }

    // =============================
    //  THE PROTOCOL SWEEP
    // =============================

    /// Credited and pulled rather than pushed, so the buyback's ability to receive a token is never in the
    /// path of a creator being paid.
    function test_SweepProtocolMovesTheCreditedShare() public {
        (address token,) = _launchHere();
        _accrueFees(token, 0, 8_000);
        locker.splitRewards(token);

        assertEq(IERC20(_quote()).balanceOf(buyback), 0, "nothing moves on its own");

        address[] memory assets = new address[](1);
        assets[0] = _quote();
        vm.prank(stranger);
        uint256[] memory swept = locker.sweepProtocol(assets);

        assertEq(swept[0], 2_000);
        assertEq(IERC20(_quote()).balanceOf(buyback), 2_000);
        assertEq(locker.protocolOwed(_quote()), 0);
        assertEq(IERC20(_quote()).balanceOf(stranger), 0, "the caller gets nothing");
    }

    /// A launch token has to be converted before it can leave, which is what keeps the buyback holding
    /// nothing but quote tokens.
    function test_SweepRefusesALaunchTokenUntilItIsConverted() public {
        (address token,) = _launchHere();
        _accrueFees(token, 40_000e18, 0);
        _seedPoolQuote(token, 1e18);
        locker.splitRewards(token);

        address[] memory assets = new address[](1);
        assets[0] = token;
        vm.expectRevert(HydropumpLocker.ConvertFirst.selector);
        locker.sweepProtocol(assets);

        locker.convertProtocolShare(token);
        assets[0] = _quote();
        locker.sweepProtocol(assets);
        assertGt(IERC20(_quote()).balanceOf(buyback), 0);
        assertEq(IERC20(token).balanceOf(buyback), 0, "and only the quote got there");
    }

    function test_SweepSkipsEmptyAssetsAndPoolsAcrossLaunches() public {
        (address tokenA,) = _launchHere();
        (address tokenB,,) = _launch(_quote());
        _accrueFees(tokenA, 0, 4_000);
        locker.splitRewards(tokenA);
        _accrueFees(tokenB, 0, 8_000);
        locker.splitRewards(tokenB);

        assertEq(locker.protocolOwed(_quote()), 3_000, "both launches pooled into one balance");

        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (makeAddr("nothingOwed"), _quote());
        uint256[] memory swept = locker.sweepProtocol(assets);

        assertEq(swept[0], 0);
        assertEq(swept[1], 3_000);
    }

    /// The isolation the credit-then-pull design buys: a buyback that cannot receive a token stalls only
    /// its own payout, and the creator's share has already left for the escrow regardless.
    function test_ABlockedBuybackCannotStopACreatorBeingPaid() public {
        (address token,) = _launchHere();
        _accrueFees(token, 0, 8_000);

        MockERC20(_quote()).setBlocked(buyback, true);

        locker.splitRewards(token);
        assertEq(locker.creatorOwed(token, _quote()), 6_000, "the creator side went through");

        address[] memory assets = new address[](1);
        assets[0] = _quote();
        vm.expectRevert();
        locker.sweepProtocol(assets);

        // And the protocol share is safe in the ledger until the recipient can take it.
        assertEq(locker.protocolOwed(_quote()), 2_000);
        vm.prank(owner);
        locker.setProtocolFeeRecipient(makeAddr("rescue"));
        locker.sweepProtocol(assets);
        assertEq(IERC20(_quote()).balanceOf(makeAddr("rescue")), 2_000);
    }

    // =============================
    //  RECIPIENT + LOCK
    // =============================

    function test_OnlyCurrentRecipientCanRedirect() public {
        (address token,) = _launchHere();

        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotCreatorRecipient.selector);
        locker.setCreatorRecipient(token, stranger);

        vm.prank(creator);
        locker.setCreatorRecipient(token, stranger);
        assertEq(locker.creatorRecipient(token), stranger);
    }

    /// The locker or registry as recipient would trap the creator's share for good.
    function test_RecipientCannotBeRedirectedToTheLockerOrRegistry() public {
        (address token,) = _launchHere();

        vm.startPrank(creator);
        vm.expectRevert(HydropumpLocker.InvalidCreatorRecipient.selector);
        locker.setCreatorRecipient(token, address(locker));
        vm.expectRevert(HydropumpLocker.InvalidCreatorRecipient.selector);
        locker.setCreatorRecipient(token, address(registry));
        vm.stopPrank();
    }

    function test_ExposesNoWayToMoveAPosition() public view {
        // The lock is structural: no transfer, withdraw, burn or decreaseLiquidity entry point exists.
        string[4] memory forbidden = [
            "safeTransferFrom(address,address,uint256)",
            "withdraw(address,address,uint256)",
            "burn(uint256)",
            "decreaseLiquidity(uint256,uint128,uint256,uint256,uint256)"
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            assertFalse(_codeContains(address(locker), bytes4(keccak256(bytes(forbidden[i])))), forbidden[i]);
        }
    }

    function test_RejectsNFTsFromAnyoneButThePositionManager() public {
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotNFTPositionManager.selector);
        locker.onERC721Received(stranger, stranger, 1, "");

        vm.prank(NPM);
        assertEq(locker.onERC721Received(NPM, NPM, 1, ""), locker.onERC721Received.selector);
    }

    // =============================
    //  ADMIN
    // =============================

    function test_AdminSettersAreOwnerOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        locker.setLauncher(stranger);
        vm.expectRevert();
        locker.setFeeUseRegistry(stranger);
        vm.expectRevert();
        locker.setProtocolFeeRecipient(stranger);
        vm.expectRevert();
        locker.setFeeSplit(1, 1);
        vm.stopPrank();
    }

    function test_FeeSplitIsARatioAndRejectsZeroTotal() public {
        (address token,) = _launchHere();

        vm.prank(owner);
        locker.setFeeSplit(75, 25); // same ratio as 7500/2500
        _accrueFees(token, 40_000, 0);
        locker.splitRewards(token);
        assertEq(locker.creatorOwed(token, token), 30_000);

        vm.prank(owner);
        vm.expectRevert(HydropumpLocker.InvalidFeeSplit.selector);
        locker.setFeeSplit(0, 0);
    }

    function test_SplitChangeDoesNotTouchWhatAlreadyLeft() public {
        (address token,) = _launchHere();
        _accrueFees(token, 40_000, 0);
        locker.splitRewards(token);

        vm.prank(owner);
        locker.setFeeSplit(0, 1); // everything to the protocol from here on

        _accrueFees(token, 40_000, 0);
        locker.splitRewards(token);

        assertEq(locker.creatorOwed(token, token), 30_000, "the earlier share stands");
        assertEq(locker.protocolOwed(token), 10_000 + 40_000);
    }

    function test_UpgradeIsOwnerOnly() public {
        address newImpl = address(new HydropumpLocker());

        vm.prank(stranger);
        vm.expectRevert();
        locker.upgradeToAndCall(newImpl, "");

        vm.prank(owner);
        locker.upgradeToAndCall(newImpl, "");
    }

    function test_ImplementationCannotBeInitialized() public {
        HydropumpLocker impl = new HydropumpLocker();
        vm.expectRevert();
        impl.initialize(owner, address(launcher), buyback, CREATOR_FEE, PROTOCOL_FEE);
    }

    // ---------------------------------------------------------------- helpers

    function _codeContains(address target, bytes4 selector) internal view returns (bool) {
        bytes memory code = target.code;
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (
                code[i] == selector[0] && code[i + 1] == selector[1] && code[i + 2] == selector[2]
                    && code[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }
}

/// @notice Every case above again, with the launch token sorting ABOVE its quote.
/// @dev The launcher hands out both orientations and cannot be made to prefer one, so the fee split has to
///      be right in both. Re-running the suite is what makes that hold for the collect, the conversion, the
///      escrow push and the protocol sweep at once, rather than for whichever one a single test happened to
///      exercise.
contract HydropumpLockerMirroredTest is HydropumpLockerTest {
    function _quote() internal pure override returns (address) {
        return LOW_QUOTE;
    }
}
