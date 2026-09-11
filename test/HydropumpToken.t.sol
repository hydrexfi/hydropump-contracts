// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HydropumpToken} from "../contracts/HydropumpToken.sol";

/// @dev Stands in for the launcher: exposes `pendingToken()` for the token's argument-less constructor.
contract TokenDeployer {
    string public pendingName;
    string public pendingSymbol;
    uint256 public pendingSupply;
    address public pendingRecipient;

    function pendingToken() external view returns (string memory, string memory, uint256, address) {
        return (pendingName, pendingSymbol, pendingSupply, pendingRecipient);
    }

    function deploy(string memory name_, string memory symbol_, uint256 supply, address to)
        external
        returns (HydropumpToken)
    {
        (pendingName, pendingSymbol, pendingSupply, pendingRecipient) = (name_, symbol_, supply, to);
        return new HydropumpToken();
    }

    function deployAt(string memory name_, string memory symbol_, uint256 supply, address to, bytes32 salt)
        external
        returns (HydropumpToken)
    {
        (pendingName, pendingSymbol, pendingSupply, pendingRecipient) = (name_, symbol_, supply, to);
        return new HydropumpToken{salt: salt}();
    }
}

contract HydropumpTokenTest is Test {
    TokenDeployer internal deployer;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        deployer = new TokenDeployer();
    }

    function test_ConstructorReadsParamsBackFromDeployer() public {
        HydropumpToken token = deployer.deploy("Alpha", "ALPHA", 10_000_000_000e18, alice);

        assertEq(token.name(), "Alpha");
        assertEq(token.symbol(), "ALPHA");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 10_000_000_000e18);
        assertEq(token.balanceOf(alice), 10_000_000_000e18);
    }

    function test_IsNotAProxy() public {
        HydropumpToken token = deployer.deploy("Alpha", "ALPHA", 1e18, alice);

        // An EIP-1167 clone is 45 bytes and starts 0x363d3d37. Full bytecode is neither.
        bytes memory code = address(token).code;
        assertGt(code.length, 1_000, "must be full bytecode, not a minimal proxy");
        assertTrue(
            !(code[0] == hex"36" && code[1] == hex"3d" && code[2] == hex"3d" && code[3] == hex"37"),
            "must not be an EIP-1167 clone"
        );

        // No ERC1967 implementation or admin slot.
        assertEq(vm.load(address(token), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc), 0);
        assertEq(vm.load(address(token), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103), 0);
    }

    function test_HasNoOwnerMintOrUpgradePath() public {
        HydropumpToken token = deployer.deploy("Alpha", "ALPHA", 1e18, alice);

        string[5] memory forbidden = [
            "owner()",
            "mint(address,uint256)",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(string,string,uint256,address)"
        ];
        for (uint256 i = 0; i < forbidden.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(forbidden[i]));
            assertFalse(ok, forbidden[i]);
        }
        assertEq(token.totalSupply(), 1e18);
    }

    function test_InitCodeHashIsConstantAcrossDifferentParams() public {
        // This is what makes salt mining possible before the user picks a name.
        bytes32 hashA = keccak256(type(HydropumpToken).creationCode);

        deployer.deploy("Alpha", "ALPHA", 1e18, alice);
        deployer.deploy("A Very Much Longer Token Name", "LONGER", 99e18, bob);

        assertEq(keccak256(type(HydropumpToken).creationCode), hashA);
    }

    function test_Create2AddressMatchesThePrediction() public {
        bytes32 salt = keccak256("salt");
        address predicted =
            vm.computeCreate2Address(salt, keccak256(type(HydropumpToken).creationCode), address(deployer));

        HydropumpToken token = deployer.deployAt("Alpha", "ALPHA", 1e18, alice, salt);

        assertEq(address(token), predicted);
    }

    function test_IsBurnable() public {
        HydropumpToken token = deployer.deploy("Alpha", "ALPHA", 10e18, alice);

        vm.prank(alice);
        token.burn(4e18);

        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.totalSupply(), 6e18);
    }

    function test_SupportsPermit() public {
        (uint256 ownerKey, address owner) = (0xA11CE, vm.addr(0xA11CE));
        HydropumpToken token = deployer.deploy("Alpha", "ALPHA", 10e18, owner);

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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

        token.permit(owner, bob, 5e18, deadline, v, r, s);

        assertEq(token.allowance(owner, bob), 5e18);
    }

    function test_PermitDomainUsesTheRealName() public {
        HydropumpToken token = deployer.deploy("Alpha", "ALPHA", 1e18, alice);
        (, string memory name,,,,,) = token.eip712Domain();
        assertEq(name, "Alpha", "domain separator must be built from the actual name");
    }
}
