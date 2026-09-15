// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLocker} from "../contracts/HydropumpLocker.sol";
import {IHydropumpLocker} from "../contracts/interfaces/IHydropumpLocker.sol";
import {HydropumpFeeEscrow} from "../contracts/HydropumpFeeEscrow.sol";
import {HydropumpAddresses} from "../contracts/libraries/HydropumpAddresses.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";
import {MockAlgebraPool} from "./mocks/MockAlgebraPool.sol";
import {INonfungiblePositionManager} from "../contracts/interfaces/INonfungiblePositionManager.sol";

contract HydropumpLockerTest is Test {
    address internal constant NPM = HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER;

    HydropumpLocker internal locker;
    HydropumpFeeEscrow internal feeEscrow;
    MockPositionManager internal npm;
    MockAlgebraPool internal pool;
    MockERC20 internal launchToken;
    MockERC20 internal quote;

    address internal owner = makeAddr("owner");
    address internal launcher = makeAddr("launcher");
    address internal buyback = makeAddr("buyback");
    address internal creator = makeAddr("creator");
    address internal creatorRecipient = makeAddr("creatorRecipient");
    address internal stranger = makeAddr("stranger");

    uint256[] internal ids;

    function setUp() public {
        ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            ids[i] = i + 1;
        }

        vm.etch(NPM, address(new MockPositionManager()).code);
        npm = MockPositionManager(NPM);
        pool = new MockAlgebraPool();

        launchToken = new MockERC20("Alpha", "ALPHA");
        quote = new MockERC20("Wrapped Ether", "WETH");
        npm.setPair(address(launchToken), address(quote));

        locker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(HydropumpLocker.initialize, (owner, launcher, buyback, uint64(7_500), uint64(2_500)))
                )
            )
        );

        feeEscrow = new HydropumpFeeEscrow(owner, address(locker));
        vm.prank(owner);
        locker.setFeeEscrow(address(feeEscrow));

        vm.prank(launcher);
        locker.registerLaunch(address(launchToken), address(quote), address(pool), creator, creatorRecipient, ids);
    }

    function _fund(uint256 positionId, uint256 amount0, uint256 amount1) internal {
        launchToken.mint(NPM, amount0);
        quote.mint(NPM, amount1);
        npm.setOwed(positionId, amount0, amount1);
    }

    // =============================
    //  REGISTRATION
    // =============================

    function test_RegisterStoresLaunch() public view {
        HydropumpLocker.Launch memory launch = locker.getLaunch(address(launchToken));
        assertEq(launch.quoteToken, address(quote));
        assertEq(launch.creator, creator);
        assertEq(launch.creatorRecipient, creatorRecipient);
        assertEq(locker.getPositions(address(launchToken))[4], 5);
        assertEq(locker.fullMask(address(launchToken)), 0x1F);
    }

    function test_OnlyLauncherCanRegister() public {
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotLauncher.selector);
        locker.registerLaunch(makeAddr("t"), address(quote), makeAddr("p"), creator, creatorRecipient, ids);
    }

    function test_CannotRegisterTwice() public {
        vm.prank(launcher);
        vm.expectRevert(HydropumpLocker.AlreadyRegistered.selector);
        locker.registerLaunch(address(launchToken), address(quote), makeAddr("p"), creator, creatorRecipient, ids);
    }

    function test_HandlesAnyPositionCount() public {
        uint256[] memory three = new uint256[](3);
        uint256[] memory twelve = new uint256[](12);
        for (uint256 i = 0; i < 3; i++) {
            three[i] = 100 + i;
        }
        for (uint256 i = 0; i < 12; i++) {
            twelve[i] = 200 + i;
        }

        address tokenA = address(new MockERC20("A", "A"));
        address tokenB = address(new MockERC20("B", "B"));

        vm.startPrank(launcher);
        locker.registerLaunch(tokenA, address(quote), makeAddr("poolA"), creator, creatorRecipient, three);
        locker.registerLaunch(tokenB, address(quote), makeAddr("poolB"), creator, creatorRecipient, twelve);
        vm.stopPrank();

        assertEq(locker.positionCount(tokenA), 3);
        assertEq(locker.positionCount(tokenB), 12);
        assertEq(locker.fullMask(tokenA), 0x7);
        assertEq(locker.fullMask(tokenB), 0xFFF);
        assertEq(locker.getPositions(tokenB)[11], 211);

        (uint256[] memory got0,) = locker.collect(tokenB, locker.fullMask(tokenB));
        assertEq(got0.length, 12, "collect must size to the launch's position count");
    }

    function test_RejectsEmptyOrOversizedPositionSets() public {
        vm.startPrank(launcher);
        vm.expectRevert(HydropumpLocker.InvalidPositionCount.selector);
        locker.registerLaunch(makeAddr("a"), address(quote), makeAddr("p"), creator, creatorRecipient, new uint256[](0));

        vm.expectRevert(HydropumpLocker.InvalidPositionCount.selector);
        locker.registerLaunch(
            makeAddr("b"), address(quote), makeAddr("p"), creator, creatorRecipient, new uint256[](33)
        );
        vm.stopPrank();
    }

    // =============================
    //  FEE SPLIT
    // =============================

    function test_ClaimableReportsCreditedFeesForBothAssets() public {
        _fund(1, 10_000, 20_000);
        locker.collect(address(launchToken), 0x01);

        HydropumpLocker.ClaimableFees memory fees = locker.claimable(address(launchToken));

        assertEq(fees.launchToken, address(launchToken));
        assertEq(fees.quoteToken, address(quote));
        assertEq(fees.launchTokenAmount, 7_500);
        assertEq(fees.quoteAmount, 15_000);
    }

    function test_ClaimableGoesToZeroAfterClaim() public {
        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);
        locker.claim(address(launchToken));

        assertEq(locker.claimable(address(launchToken)).launchTokenAmount, 0);
    }

    function test_ClaimableManyCoversACreatorsWholePortfolio() public {
        uint256[] memory ids2 = new uint256[](1);
        ids2[0] = 99;
        MockERC20 second = new MockERC20("Beta", "BETA");
        vm.prank(launcher);
        locker.registerLaunch(address(second), address(quote), makeAddr("pool2"), creator, creatorRecipient, ids2);

        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(launchToken), address(second));
        HydropumpLocker.ClaimableFees[] memory fees = locker.claimableMany(tokens);

        assertEq(fees.length, 2);
        assertEq(fees[0].launchTokenAmount, 7_500);
        assertEq(fees[1].launchTokenAmount, 0);
        assertEq(fees[1].quoteToken, address(quote));
    }

    function test_TotalOwedIncludesFeesStillInThePositions() public {
        _fund(1, 10_000, 0); // collected and credited
        locker.collect(address(launchToken), 0x01);
        _fund(3, 20_000, 10_000); // still sitting in a position

        assertEq(locker.claimable(address(launchToken)).launchTokenAmount, 7_500, "claimable sees credited only");

        HydropumpLocker.ClaimableFees memory owed = locker.totalOwed(address(launchToken));

        assertEq(owed.launchTokenAmount, 7_500 + 15_000);
        assertEq(owed.quoteAmount, 7_500);
    }

    function test_TotalOwedSentAsATransactionIsJustACollect() public {
        _fund(2, 10_000, 0);

        locker.totalOwed(address(launchToken));

        // Fees were collected and split as normal, nothing stranded.
        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 7_500);
        assertEq(locker.protocolOwed(address(launchToken)), 2_500);
    }

    function test_CollectSplitsSeventyFiveTwentyFive() public {
        // 10000 wei splits exactly along the 75 / 25 shares
        _fund(1, 10_000, 20_000);

        locker.collect(address(launchToken), 0x01);

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 7_500);
        assertEq(locker.creatorOwed(address(launchToken), address(quote)), 15_000);
        assertEq(locker.protocolOwed(address(launchToken)), 2_500);
        assertEq(locker.protocolOwed(address(quote)), 5_000);
        assertEq(launchToken.balanceOf(address(locker)), 0, "locker should not custody credited fees");
        assertEq(quote.balanceOf(address(locker)), 0, "locker should not custody credited fees");
        assertEq(launchToken.balanceOf(address(feeEscrow)), 10_000);
        assertEq(quote.balanceOf(address(feeEscrow)), 20_000);
    }

    function test_FeeEscrowCanOnlyBeConfiguredOnce() public {
        HydropumpFeeEscrow replacement = new HydropumpFeeEscrow(owner, address(locker));
        vm.prank(owner);
        vm.expectRevert(HydropumpLocker.FeeEscrowAlreadySet.selector);
        locker.setFeeEscrow(address(replacement));
    }

    function test_PreEscrowBalancesRemainClaimableAfterEscrowIsConfigured() public {
        HydropumpLocker transitioningLocker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(HydropumpLocker.initialize, (owner, launcher, buyback, uint64(7_500), uint64(2_500)))
                )
            )
        );
        uint256[] memory transitionIds = new uint256[](1);
        transitionIds[0] = 77;
        vm.prank(launcher);
        transitioningLocker.registerLaunch(
            address(launchToken), address(quote), makeAddr("transitionPool"), creator, creatorRecipient, transitionIds
        );

        _fund(77, 10_000, 8_000);
        transitioningLocker.collect(address(launchToken), 1);
        assertEq(launchToken.balanceOf(address(transitioningLocker)), 10_000);

        HydropumpFeeEscrow transitionEscrow = new HydropumpFeeEscrow(owner, address(transitioningLocker));
        vm.prank(owner);
        transitioningLocker.setFeeEscrow(address(transitionEscrow));

        assertEq(transitioningLocker.creatorOwed(address(launchToken), address(launchToken)), 7_500);
        assertEq(transitioningLocker.protocolOwed(address(quote)), 2_000);

        transitioningLocker.claimCredited(address(launchToken));
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (address(launchToken), address(quote));
        transitioningLocker.sweepProtocol(assets);

        assertEq(launchToken.balanceOf(creatorRecipient), 7_500);
        assertEq(quote.balanceOf(creatorRecipient), 6_000);
        assertEq(launchToken.balanceOf(buyback), 2_500);
        assertEq(quote.balanceOf(buyback), 2_000);
    }

    function test_ApprovedAutoLpStrategyCompoundsOnlyTheActivePosition() public {
        pool.setTick(150);
        npm.setPosition(1, 100, 200);

        vm.prank(owner);
        locker.setAutoLpStrategy(address(launchToken), stranger);

        launchToken.mint(stranger, 1_000);
        quote.mint(stranger, 500);
        vm.startPrank(stranger);
        launchToken.approve(address(locker), 1_000);
        quote.approve(address(locker), 500);

        locker.compound(address(launchToken), 0, 1_000, 500, 700, 350, 150, 5);
        vm.stopPrank();

        assertEq(npm.increased0(1), 800);
        assertEq(npm.increased1(1), 400);
        assertEq(launchToken.balanceOf(stranger), 200, "unused token0 returned to strategy");
        assertEq(quote.balanceOf(stranger), 100, "unused token1 returned to strategy");
    }

    function test_LaunchCanAllocatePartOfCreatorShareToAutoLp() public {
        MockERC20 second = new MockERC20("Auto", "AUTO");
        uint256[] memory autoIds = new uint256[](1);
        autoIds[0] = 88;
        IHydropumpLocker.FeeRoute[] memory routes = _autoLpRoutes(stranger, 1_000);
        vm.prank(launcher);
        locker.registerLaunchWithRoutes(
            address(second), address(quote), address(pool), creator, creatorRecipient, autoIds, routes
        );
        npm.setPair(address(second), address(quote));
        second.mint(NPM, 10_000);
        npm.setOwed(88, 10_000, 0);

        locker.collect(address(second), 1);

        assertEq(locker.creatorOwed(address(second), address(second)), 6_500);
        assertEq(locker.protocolOwed(address(second)), 2_500);
        assertEq(feeEscrow.claimable(locker.autoLpAccount(address(second)), address(second)), 1_000);
        assertEq(feeEscrow.recipient(locker.autoLpAccount(address(second))), stranger);
        (uint128 lifetimeToken, uint128 lifetimeQuote) = locker.lifetimeAutoLpFees(address(second));
        assertEq(lifetimeToken, 1_000);
        assertEq(lifetimeQuote, 0);
        IHydropumpLocker.FeeRoute[] memory storedRoutes = locker.getFeeRoutes(address(second));
        assertEq(storedRoutes.length, 1);
        assertEq(storedRoutes[0].routeType, 1);
        assertEq(storedRoutes[0].bps, 1_000);
        assertEq(storedRoutes[0].strategy, stranger);
    }

    function test_AutoLpCannotExceedCreatorAllocation() public {
        MockERC20 second = new MockERC20("Auto", "AUTO");
        uint256[] memory autoIds = new uint256[](1);
        autoIds[0] = 88;
        IHydropumpLocker.FeeRoute[] memory routes = _autoLpRoutes(stranger, 7_501);
        vm.prank(launcher);
        vm.expectRevert(HydropumpLocker.InvalidFeeRouteAllocation.selector);
        locker.registerLaunchWithRoutes(
            address(second), address(quote), address(pool), creator, creatorRecipient, autoIds, routes
        );
    }

    function test_LockerRejectsUnsupportedAndDuplicateRoutes() public {
        MockERC20 second = new MockERC20("Auto", "AUTO");
        uint256[] memory autoIds = new uint256[](1);
        autoIds[0] = 88;
        IHydropumpLocker.FeeRoute[] memory routes = _autoLpRoutes(stranger, 1_000);
        routes[0].routeType = 5;

        vm.prank(launcher);
        vm.expectRevert(HydropumpLocker.UnsupportedFeeRoute.selector);
        locker.registerLaunchWithRoutes(
            address(second), address(quote), address(pool), creator, creatorRecipient, autoIds, routes
        );

        routes = new IHydropumpLocker.FeeRoute[](2);
        routes[0] = IHydropumpLocker.FeeRoute({routeType: 1, bps: 500, strategy: stranger});
        routes[1] = IHydropumpLocker.FeeRoute({routeType: 1, bps: 500, strategy: stranger});
        vm.prank(launcher);
        vm.expectRevert(HydropumpLocker.DuplicateFeeRoute.selector);
        locker.registerLaunchWithRoutes(
            address(second), address(quote), address(pool), creator, creatorRecipient, autoIds, routes
        );
    }

    function test_AutoLpAllocationSnapshotsProtocolShareAtLaunch() public {
        MockERC20 second = new MockERC20("Auto", "AUTO");
        uint256[] memory autoIds = new uint256[](1);
        autoIds[0] = 88;
        IHydropumpLocker.FeeRoute[] memory routes = _autoLpRoutes(stranger, 1_000);
        vm.prank(launcher);
        locker.registerLaunchWithRoutes(
            address(second), address(quote), address(pool), creator, creatorRecipient, autoIds, routes
        );

        vm.prank(owner);
        locker.setFeeSplit(5_000, 5_000);
        npm.setPair(address(second), address(quote));
        second.mint(NPM, 10_000);
        npm.setOwed(88, 10_000, 0);
        locker.collect(address(second), 1);

        assertEq(locker.creatorOwed(address(second), address(second)), 6_500);
        assertEq(locker.protocolOwed(address(second)), 2_500);
        assertEq(feeEscrow.claimable(locker.autoLpAccount(address(second)), address(second)), 1_000);
    }

    function test_LaunchCanCombineAutoLpAndStakingRewardsRoutes() public {
        MockERC20 second = new MockERC20("Routed", "ROUTE");
        address stakingStrategy = makeAddr("stakingStrategy");
        uint256[] memory routeIds = new uint256[](1);
        routeIds[0] = 89;
        IHydropumpLocker.FeeRoute[] memory routes = new IHydropumpLocker.FeeRoute[](2);
        routes[0] = IHydropumpLocker.FeeRoute({routeType: 1, bps: 1_000, strategy: stranger});
        routes[1] = IHydropumpLocker.FeeRoute({routeType: 2, bps: 2_000, strategy: stakingStrategy});

        vm.prank(launcher);
        locker.registerLaunchWithRoutes(
            address(second), address(quote), address(pool), creator, creatorRecipient, routeIds, routes
        );
        npm.setPair(address(second), address(quote));
        second.mint(NPM, 10_000);
        npm.setOwed(89, 10_000, 0);
        locker.collect(address(second), 1);

        assertEq(locker.creatorOwed(address(second), address(second)), 4_500);
        assertEq(locker.protocolOwed(address(second)), 2_500);
        assertEq(feeEscrow.claimable(locker.autoLpAccount(address(second)), address(second)), 1_000);
        assertEq(feeEscrow.claimable(locker.stakingRewardsAccount(address(second)), address(second)), 2_000);
        assertEq(feeEscrow.recipient(locker.stakingRewardsAccount(address(second))), stakingStrategy);
    }

    function test_LaunchCanAllocateCreatorShareToVeHydxIncentives() public {
        MockERC20 second = new MockERC20("Voter", "VOTE");
        uint256[] memory routeIds = new uint256[](1);
        routeIds[0] = 90;
        IHydropumpLocker.FeeRoute[] memory routes = new IHydropumpLocker.FeeRoute[](1);
        routes[0] = IHydropumpLocker.FeeRoute({routeType: 3, bps: 1_000, strategy: buyback});

        vm.prank(launcher);
        locker.registerLaunchWithRoutes(
            address(second), address(quote), address(pool), creator, creatorRecipient, routeIds, routes
        );
        npm.setPair(address(second), address(quote));
        second.mint(NPM, 10_000);
        quote.mint(NPM, 20_000);
        npm.setOwed(90, 10_000, 20_000);

        locker.collect(address(second), 1);

        assertEq(locker.creatorOwed(address(second), address(second)), 6_500);
        assertEq(locker.creatorOwed(address(second), address(quote)), 13_000);
        assertEq(locker.protocolOwed(address(second)), 2_500);
        assertEq(locker.protocolOwed(address(quote)), 5_000);
        assertEq(feeEscrow.claimable(locker.veHydxIncentivesAccount(address(second)), address(second)), 1_000);
        assertEq(feeEscrow.claimable(locker.veHydxIncentivesAccount(address(second)), address(quote)), 2_000);
        assertEq(feeEscrow.recipient(locker.veHydxIncentivesAccount(address(second))), buyback);
        (uint128 lifetimeToken, uint128 lifetimeQuote) = locker.lifetimeVeHydxIncentivesFees(address(second));
        assertEq(lifetimeToken, 1_000);
        assertEq(lifetimeQuote, 2_000);
    }

    function test_VeHydxIncentivesRouteMustUseProtocolBuyback() public {
        MockERC20 second = new MockERC20("Voter", "VOTE");
        uint256[] memory routeIds = new uint256[](1);
        routeIds[0] = 90;
        IHydropumpLocker.FeeRoute[] memory routes = new IHydropumpLocker.FeeRoute[](1);
        routes[0] = IHydropumpLocker.FeeRoute({routeType: 3, bps: 1_000, strategy: stranger});

        vm.prank(launcher);
        vm.expectRevert(HydropumpLocker.InvalidFeeRouteStrategy.selector);
        locker.registerLaunchWithRoutes(
            address(second), address(quote), address(pool), creator, creatorRecipient, routeIds, routes
        );
    }

    function test_LaunchCanAllocateCreatorShareToAnyDirectRecipient() public {
        MockERC20 second = new MockERC20("Direct", "DIRECT");
        address recipient = makeAddr("directRecipient");
        uint256[] memory routeIds = new uint256[](1);
        routeIds[0] = 91;
        IHydropumpLocker.FeeRoute[] memory routes = new IHydropumpLocker.FeeRoute[](1);
        routes[0] = IHydropumpLocker.FeeRoute({routeType: 4, bps: 1_000, strategy: recipient});

        vm.prank(launcher);
        locker.registerLaunchWithRoutes(
            address(second), address(quote), address(pool), creator, creatorRecipient, routeIds, routes
        );
        npm.setPair(address(second), address(quote));
        second.mint(NPM, 10_000);
        quote.mint(NPM, 20_000);
        npm.setOwed(91, 10_000, 20_000);

        locker.collect(address(second), 1);

        assertEq(locker.creatorOwed(address(second), address(second)), 6_500);
        assertEq(locker.creatorOwed(address(second), address(quote)), 13_000);
        assertEq(locker.protocolOwed(address(second)), 2_500);
        assertEq(locker.protocolOwed(address(quote)), 5_000);
        assertEq(feeEscrow.claimable(locker.directRecipientAccount(address(second)), address(second)), 1_000);
        assertEq(feeEscrow.claimable(locker.directRecipientAccount(address(second)), address(quote)), 2_000);
        assertEq(feeEscrow.recipient(locker.directRecipientAccount(address(second))), recipient);
        (uint128 lifetimeToken, uint128 lifetimeQuote) = locker.lifetimeDirectRecipientFees(address(second));
        assertEq(lifetimeToken, 1_000);
        assertEq(lifetimeQuote, 2_000);
    }

    function test_AutoLpRejectsAnInactivePosition() public {
        pool.setTick(250);
        npm.setPosition(1, 100, 200);
        vm.prank(owner);
        locker.setAutoLpStrategy(address(launchToken), stranger);

        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.PositionNotActive.selector);
        locker.compound(address(launchToken), 0, 0, 0, 0, 0, 250, 5);
    }

    function test_AutoLpRejectsUnapprovedCallerAndUnregisteredPosition() public {
        pool.setTick(150);
        npm.setPosition(1, 100, 200);

        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotAutoLpStrategy.selector);
        locker.compound(address(launchToken), 0, 0, 0, 0, 0, 150, 5);

        vm.prank(owner);
        locker.setAutoLpStrategy(address(launchToken), stranger);
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.InvalidPositionIndex.selector);
        locker.compound(address(launchToken), 5, 0, 0, 0, 0, 150, 5);
    }

    function test_AutoLpChecksExpectedTick() public {
        pool.setTick(150);
        npm.setPosition(1, 100, 200);
        vm.prank(owner);
        locker.setAutoLpStrategy(address(launchToken), stranger);

        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.TickDeviationExceeded.selector);
        locker.compound(address(launchToken), 0, 0, 0, 0, 0, 100, 5);
    }

    function test_CollectOnlyTouchesMaskedPositions() public {
        _fund(1, 1_100, 0);
        _fund(3, 2_200, 0);
        _fund(5, 4_400, 0);

        // bits 0 and 2 -> positions 1 and 3
        (uint256[] memory got0,) = locker.collect(address(launchToken), 0x05);

        assertEq(got0[0], 1_100);
        assertEq(got0[1], 0);
        assertEq(got0[2], 2_200);
        assertEq(got0[4], 0, "masked-out band must be untouched");
        assertEq(npm.owed0(5), 4_400, "band 5 fees still pending");
    }

    function test_CollectReportsPerBandAmountsForKeeperSizing() public {
        _fund(1, 1_000e18, 1e18);
        _fund(2, 5, 0);

        // What the keeper sees when it eth_calls collect with the full mask.
        (uint256[] memory f0, uint256[] memory f1) = locker.collect(address(launchToken), 0x1F);

        assertEq(f0[0], 1_000e18);
        assertEq(f1[0], 1e18);
        assertEq(f0[1], 5, "dust band reported so the keeper can skip it");
        assertEq(f0[2], 0);
    }

    function test_CollectIsPermissionlessButDestinationsAreFixed() public {
        _fund(1, 10_000, 0);

        vm.prank(stranger);
        locker.collect(address(launchToken), 0x01);

        assertEq(launchToken.balanceOf(stranger), 0, "caller must not receive anything");
        assertEq(locker.protocolOwed(address(launchToken)), 2_500);
        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 7_500);
    }

    function test_CollectRevertsOnUnknownLaunchOrEmptyMask() public {
        vm.expectRevert(HydropumpLocker.UnknownLaunch.selector);
        locker.collect(makeAddr("nope"), 0x01);

        vm.expectRevert(HydropumpLocker.EmptyMask.selector);
        locker.collect(address(launchToken), 0);
    }

    function test_FeeSplitIsAdjustable() public {
        vm.prank(owner);
        locker.setFeeSplit(5_000, 5_000);

        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 5_000);
        assertEq(locker.protocolOwed(address(launchToken)), 5_000);
    }

    function test_FeeSplitIsARatioNotAnAbsoluteRate() public {
        vm.prank(owner);
        locker.setFeeSplit(75, 25); // same ratio as 7500/2500

        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 7_500);
    }

    function test_FeeSplitIsOwnerOnlyAndRejectsZeroTotal() public {
        vm.prank(stranger);
        vm.expectRevert();
        locker.setFeeSplit(1, 1);

        vm.prank(owner);
        vm.expectRevert(HydropumpLocker.InvalidFeeSplit.selector);
        locker.setFeeSplit(0, 0);
    }

    function test_SplitChangeDoesNotTouchAlreadyCreditedFees() public {
        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);

        vm.prank(owner);
        locker.setFeeSplit(0, 1); // everything to the protocol from here on

        _fund(2, 10_000, 0);
        locker.collect(address(launchToken), 0x02);

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 7_500, "earlier credit stands");
        assertEq(locker.protocolOwed(address(launchToken)), 2_500 + 10_000);
    }

    function test_RoundingDustFavoursTheProtocol() public {
        _fund(1, 1, 0);

        locker.collect(address(launchToken), 0x01);

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 0);
        assertEq(locker.protocolOwed(address(launchToken)), 1);
    }

    // =============================
    //  CLAIMING
    // =============================

    function test_ClaimPaysCreatorRecipientAndZeroesOwed() public {
        _fund(1, 10_000, 10_000);
        locker.collect(address(launchToken), 0x01);

        locker.claim(address(launchToken));

        assertEq(launchToken.balanceOf(creatorRecipient), 7_500);
        assertEq(quote.balanceOf(creatorRecipient), 7_500);
        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 0);
        assertEq(locker.creatorOwed(address(launchToken), address(quote)), 0);
    }

    function test_ClaimIsPermissionless() public {
        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);

        vm.prank(stranger);
        locker.claim(address(launchToken));

        assertEq(launchToken.balanceOf(creatorRecipient), 7_500);
        assertEq(launchToken.balanceOf(stranger), 0);
    }

    /// Fees live in two places — credited on the locker, or still sitting in the positions — and a creator
    /// should not have to know which. `claim` sweeps first, so one call is always enough.
    function test_ClaimCollectsFirstSoUncollectedFeesNeedNoSeparateCall() public {
        _fund(1, 10_000, 10_000);
        _fund(2, 6_000, 2_000);

        // No collect() anywhere: everything is still owed by the position manager.
        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 0);
        assertEq(locker.creatorOwed(address(launchToken), address(quote)), 0);

        locker.claim(address(launchToken));

        assertEq(launchToken.balanceOf(creatorRecipient), 12_000, "75% of 16,000");
        assertEq(quote.balanceOf(creatorRecipient), 9_000, "75% of 12,000");
        assertEq(locker.protocolOwed(address(launchToken)), 4_000, "protocol share credited, not pushed");
        assertEq(locker.protocolOwed(address(quote)), 3_000);
    }

    /// The collect inside `claim` pays the protocol share inline, so a blocked or reverting fee recipient
    /// takes `claim` with it. That must fail loudly, not silently pay nothing.
    function test_ClaimRevertsRatherThanSilentlySkippingAFailedCollect() public {
        _fund(1, 10_000, 0);
        vm.mockCallRevert(NPM, abi.encodeWithSelector(INonfungiblePositionManager.collect.selector), "nope");

        vm.expectRevert();
        locker.claim(address(launchToken));
    }

    /// ...and the creator can still withdraw what is already credited while the owner repoints the recipient.
    function test_ClaimCreditedStillPaysOutWhenCollectIsBroken() public {
        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);
        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 7_500);

        vm.mockCallRevert(NPM, abi.encodeWithSelector(INonfungiblePositionManager.collect.selector), "nope");

        locker.claimCredited(address(launchToken));

        assertEq(launchToken.balanceOf(creatorRecipient), 7_500, "credited balance still reachable");
        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 0);
    }

    /// `claim` must have no cheap success path. eth_estimateGas binary-searches for the lowest gas that
    /// succeeds, so if starving the collect still produced a successful claim, wallets would settle on that
    /// limit and every claim would silently pay nothing.
    function test_ClaimHasNoCheapSuccessPathForGasEstimationToFind() public {
        _fund(1, 10_000, 10_000);

        // Enough gas to enter claim, nowhere near enough to collect five positions.
        (bool ok,) = address(locker).call{gas: 80_000}(abi.encodeCall(HydropumpLocker.claim, (address(launchToken))));
        assertFalse(ok, "a starved claim must revert, never succeed having paid nothing");

        locker.claim(address(launchToken));
        assertEq(launchToken.balanceOf(creatorRecipient), 7_500, "and with real gas it pays in full");
    }

    function test_ClaimTwiceIsANoop() public {
        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);
        locker.claim(address(launchToken));
        locker.claim(address(launchToken));

        assertEq(launchToken.balanceOf(creatorRecipient), 7_500);
    }

    // =============================
    //  LIFETIME TOTALS
    // =============================

    function test_LifetimeFeesAccumulateGrossAcrossCollects() public {
        _fund(1, 10_000, 4_000);
        locker.collect(address(launchToken), 0x01);

        (uint128 gross0, uint128 gross1) = locker.lifetimeFees(address(launchToken));
        assertEq(gross0, 10_000, "gross, before the split");
        assertEq(gross1, 4_000);

        _fund(2, 6_000, 1_000);
        locker.collect(address(launchToken), 0x02);

        (gross0, gross1) = locker.lifetimeFees(address(launchToken));
        assertEq(gross0, 16_000);
        assertEq(gross1, 5_000);
    }

    /// The whole point: claiming empties `creatorOwed`, so without this the number a launch has earned is
    /// gone from state entirely.
    function test_LifetimeFeesSurviveClaiming() public {
        _fund(1, 10_000, 0);
        locker.claim(address(launchToken));

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 0, "claim zeroed the balance");
        (uint128 gross0,) = locker.lifetimeFees(address(launchToken));
        assertEq(gross0, 10_000, "but the lifetime total remains");
    }

    function test_LifetimeFeesAreUntouchedBySweepingOrSplitChanges() public {
        _fund(1, 8_000, 0);
        locker.collect(address(launchToken), 0x01);

        address[] memory assets = new address[](1);
        assets[0] = address(launchToken);
        locker.sweepProtocol(assets);
        vm.prank(owner);
        locker.setFeeSplit(1, 1);

        (uint128 gross0,) = locker.lifetimeFees(address(launchToken));
        assertEq(gross0, 8_000, "gross is independent of how it was divided or where it went");
    }

    // =============================
    //  PROTOCOL SWEEP
    // =============================

    function test_SweepProtocolMovesCreditedSharesToTheRecipient() public {
        _fund(1, 10_000, 8_000);
        locker.collect(address(launchToken), 0x01);

        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (address(launchToken), address(quote));
        uint256[] memory swept = locker.sweepProtocol(assets);

        assertEq(swept[0], 2_500);
        assertEq(swept[1], 2_000);
        assertEq(launchToken.balanceOf(buyback), 2_500);
        assertEq(quote.balanceOf(buyback), 2_000);
        assertEq(locker.protocolOwed(address(launchToken)), 0);
        assertEq(locker.protocolOwed(address(quote)), 0);
    }

    /// The buyback job runs on the operator's schedule, so a sweep batches whatever has piled up since the
    /// last one, across every launch that produced that asset.
    function test_SweepProtocolPoolsAcrossLaunchesAndCycles() public {
        MockERC20 second = new MockERC20("Beta", "BETA");
        uint256[] memory otherIds = new uint256[](1);
        otherIds[0] = 99;
        vm.prank(launcher);
        locker.registerLaunch(address(second), address(quote), makeAddr("pool2"), creator, creatorRecipient, otherIds);
        npm.setPair(address(second), address(quote));

        _fund(1, 0, 4_000);
        locker.collect(address(launchToken), 0x01);
        quote.mint(NPM, 8_000);
        npm.setOwed(99, 0, 8_000);
        locker.collect(address(second), 0x01);

        assertEq(locker.protocolOwed(address(quote)), 3_000, "both launches pooled into one balance");

        address[] memory assets = new address[](1);
        assets[0] = address(quote);
        locker.sweepProtocol(assets);
        assertEq(quote.balanceOf(buyback), 3_000);

        // Next cycle accrues from zero again.
        quote.mint(NPM, 4_000);
        npm.setOwed(1, 0, 4_000);
        locker.collect(address(launchToken), 0x01);
        assertEq(locker.protocolOwed(address(quote)), 1_000);
    }

    function test_SweepProtocolIsPermissionlessAndSkipsEmptyAssets() public {
        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);

        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (address(quote), address(launchToken));

        vm.prank(stranger);
        uint256[] memory swept = locker.sweepProtocol(assets);

        assertEq(swept[0], 0, "nothing owed in quote");
        assertEq(swept[1], 2_500);
        assertEq(launchToken.balanceOf(stranger), 0, "caller gets nothing; destination is fixed");
    }

    /// The point of crediting rather than pushing: a protocol-side problem can never stop a creator being
    /// paid, and a creator-side one can never stop the buyback.
    function test_ProtocolAndCreatorPayoutsCannotBlockEachOther() public {
        _fund(1, 10_000, 0);

        // The buyback cannot receive this asset at all.
        launchToken.setBlocked(buyback, true);

        // A creator claims anyway — collect credits, and the only transfer is to their own recipient.
        locker.claim(address(launchToken));
        assertEq(launchToken.balanceOf(creatorRecipient), 7_500);

        // The protocol share is safe in the ledger until the recipient can take it.
        assertEq(locker.protocolOwed(address(launchToken)), 2_500);
        address[] memory assets = new address[](1);
        assets[0] = address(launchToken);
        vm.expectRevert();
        locker.sweepProtocol(assets);

        vm.prank(owner);
        locker.setProtocolFeeRecipient(makeAddr("rescue"));
        locker.sweepProtocol(assets);
        assertEq(launchToken.balanceOf(makeAddr("rescue")), 2_500);
    }

    function test_OnlyCurrentRecipientCanRedirect() public {
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotCreatorRecipient.selector);
        locker.setCreatorRecipient(address(launchToken), stranger);

        vm.prank(creatorRecipient);
        locker.setCreatorRecipient(address(launchToken), stranger);
        assertEq(locker.getLaunch(address(launchToken)).creatorRecipient, stranger);
    }

    function test_RedirectSendsLaterClaimsToTheNewRecipient() public {
        vm.prank(creatorRecipient);
        locker.setCreatorRecipient(address(launchToken), stranger);

        _fund(1, 10_000, 0);
        locker.collect(address(launchToken), 0x01);
        locker.claim(address(launchToken));

        assertEq(launchToken.balanceOf(stranger), 7_500);
        assertEq(launchToken.balanceOf(creatorRecipient), 0);
    }

    // =============================
    //  LOCK GUARANTEE + ADMIN
    // =============================

    function test_ExposesNoWayToMoveAPosition() public view {
        // The lock is structural: no transfer, withdraw, burn or decreaseLiquidity entry point exists.
        string[4] memory forbidden = [
            "safeTransferFrom(address,address,uint256)",
            "withdraw(address,address,uint256)",
            "burn(uint256)",
            "decreaseLiquidity(uint256,uint128,uint256,uint256,uint256)"
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            bytes4 selector = bytes4(keccak256(bytes(forbidden[i])));
            assertEq(_codeContains(address(locker), selector), false, forbidden[i]);
        }
    }

    function test_RejectsNFTsFromAnyoneButThePositionManager() public {
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotNFTPositionManager.selector);
        locker.onERC721Received(stranger, stranger, 1, "");

        vm.prank(NPM);
        assertEq(locker.onERC721Received(NPM, NPM, 1, ""), locker.onERC721Received.selector);
    }

    function test_AdminSettersAreOwnerOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        locker.setLauncher(stranger);
        vm.expectRevert();
        locker.setProtocolFeeRecipient(stranger);
        vm.stopPrank();

        vm.startPrank(owner);
        locker.setLauncher(stranger);
        locker.setProtocolFeeRecipient(stranger);
        vm.stopPrank();

        assertEq(locker.launcher(), stranger);
        assertEq(locker.protocolFeeRecipient(), stranger);
    }

    function test_ImplementationCannotBeInitialized() public {
        HydropumpLocker impl = new HydropumpLocker();
        vm.expectRevert();
        impl.initialize(owner, launcher, buyback, uint64(7_500), uint64(2_500));
    }

    function test_UpgradeIsOwnerOnly() public {
        address newImpl = address(new HydropumpLocker());

        vm.prank(stranger);
        vm.expectRevert();
        locker.upgradeToAndCall(newImpl, "");

        vm.prank(owner);
        locker.upgradeToAndCall(newImpl, "");
    }

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

    function _autoLpRoutes(address strategy, uint64 bps)
        internal
        pure
        returns (IHydropumpLocker.FeeRoute[] memory routes)
    {
        routes = new IHydropumpLocker.FeeRoute[](1);
        routes[0] = IHydropumpLocker.FeeRoute({routeType: 1, bps: bps, strategy: strategy});
    }
}
