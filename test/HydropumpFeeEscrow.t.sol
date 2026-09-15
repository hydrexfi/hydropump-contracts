// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {HydropumpFeeEscrow} from "../contracts/HydropumpFeeEscrow.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract HydropumpFeeEscrowTest is Test {
    HydropumpFeeEscrow internal escrow;
    MockERC20 internal asset;

    address internal owner = makeAddr("owner");
    address internal depositor = makeAddr("depositor");
    address internal recipient = makeAddr("recipient");
    address internal stranger = makeAddr("stranger");
    bytes32 internal account = keccak256("launch/creator");

    function setUp() public {
        escrow = new HydropumpFeeEscrow(owner, depositor);
        asset = new MockERC20("Asset", "ASSET");
        asset.mint(depositor, 10_000);
        vm.prank(depositor);
        asset.approve(address(escrow), type(uint256).max);
    }

    function test_DepositorCreditsAnAccount() public {
        vm.prank(depositor);
        escrow.credit(account, recipient, address(asset), 4_000);

        assertEq(escrow.recipient(account), recipient);
        assertEq(escrow.claimable(account, address(asset)), 4_000);
        assertEq(asset.balanceOf(address(escrow)), 4_000);
    }

    function test_OnlyApprovedDepositorCanCredit() public {
        vm.prank(stranger);
        vm.expectRevert(HydropumpFeeEscrow.NotDepositor.selector);
        escrow.credit(account, recipient, address(asset), 1);
    }

    function test_AccountRecipientCannotChangeDuringCredit() public {
        vm.prank(depositor);
        escrow.credit(account, recipient, address(asset), 1_000);

        vm.prank(depositor);
        vm.expectRevert(HydropumpFeeEscrow.RecipientMismatch.selector);
        escrow.credit(account, stranger, address(asset), 1_000);
    }

    function test_ClaimIsPermissionlessButPaysFixedRecipient() public {
        vm.prank(depositor);
        escrow.credit(account, recipient, address(asset), 4_000);

        vm.prank(stranger);
        uint256 amount = escrow.claim(account, address(asset));

        assertEq(amount, 4_000);
        assertEq(asset.balanceOf(recipient), 4_000);
        assertEq(asset.balanceOf(stranger), 0);
        assertEq(escrow.claimable(account, address(asset)), 0);
    }

    function test_DepositorCanRedirectAccountWithoutMovingItsBalance() public {
        vm.prank(depositor);
        escrow.credit(account, recipient, address(asset), 4_000);

        vm.prank(depositor);
        escrow.setRecipient(account, stranger);
        escrow.claim(account, address(asset));

        assertEq(asset.balanceOf(stranger), 4_000);
        assertEq(asset.balanceOf(recipient), 0);
    }

    function test_EmptyClaimIsANoop() public {
        assertEq(escrow.claim(account, address(asset)), 0);
    }

    function test_OwnerControlsDepositors() public {
        vm.prank(owner);
        escrow.setDepositor(stranger, true);
        assertTrue(escrow.depositors(stranger));

        vm.prank(stranger);
        escrow.setRecipient(account, recipient);
        assertEq(escrow.recipient(account), recipient);
    }

    function test_AnotherDepositorCannotHijackAnExistingAccount() public {
        vm.prank(depositor);
        escrow.credit(account, recipient, address(asset), 1_000);

        vm.prank(owner);
        escrow.setDepositor(stranger, true);

        vm.prank(stranger);
        vm.expectRevert(HydropumpFeeEscrow.NotAccountDepositor.selector);
        escrow.setRecipient(account, stranger);
    }
}
