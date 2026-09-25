// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";
import {KeeperBuybackBurnFeeUse} from "../contracts/feeuses/KeeperBuybackBurnFeeUse.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockVeHydx} from "./mocks/MockVeHydx.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebra.sol";
import {MockBountyCallbackQuote} from "./mocks/MockBountyCallbackQuote.sol";

contract KeeperBuybackTest is HydropumpFixture {
    KeeperBuybackBurnFeeUse internal keeperBuyback;
    MockVeHydx internal ve;
    address internal keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        ve = new MockVeHydx();
        ve.setPosition(1, keeper, 1e18);
        keeperBuyback = new KeeperBuybackBurnFeeUse(address(locker), address(ve));
        vm.prank(owner);
        registry.replaceFeeUse(FeeUses.BUYBACK_BURN, address(keeperBuyback));
    }

    function _quote() internal pure virtual returns (address) {
        return HIGH_QUOTE;
    }

    function _configured(uint16 bps, uint256 quoteAmount) internal returns (address token, address pool) {
        (token, pool,) = _launch(_quote(), FeeUses.BUYBACK_BURN, 0);
        vm.prank(creator);
        keeperBuyback.configureBuyback(token, bps);
        _accrueFees(token, 0, quoteAmount);
        locker.splitRewards(token);
    }

    function _execute(address token) internal {
        vm.prank(keeper);
        locker.executeKeeperBuyback(token, 1);
    }

    function test_LegacyEntryCannotBypassKeeperGate() public {
        (address token,) = _configured(250, 1e18);
        vm.prank(stranger);
        vm.expectRevert(KeeperBuybackBurnFeeUse.KeeperEntryRequired.selector);
        locker.spendCreatorShare(token);
        vm.expectRevert(KeeperBuybackBurnFeeUse.KeeperEntryRequired.selector);
        locker.handleCreatorRewards(token);
        vm.expectRevert(KeeperBuybackBurnFeeUse.KeeperEntryRequired.selector);
        locker.handleAllRewards(token);
        assertEq(locker.creatorOwed(token, _quote()), 0.75 ether);
    }

    function test_FullFillPaysTwoPointFivePercentAndBurnsBoughtTokens() public {
        (address token,) = _configured(250, 1e18);
        uint256 budget = locker.creatorOwed(token, _quote());
        uint256 supply = IERC20(token).totalSupply();
        _execute(token);
        assertEq(IERC20(_quote()).balanceOf(keeper), budget * 250 / 10_000);
        assertEq(locker.creatorOwed(token, _quote()), 0);
        assertGt(keeperBuyback.lifetimeBurned(token), 0);
        assertLt(IERC20(token).totalSupply(), supply);
        assertEq(IERC20(_quote()).balanceOf(address(keeperBuyback)), 0);
        assertEq(IERC20(token).balanceOf(address(keeperBuyback)), 0);
        _execute(token);
        assertEq(IERC20(_quote()).balanceOf(keeper), budget * 250 / 10_000, "no duplicate payout");
    }

    function test_RejectsNonOwnerAndExpiredPosition() public {
        (address token,) = _configured(250, 1e18);
        vm.prank(stranger);
        vm.expectRevert(KeeperBuybackBurnFeeUse.IneligibleKeeper.selector);
        locker.executeKeeperBuyback(token, 1);
        ve.setPosition(1, keeper, 0);
        vm.prank(keeper);
        vm.expectRevert(KeeperBuybackBurnFeeUse.IneligibleKeeper.selector);
        locker.executeKeeperBuyback(token, 1);
        assertEq(locker.creatorOwed(token, _quote()), 0.75 ether);
        ve.setPosition(1, stranger, 1e18);
        vm.prank(keeper);
        vm.expectRevert(KeeperBuybackBurnFeeUse.IneligibleKeeper.selector);
        locker.executeKeeperBuyback(token, 1);
    }

    function test_SetupIsCreatorOnlyBoundedAndWriteOnce() public {
        (address token,,) = _launch(_quote(), FeeUses.BUYBACK_BURN, 0);
        vm.expectRevert(KeeperBuybackBurnFeeUse.NotCreator.selector);
        keeperBuyback.configureBuyback(token, 250);
        vm.startPrank(creator);
        vm.expectRevert(KeeperBuybackBurnFeeUse.InvalidBounty.selector);
        keeperBuyback.configureBuyback(token, 9901);
        keeperBuyback.configureBuyback(token, 9900);
        vm.expectRevert(KeeperBuybackBurnFeeUse.AlreadyConfigured.selector);
        keeperBuyback.configureBuyback(token, 0);
        vm.stopPrank();
    }

    function test_MaxBountyPaysNinetyNinePercent() public {
        (address token,) = _configured(9900, 1e18);
        uint256 budget = locker.creatorOwed(token, _quote());
        _execute(token);
        assertEq(IERC20(_quote()).balanceOf(keeper), budget * 9900 / 10_000);
        assertEq(locker.creatorOwed(token, _quote()), 0);
        assertGt(keeperBuyback.lifetimeBurned(token), 0);
    }

    function test_UnconfiguredLaunchCannotSpend() public {
        (address token,,) = _launch(_quote(), FeeUses.BUYBACK_BURN, 0);
        _accrueFees(token, 0, 1e18);
        vm.prank(keeper);
        vm.expectRevert(KeeperBuybackBurnFeeUse.NotConfigured.selector);
        locker.executeKeeperBuyback(token, 1);
    }

    function test_SkippedSwapPaysNothingAndRebooksEverything() public {
        (address token, address pool) = _configured(250, 1e18);
        _moveSpotThisBlock(pool, _currentTick(pool) + _launchPriceOffset(token, 600));
        _execute(token);
        assertEq(IERC20(_quote()).balanceOf(keeper), 0);
        assertEq(locker.creatorOwed(token, _quote()), 0.75 ether);
        assertEq(IERC20(_quote()).balanceOf(address(keeperBuyback)), 0);
    }

    function test_PartialFillBountyUsesOnlyActualSpendAndExcludesDonations() public {
        (address token, address pool) = _configured(250, 1e18);
        uint256 budget = locker.creatorOwed(token, _quote());
        MockERC20(_quote()).mint(address(keeperBuyback), 123);
        _moveSpotThisBlock(pool, _currentTick(pool) + _launchPriceOffset(token, 300));
        uint256 beforePool = IERC20(_quote()).balanceOf(pool);
        _execute(token);
        uint256 spent = IERC20(_quote()).balanceOf(pool) - beforePool;
        uint256 bounty = IERC20(_quote()).balanceOf(keeper);
        assertGt(spent, 0);
        assertGt(locker.creatorOwed(token, _quote()), 0);
        assertEq(bounty, spent * 250 / 9750);
        assertEq(spent + bounty + locker.creatorOwed(token, _quote()), budget);
        assertEq(IERC20(_quote()).balanceOf(address(keeperBuyback)), 123);
    }

    function test_ZeroBountyStillRequiresActiveHolder() public {
        (address token,) = _configured(0, 1e18);
        _execute(token);
        assertEq(IERC20(_quote()).balanceOf(keeper), 0);
        assertEq(locker.creatorOwed(token, _quote()), 0);
        assertGt(keeperBuyback.lifetimeBurned(token), 0);
    }

    function test_NoOutputPaysNoBounty() public {
        (address token,) = _configured(250, 1e18);
        router.configure(1_000_000, 500);
        _execute(token);
        assertEq(IERC20(_quote()).balanceOf(keeper), 0);
        assertEq(keeperBuyback.lifetimeBurned(token), 0);
        assertEq(locker.creatorOwed(token, _quote()), 0.75 ether * 250 / 10_000);
    }

    function test_UnusableOraclePaysNothing() public {
        (address token, address pool) = _configured(250, 1e18);
        MockAlgebraPool(pool).setPlugin(address(0), 1);
        _execute(token);
        assertEq(IERC20(_quote()).balanceOf(keeper), 0);
        assertEq(locker.creatorOwed(token, _quote()), 0.75 ether);
    }

    function test_TokenOnlyBurnPaysNoBounty() public {
        (address token,) = _configured(250, 0);
        _accrueFees(token, 1e18, 0);
        _execute(token);
        assertEq(keeperBuyback.lifetimeBurned(token), 0.75 ether);
        assertEq(IERC20(_quote()).balanceOf(keeper), 0);
    }

    function test_CannotForgeKeeperCallback() public {
        vm.expectRevert(bytes4(keccak256("NotLocker()")));
        keeperBuyback.onFeesForKeeper(address(1), new address[](0), new uint256[](0), keeper, 1);
    }

    function test_FailedBountyTransferRollsBackSwapAndAccounting() public {
        (address token, address pool) = _configured(250, 1e18);
        uint256 poolQuote = IERC20(_quote()).balanceOf(pool);
        uint256 supply = IERC20(token).totalSupply();
        MockERC20(_quote()).setBlocked(keeper, true);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(MockERC20.TransferBlocked.selector, keeper));
        locker.executeKeeperBuyback(token, 1);
        assertEq(locker.creatorOwed(token, _quote()), 0.75 ether);
        assertEq(IERC20(_quote()).balanceOf(pool), poolQuote);
        assertEq(IERC20(token).totalSupply(), supply);
        assertEq(keeperBuyback.lifetimeBurned(token), 0);
    }

    function test_BountyCallbackCannotReenterLocker() public {
        (address token,) = _configured(250, 1e18);
        vm.etch(_quote(), address(new MockBountyCallbackQuote()).code);
        MockBountyCallbackQuote quote = MockBountyCallbackQuote(_quote());
        quote.setCallback(address(locker), keeper, abi.encodeCall(locker.executeKeeperBuyback, (token, 1)));
        _execute(token);
        assertTrue(quote.attempted());
        assertFalse(quote.succeeded());
        assertEq(quote.failure(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(quote.balanceOf(keeper), 0.75 ether * 250 / 10_000);
    }

    function test_BountyRatesAreIsolatedByLaunch() public {
        (address a,) = _configured(250, 1e18);
        (address b,) = _configured(100, 1e18);
        _execute(a);
        uint256 first = IERC20(_quote()).balanceOf(keeper);
        _execute(b);
        assertEq(first, 0.75 ether * 250 / 10_000);
        assertEq(IERC20(_quote()).balanceOf(keeper) - first, 0.75 ether * 100 / 10_000);
    }

    function test_DustDoesNotRoundBountyUp() public {
        (address token,) = _configured(250, 4);
        _execute(token);
        assertEq(IERC20(_quote()).balanceOf(keeper), 0);
        assertEq(locker.creatorOwed(token, _quote()), 0);
    }

    /// Invariant: spending, bounty and rebooked remainder conserve the allocated quote, excluding donations.
    function testFuzz_BudgetConservation(uint96 amount, uint16 bps, uint16 push) public {
        amount = uint96(bound(amount, 1e6, 1e18));
        bps = uint16(bound(bps, 0, 9900));
        push = uint16(bound(push, 0, 600));
        (address token, address pool) = _configured(bps, amount);
        uint256 budget = locker.creatorOwed(token, _quote());
        _moveSpotThisBlock(pool, _currentTick(pool) + _launchPriceOffset(token, int24(uint24(push))));
        uint256 beforePool = IERC20(_quote()).balanceOf(pool);
        _execute(token);
        uint256 spent = IERC20(_quote()).balanceOf(pool) - beforePool;
        uint256 bounty = IERC20(_quote()).balanceOf(keeper);
        assertEq(spent + bounty + locker.creatorOwed(token, _quote()), budget);
        assertLe(bounty, budget * bps / 10_000);
        assertEq(IERC20(_quote()).balanceOf(address(keeperBuyback)), 0);
    }
}

contract KeeperBuybackMirroredTest is KeeperBuybackTest {
    function _quote() internal pure override returns (address) {
        return LOW_QUOTE;
    }
}
