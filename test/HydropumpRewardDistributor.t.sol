// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpRewardDistributor} from "../contracts/HydropumpRewardDistributor.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The reward ledger: who may write it, who gets paid, and what an owner may take back.
contract HydropumpRewardDistributorTest is Test {
    HydropumpRewardDistributor internal distributor;
    MockERC20 internal hydx;
    MockERC20 internal other;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        distributor = new HydropumpRewardDistributor(owner, operator);
        hydx = new MockERC20("Hydrex", "HYDX");
        other = new MockERC20("Other", "OTHER");

        hydx.mint(operator, 1_000e18);
        other.mint(operator, 1_000e18);
        vm.startPrank(operator);
        hydx.approve(address(distributor), type(uint256).max);
        other.approve(address(distributor), type(uint256).max);
        vm.stopPrank();
    }

    function _allocate(address token, address a, uint256 amountA, address b, uint256 amountB) internal {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (recipients[0], recipients[1]) = (a, b);
        (amounts[0], amounts[1]) = (amountA, amountB);

        vm.prank(operator);
        distributor.allocate(token, recipients, amounts);
    }

    function _one(address token, address to, uint256 amount) internal {
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (recipients[0], amounts[0]) = (to, amount);

        vm.prank(operator);
        distributor.allocate(token, recipients, amounts);
    }

    // =============================
    //  ALLOCATE
    // =============================

    /// Funding and crediting are the same call, so the ledger can never promise more than is held.
    function test_AllocatePullsExactlyWhatItCredits() public {
        _allocate(address(hydx), alice, 30e18, bob, 70e18);

        assertEq(hydx.balanceOf(address(distributor)), 100e18, "the contract holds what it owes");
        assertEq(hydx.balanceOf(operator), 900e18);
        assertEq(distributor.claimable(alice, address(hydx)), 30e18);
        assertEq(distributor.claimable(bob, address(hydx)), 70e18);
        assertEq(distributor.totalOwed(address(hydx)), 100e18);
    }

    /// A weekly run is just another call, so allocations add rather than replace.
    function test_AllocationsAccumulate() public {
        _one(address(hydx), alice, 10e18);
        _one(address(hydx), alice, 15e18);

        assertEq(distributor.claimable(alice, address(hydx)), 25e18);
        assertEq(distributor.totalOwed(address(hydx)), 25e18);
    }

    function test_AllocateIsOperatorGated() public {
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (recipients[0], amounts[0]) = (alice, 1e18);

        vm.prank(stranger);
        vm.expectRevert(HydropumpRewardDistributor.NotOperator.selector);
        distributor.allocate(address(hydx), recipients, amounts);
    }

    function test_AllocateRejectsMismatchedAndEmptyInput() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        (recipients[0], recipients[1]) = (alice, bob);
        amounts[0] = 1e18;

        vm.startPrank(operator);
        vm.expectRevert(HydropumpRewardDistributor.LengthMismatch.selector);
        distributor.allocate(address(hydx), recipients, amounts);

        address[] memory none = new address[](0);
        uint256[] memory noAmounts = new uint256[](0);
        vm.expectRevert(HydropumpRewardDistributor.NothingAllocated.selector);
        distributor.allocate(address(hydx), none, noAmounts);
        vm.stopPrank();
    }

    /// Zero entries are skipped rather than rejected, so a split with a zero row still goes through.
    function test_ZeroAmountsAreSkipped() public {
        _allocate(address(hydx), alice, 0, bob, 5e18);

        assertEq(distributor.claimable(alice, address(hydx)), 0);
        assertEq(distributor.claimable(bob, address(hydx)), 5e18);
        assertEq(hydx.balanceOf(address(distributor)), 5e18, "only the non-zero row was pulled");
    }

    // =============================
    //  CLAIM
    // =============================

    /// Permissionless, and always paid to the recipient — so the operator can push without anyone
    /// having to come and collect, and pushing costs nobody their reward.
    function test_AnyoneCanClaimButOnlyTheRecipientIsPaid() public {
        _allocate(address(hydx), alice, 30e18, bob, 70e18);

        vm.prank(stranger);
        uint256 paid = distributor.claim(alice, address(hydx));

        assertEq(paid, 30e18);
        assertEq(hydx.balanceOf(alice), 30e18);
        assertEq(hydx.balanceOf(stranger), 0, "the caller takes nothing");
        assertEq(distributor.claimable(alice, address(hydx)), 0);
        assertEq(distributor.totalOwed(address(hydx)), 70e18, "and bob's is untouched");
    }

    function test_ClaimingTwiceIsANoop() public {
        _one(address(hydx), alice, 10e18);
        distributor.claim(alice, address(hydx));
        assertEq(distributor.claim(alice, address(hydx)), 0);
        assertEq(hydx.balanceOf(alice), 10e18);
    }

    function test_LifetimeSurvivesAClaim() public {
        _one(address(hydx), alice, 10e18);
        distributor.claim(alice, address(hydx));
        _one(address(hydx), alice, 4e18);
        distributor.claim(alice, address(hydx));

        assertEq(distributor.claimable(alice, address(hydx)), 0);
        assertEq(distributor.lifetimeClaimed(alice, address(hydx)), 14e18);
    }

    function test_ClaimManyCoversSeveralTokens() public {
        _one(address(hydx), alice, 10e18);
        _one(address(other), alice, 6e18);

        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(hydx), address(other));
        uint256[] memory amounts = distributor.claimMany(alice, tokens);

        assertEq(amounts[0], 10e18);
        assertEq(amounts[1], 6e18);
        assertEq(hydx.balanceOf(alice), 10e18);
        assertEq(other.balanceOf(alice), 6e18);
    }

    /// One token's ledger is not another's.
    function test_TokensAreTrackedSeparately() public {
        _one(address(hydx), alice, 10e18);
        _one(address(other), alice, 6e18);

        distributor.claim(alice, address(hydx));

        assertEq(distributor.claimable(alice, address(other)), 6e18, "the other token is untouched");
        assertEq(distributor.totalOwed(address(other)), 6e18);
    }

    // =============================
    //  SWEEP
    // =============================

    /// The operator can only ever give. Everything that takes is the owner's.
    function test_OperatorCannotTakeAnything() public {
        _one(address(hydx), alice, 10e18);

        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (recipients[0], amounts[0]) = (alice, 0);

        vm.startPrank(operator);
        vm.expectRevert();
        distributor.setAllocation(address(hydx), recipients, amounts);
        vm.expectRevert();
        distributor.emergencyWithdraw(address(hydx), operator, 1e18);
        vm.stopPrank();

        assertEq(distributor.claimable(alice, address(hydx)), 10e18, "untouched");
    }

    /// Sets rather than adds, because the reason to reach for it is a number that is wrong.
    function test_OwnerCanRewriteAllocationsInEitherDirection() public {
        _allocate(address(hydx), alice, 30e18, bob, 70e18);

        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (recipients[0], recipients[1]) = (alice, bob);
        (amounts[0], amounts[1]) = (0, 90e18); // alice clawed back, bob raised

        vm.prank(owner);
        distributor.setAllocation(address(hydx), recipients, amounts);

        assertEq(distributor.claimable(alice, address(hydx)), 0);
        assertEq(distributor.claimable(bob, address(hydx)), 90e18);
        assertEq(distributor.totalOwed(address(hydx)), 90e18, "the ledger tracks the delta, not the sum");
        assertEq(hydx.balanceOf(address(distributor)), 100e18, "and no tokens moved");
    }

    /// A cancelled allocation cannot be claimed, and what it freed is withdrawable.
    function test_ClawbackThenWithdraw() public {
        _allocate(address(hydx), alice, 30e18, bob, 70e18);

        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (recipients[0], amounts[0]) = (alice, 0);

        vm.startPrank(owner);
        distributor.setAllocation(address(hydx), recipients, amounts);
        distributor.emergencyWithdraw(address(hydx), owner, 30e18);
        vm.stopPrank();

        assertEq(hydx.balanceOf(owner), 30e18);
        assertEq(distributor.claim(alice, address(hydx)), 0, "nothing left for alice");
        assertEq(distributor.claim(bob, address(hydx)), 70e18, "and bob is still whole");
    }

    /// Unbounded on purpose: a hatch that respects the ledger is no use when the ledger is the problem.
    function test_EmergencyWithdrawIgnoresTheLedger() public {
        _one(address(hydx), alice, 10e18);

        vm.prank(owner);
        distributor.emergencyWithdraw(address(hydx), owner, 10e18);

        assertEq(hydx.balanceOf(owner), 10e18);
        assertEq(distributor.claimable(alice, address(hydx)), 10e18, "the ledger still says so");

        // And the claim fails on the transfer rather than half-paying.
        vm.expectRevert();
        distributor.claim(alice, address(hydx));
    }

    function test_OwnerPowersAreOwnerOnly() public {
        hydx.mint(address(distributor), 1e18);

        vm.prank(stranger);
        vm.expectRevert();
        distributor.emergencyWithdraw(address(hydx), stranger, 1e18);
    }

    function test_OperatorIsOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert();
        distributor.setOperator(stranger);

        vm.prank(owner);
        distributor.setOperator(stranger);
        assertEq(distributor.operator(), stranger);
    }
}
