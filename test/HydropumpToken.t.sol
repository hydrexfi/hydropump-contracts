// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HydropumpToken} from "../contracts/HydropumpToken.sol";

contract HydropumpTokenTest is Test {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _single(address to, uint256 amount) internal pure returns (address[] memory r, uint256[] memory a) {
        r = new address[](1);
        a = new uint256[](1);
        r[0] = to;
        a[0] = amount;
    }

    function test_MintsToEveryRecipient() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        (recipients[0], amounts[0]) = (alice, 100e18);
        (recipients[1], amounts[1]) = (bob, 1e18);

        HydropumpToken token = new HydropumpToken("Alpha", "ALPHA", recipients, amounts);

        assertEq(token.name(), "Alpha");
        assertEq(token.symbol(), "ALPHA");
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 1e18);
        assertEq(token.totalSupply(), 101e18);
    }

    function test_RevertsOnLengthMismatch() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = alice;
        recipients[1] = bob;
        amounts[0] = 1e18;

        vm.expectRevert("Length mismatch");
        new HydropumpToken("Alpha", "ALPHA", recipients, amounts);
    }

    function test_RevertsOnEmptyRecipients() public {
        vm.expectRevert("Empty arrays");
        new HydropumpToken("Alpha", "ALPHA", new address[](0), new uint256[](0));
    }

    function test_RevertsOnZeroRecipientOrAmount() public {
        (address[] memory r, uint256[] memory a) = _single(address(0), 1e18);
        vm.expectRevert("Invalid recipient");
        new HydropumpToken("Alpha", "ALPHA", r, a);

        (r, a) = _single(alice, 0);
        vm.expectRevert("Invalid amount");
        new HydropumpToken("Alpha", "ALPHA", r, a);
    }

    function test_IsBurnable() public {
        (address[] memory r, uint256[] memory a) = _single(alice, 10e18);
        HydropumpToken token = new HydropumpToken("Alpha", "ALPHA", r, a);

        vm.prank(alice);
        token.burn(4e18);

        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.totalSupply(), 6e18);
    }

    function test_SupportsPermit() public {
        (uint256 ownerKey, address owner) = (0xA11CE, vm.addr(0xA11CE));
        (address[] memory r, uint256[] memory a) = _single(owner, 10e18);
        HydropumpToken token = new HydropumpToken("Alpha", "ALPHA", r, a);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                bob,
                5e18,
                token.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r_, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, bob, 5e18, deadline, v, r_, s);

        assertEq(token.allowance(owner, bob), 5e18);
    }
}
