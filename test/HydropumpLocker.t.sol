// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLocker} from "../contracts/HydropumpLocker.sol";
import {HydropumpAddresses} from "../contracts/libraries/HydropumpAddresses.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

contract HydropumpLockerTest is Test {
    address internal constant NPM = HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER;

    HydropumpLocker internal locker;
    MockPositionManager internal npm;
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

        launchToken = new MockERC20("Alpha", "ALPHA");
        quote = new MockERC20("Wrapped Ether", "WETH");
        npm.setPair(address(launchToken), address(quote));

        locker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(HydropumpLocker.initialize, (owner, launcher, buyback, uint64(8_000), uint64(3_000)))
                )
            )
        );

        vm.prank(launcher);
        locker.registerLaunch(address(launchToken), address(quote), makeAddr("pool"), creator, creatorRecipient, ids);
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
        _fund(1, 11_000, 22_000);
        locker.collect(address(launchToken), 0x01);

        HydropumpLocker.ClaimableFees memory fees = locker.claimable(address(launchToken));

        assertEq(fees.launchToken, address(launchToken));
        assertEq(fees.quoteToken, address(quote));
        assertEq(fees.launchTokenAmount, 8_000);
        assertEq(fees.quoteAmount, 16_000);
    }

    function test_ClaimableGoesToZeroAfterClaim() public {
        _fund(1, 11_000, 0);
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

        _fund(1, 11_000, 0);
        locker.collect(address(launchToken), 0x01);

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(launchToken), address(second));
        HydropumpLocker.ClaimableFees[] memory fees = locker.claimableMany(tokens);

        assertEq(fees.length, 2);
        assertEq(fees[0].launchTokenAmount, 8_000);
        assertEq(fees[1].launchTokenAmount, 0);
        assertEq(fees[1].quoteToken, address(quote));
    }

    function test_TotalOwedIncludesFeesStillInThePositions() public {
        _fund(1, 11_000, 0); // collected and credited
        locker.collect(address(launchToken), 0x01);
        _fund(3, 22_000, 11_000); // still sitting in a position

        assertEq(locker.claimable(address(launchToken)).launchTokenAmount, 8_000, "claimable sees credited only");

        HydropumpLocker.ClaimableFees memory owed = locker.totalOwed(address(launchToken));

        assertEq(owed.launchTokenAmount, 8_000 + 16_000);
        assertEq(owed.quoteAmount, 8_000);
    }

    function test_TotalOwedSentAsATransactionIsJustACollect() public {
        _fund(2, 11_000, 0);

        locker.totalOwed(address(launchToken));

        // Fees were collected and split as normal, nothing stranded.
        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 8_000);
        assertEq(launchToken.balanceOf(buyback), 3_000);
    }

    function test_CollectSplits0800Creator0300Protocol() public {
        // 11000 wei splits exactly along the 0.8% / 0.3% shares of the 1.1% pool fee
        _fund(1, 11_000, 22_000);

        locker.collect(address(launchToken), 0x01);

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 8_000);
        assertEq(locker.creatorOwed(address(launchToken), address(quote)), 16_000);
        assertEq(launchToken.balanceOf(buyback), 3_000);
        assertEq(quote.balanceOf(buyback), 6_000);
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
        _fund(1, 11_000, 0);

        vm.prank(stranger);
        locker.collect(address(launchToken), 0x01);

        assertEq(launchToken.balanceOf(stranger), 0, "caller must not receive anything");
        assertEq(launchToken.balanceOf(buyback), 3_000);
        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 8_000);
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
        assertEq(launchToken.balanceOf(buyback), 5_000);
    }

    function test_FeeSplitIsARatioNotAnAbsoluteRate() public {
        vm.prank(owner);
        locker.setFeeSplit(800, 300); // same ratio as 8000/3000

        _fund(1, 11_000, 0);
        locker.collect(address(launchToken), 0x01);

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 8_000);
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
        _fund(1, 11_000, 0);
        locker.collect(address(launchToken), 0x01);

        vm.prank(owner);
        locker.setFeeSplit(0, 1); // everything to the protocol from here on

        _fund(2, 11_000, 0);
        locker.collect(address(launchToken), 0x02);

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 8_000, "earlier credit stands");
        assertEq(launchToken.balanceOf(buyback), 3_000 + 11_000);
    }

    function test_RoundingDustFavoursTheProtocol() public {
        _fund(1, 1, 0);

        locker.collect(address(launchToken), 0x01);

        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 0);
        assertEq(launchToken.balanceOf(buyback), 1);
    }

    // =============================
    //  CLAIMING
    // =============================

    function test_ClaimPaysCreatorRecipientAndZeroesOwed() public {
        _fund(1, 11_000, 11_000);
        locker.collect(address(launchToken), 0x01);

        locker.claim(address(launchToken));

        assertEq(launchToken.balanceOf(creatorRecipient), 8_000);
        assertEq(quote.balanceOf(creatorRecipient), 8_000);
        assertEq(locker.creatorOwed(address(launchToken), address(launchToken)), 0);
        assertEq(locker.creatorOwed(address(launchToken), address(quote)), 0);
    }

    function test_ClaimIsPermissionless() public {
        _fund(1, 11_000, 0);
        locker.collect(address(launchToken), 0x01);

        vm.prank(stranger);
        locker.claim(address(launchToken));

        assertEq(launchToken.balanceOf(creatorRecipient), 8_000);
        assertEq(launchToken.balanceOf(stranger), 0);
    }

    function test_ClaimTwiceIsANoop() public {
        _fund(1, 11_000, 0);
        locker.collect(address(launchToken), 0x01);
        locker.claim(address(launchToken));
        locker.claim(address(launchToken));

        assertEq(launchToken.balanceOf(creatorRecipient), 8_000);
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

        _fund(1, 11_000, 0);
        locker.collect(address(launchToken), 0x01);
        locker.claim(address(launchToken));

        assertEq(launchToken.balanceOf(stranger), 8_000);
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
}
