// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HydropumpLocker} from "../contracts/HydropumpLocker.sol";
import {HydropumpAddresses} from "../contracts/libraries/HydropumpAddresses.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBribe} from "./mocks/MockBribe.sol";
import {MockDistributor} from "./mocks/MockDistributor.sol";
import {MockPositionManager} from "./mocks/MockPositionManager.sol";

contract HydropumpLockerTest is Test {
    address internal constant NPM = HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER;
    uint256 internal constant LP_TOKEN_ID = 4242;

    HydropumpLocker internal locker;
    MockPositionManager internal npm;
    MockERC20 internal launchToken;
    MockERC20 internal weth;

    address internal owner = makeAddr("owner");
    address internal feeClaimer = makeAddr("feeClaimer");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.etch(NPM, address(new MockPositionManager()).code);
        npm = MockPositionManager(NPM);

        launchToken = new MockERC20("Alpha", "ALPHA");
        weth = new MockERC20("Wrapped Ether", "WETH");
        npm.setPair(address(launchToken), address(weth));

        locker = new HydropumpLocker(owner);
        npm.deposit(address(locker), LP_TOKEN_ID, abi.encode(feeClaimer, address(launchToken)));
    }

    // =============================
    //  DEPOSIT
    // =============================

    function test_DepositInitializesLocker() public view {
        assertEq(locker.getNFTId(), LP_TOKEN_ID);
        assertEq(locker.getLaunchToken(), address(launchToken));
        assertEq(locker.feeClaimer(), feeClaimer);
        assertEq(locker.owner(), owner);
        assertTrue(locker.forwardWhitelist(HydropumpAddresses.OHYDX));
    }

    function test_RejectsNFTFromAnyoneButPositionManager() public {
        HydropumpLocker fresh = new HydropumpLocker(owner);
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotNFTPositionManager.selector);
        fresh.onERC721Received(stranger, stranger, 1, abi.encode(feeClaimer, address(launchToken)));
    }

    function test_RejectsSecondNFT() public {
        vm.expectRevert(HydropumpLocker.AlreadyInitialized.selector);
        npm.deposit(address(locker), LP_TOKEN_ID + 1, abi.encode(feeClaimer, address(launchToken)));
    }

    function test_RejectsZeroFeeClaimerOrLaunchToken() public {
        HydropumpLocker fresh = new HydropumpLocker(owner);
        vm.expectRevert(HydropumpLocker.InvalidFeeClaimer.selector);
        npm.deposit(address(fresh), 1, abi.encode(address(0), address(launchToken)));

        vm.expectRevert(HydropumpLocker.InvalidLaunchToken.selector);
        npm.deposit(address(fresh), 1, abi.encode(feeClaimer, address(0)));
    }

    function test_RevertsBeforeInitialization() public {
        HydropumpLocker fresh = new HydropumpLocker(owner);
        vm.prank(owner);
        vm.expectRevert(HydropumpLocker.NotInitialized.selector);
        fresh.collectFees();
    }

    // =============================
    //  FEES
    // =============================

    function _fundFees(uint256 amount0, uint256 amount1) internal {
        launchToken.mint(NPM, amount0);
        weth.mint(NPM, amount1);
        npm.setOwed(amount0, amount1);
    }

    function test_CollectFeesSplitsHalfToClaimerHalfToSavings() public {
        _fundFees(100e18, 10e18);

        vm.prank(feeClaimer);
        (uint256 toClaimer0, uint256 toClaimer1) = locker.collectFees();

        assertEq(toClaimer0, 50e18);
        assertEq(toClaimer1, 5e18);
        assertEq(launchToken.balanceOf(feeClaimer), 50e18);
        assertEq(weth.balanceOf(feeClaimer), 5e18);
        assertEq(locker.getSavings(address(launchToken)), 50e18);
        assertEq(locker.getSavings(address(weth)), 5e18);
    }

    function test_CollectFeesRoundsOddDustToSavings() public {
        _fundFees(3, 0);

        vm.prank(owner);
        (uint256 toClaimer0,) = locker.collectFees();

        assertEq(toClaimer0, 1);
        assertEq(locker.getSavings(address(launchToken)), 2);
    }

    function test_CollectFeesOnlyFeeClaimerOrOwner() public {
        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotFeeClaimerOrOwner.selector);
        locker.collectFees();
    }

    // =============================
    //  FEE CLAIMER
    // =============================

    function test_FeeClaimerCanRotateItself() public {
        vm.prank(feeClaimer);
        locker.setFeeClaimer(stranger);
        assertEq(locker.feeClaimer(), stranger);
    }

    function test_SetFeeClaimerRejectsZeroAndStrangers() public {
        vm.prank(owner);
        vm.expectRevert(HydropumpLocker.InvalidFeeClaimerAddress.selector);
        locker.setFeeClaimer(address(0));

        vm.prank(stranger);
        vm.expectRevert(HydropumpLocker.NotFeeClaimerOrOwner.selector);
        locker.setFeeClaimer(stranger);
    }

    // =============================
    //  BRIBES
    // =============================

    function test_PlaceBribeSpendsSavings() public {
        _fundFees(100e18, 0);
        vm.prank(feeClaimer);
        locker.collectFees();

        MockBribe bribe = new MockBribe();
        vm.prank(owner);
        locker.setGaugeBribe(address(bribe));

        vm.prank(feeClaimer);
        locker.placeBribe(address(launchToken), 20e18);

        assertEq(bribe.received(address(launchToken)), 20e18);
        assertEq(launchToken.balanceOf(address(bribe)), 20e18);
        assertEq(locker.getSavings(address(launchToken)), 30e18);
    }

    function test_PlaceBribeRequiresGaugeAndSavings() public {
        vm.prank(feeClaimer);
        vm.expectRevert(HydropumpLocker.GaugeBribeNotSet.selector);
        locker.placeBribe(address(launchToken), 1);

        MockBribe bribe = new MockBribe();
        vm.prank(owner);
        locker.setGaugeBribe(address(bribe));

        vm.prank(feeClaimer);
        vm.expectRevert(HydropumpLocker.InsufficientSavings.selector);
        locker.placeBribe(address(launchToken), 1);
    }

    function test_SetGaugeBribeIsOwnerOnly() public {
        vm.prank(feeClaimer);
        vm.expectRevert(HydropumpLocker.NotOwner.selector);
        locker.setGaugeBribe(address(1));
    }

    // =============================
    //  CLAIM AND FORWARD
    // =============================

    function test_ClaimAndForwardSendsDeltaToFeeClaimer() public {
        MockERC20 reward = new MockERC20("Reward", "RWD");
        MockDistributor distributor = new MockDistributor();

        // Pre-existing balance must stay put; only the claimed delta is forwarded
        reward.mint(address(locker), 1e18);

        vm.prank(owner);
        locker.setForwardWhitelist(address(reward), true);

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        address[] memory tokens = new address[](1);
        targets[0] = address(distributor);
        data[0] = abi.encodeCall(MockDistributor.claim, (address(reward), address(locker), 7e18));
        tokens[0] = address(reward);

        vm.prank(feeClaimer);
        locker.claimAndForward(targets, data, tokens);

        assertEq(reward.balanceOf(feeClaimer), 7e18);
        assertEq(reward.balanceOf(address(locker)), 1e18);
    }

    function test_ClaimAndForwardEnforcesWhitelistLengthsAndSuccess() public {
        MockERC20 reward = new MockERC20("Reward", "RWD");
        MockDistributor distributor = new MockDistributor();

        address[] memory targets = new address[](1);
        bytes[] memory data = new bytes[](1);
        address[] memory tokens = new address[](1);
        targets[0] = address(distributor);
        data[0] = abi.encodeCall(MockDistributor.claim, (address(reward), address(locker), 1e18));
        tokens[0] = address(reward);

        vm.prank(feeClaimer);
        vm.expectRevert(HydropumpLocker.TokenNotWhitelisted.selector);
        locker.claimAndForward(targets, data, tokens);

        vm.prank(owner);
        locker.setForwardWhitelist(address(reward), true);

        vm.prank(feeClaimer);
        vm.expectRevert(HydropumpLocker.InvalidLengths.selector);
        locker.claimAndForward(targets, new bytes[](2), tokens);

        data[0] = abi.encodeCall(MockDistributor.fail, ());
        vm.prank(feeClaimer);
        vm.expectRevert(HydropumpLocker.DistributorCallFailed.selector);
        locker.claimAndForward(targets, data, tokens);
    }

    // =============================
    //  ADMIN
    // =============================

    function test_WithdrawDrawsDownSavings() public {
        _fundFees(0, 8e18);
        vm.prank(feeClaimer);
        locker.collectFees();

        vm.prank(owner);
        locker.withdraw(address(weth), stranger, 3e18);

        assertEq(weth.balanceOf(stranger), 3e18);
        assertEq(locker.getSavings(address(weth)), 1e18);

        vm.prank(owner);
        vm.expectRevert(HydropumpLocker.InsufficientSavings.selector);
        locker.withdraw(address(weth), stranger, 2e18);
    }

    function test_EmergencyWithdrawIgnoresSavingsAccounting() public {
        weth.mint(address(locker), 5e18);

        vm.prank(owner);
        locker.emergencyWithdraw(address(weth), stranger, 5e18);

        assertEq(weth.balanceOf(stranger), 5e18);
    }

    function test_AdminFunctionsAreOwnerOnly() public {
        vm.startPrank(feeClaimer);
        vm.expectRevert(HydropumpLocker.NotOwner.selector);
        locker.withdraw(address(weth), feeClaimer, 0);
        vm.expectRevert(HydropumpLocker.NotOwner.selector);
        locker.emergencyWithdraw(address(weth), feeClaimer, 0);
        vm.expectRevert(HydropumpLocker.NotOwner.selector);
        locker.setForwardWhitelist(address(weth), true);
        vm.expectRevert(HydropumpLocker.NotOwner.selector);
        locker.setOwner(feeClaimer);
        vm.stopPrank();
    }

    function test_WithdrawRejectsZeroRecipient() public {
        vm.startPrank(owner);
        vm.expectRevert(HydropumpLocker.InvalidRecipient.selector);
        locker.withdraw(address(weth), address(0), 0);
        vm.expectRevert(HydropumpLocker.InvalidRecipient.selector);
        locker.emergencyWithdraw(address(weth), address(0), 0);
        vm.stopPrank();
    }

    function test_OwnerCanHandOff() public {
        vm.prank(owner);
        locker.setOwner(stranger);
        assertEq(locker.owner(), stranger);
    }
}
