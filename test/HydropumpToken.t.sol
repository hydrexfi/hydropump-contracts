// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HydropumpToken} from "../contracts/core/HydropumpToken.sol";

/// @dev Stands in for the launcher. The whole supply is minted to whoever deploys, so a test that wants
///      the balance somewhere else forwards it on — which is what the launcher does too.
contract TokenDeployer {
    function deploy(string memory name_, string memory symbol_, uint256 supply, address to)
        external
        returns (HydropumpToken token)
    {
        token = new HydropumpToken(name_, symbol_, supply);
        if (to != address(this)) token.transfer(to, supply);
    }

    function deployAt(string memory name_, string memory symbol_, uint256 supply, address to, bytes32 salt)
        external
        returns (HydropumpToken token)
    {
        token = new HydropumpToken{salt: salt}(name_, symbol_, supply);
        if (to != address(this)) token.transfer(to, supply);
    }

    function initCodeHash(string memory name_, string memory symbol_, uint256 supply) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(HydropumpToken).creationCode, abi.encode(name_, symbol_, supply)));
    }
}

contract HydropumpTokenTest is Test {
    TokenDeployer internal deployer;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        deployer = new TokenDeployer();
    }

    function test_ConstructorTakesItsParametersDirectly() public {
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

    /// The constructor arguments are part of the init code, so the address a launch lands at depends on
    /// its name and symbol. That is deliberate: it means nobody can work out an address — or squat it with
    /// a pre-made pool — until the launch that uses it is already in flight.
    function test_InitCodeHashTracksTheNameAndSymbol() public view {
        bytes32 alpha = deployer.initCodeHash("Alpha", "ALPHA", 1e18);

        assertTrue(alpha != deployer.initCodeHash("Beta", "ALPHA", 1e18), "a different name moves it");
        assertTrue(alpha != deployer.initCodeHash("Alpha", "BETA", 1e18), "so does a different symbol");
        assertTrue(alpha != deployer.initCodeHash("Alpha", "ALPHA", 2e18), "and a different supply");
        assertEq(alpha, deployer.initCodeHash("Alpha", "ALPHA", 1e18), "and it is stable for the same ones");
    }

    function test_Create2AddressMatchesThePrediction() public {
        bytes32 salt = keccak256("salt");
        address predicted =
            vm.computeCreate2Address(salt, deployer.initCodeHash("Alpha", "ALPHA", 1e18), address(deployer));

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
