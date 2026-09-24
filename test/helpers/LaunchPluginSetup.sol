// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HydropumpLauncher} from "../../contracts/core/HydropumpLauncher.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

interface ILaunchAlgebraFactory {
    function owner() external view returns (address);
    function defaultPluginFactory() external view returns (address);
    function CUSTOM_POOL_DEPLOYER() external view returns (bytes32);
    function grantRole(bytes32 role, address user) external;
    function revokeRole(bytes32 role, address user) external;
    function poolByPair(address a, address b) external view returns (address);
    function customPoolByPair(address deployer, address a, address b) external view returns (address);
    function createPool(address a, address b, bytes calldata data) external returns (address);
}

/// @dev Compiles separately from the 0.8.20 plugin. Tests deploy its compiled
/// artifact, not a mock. Build the plugins profile before running launch forks.
abstract contract LaunchPluginSetup is Test {
    function _deployLaunchPlugin(HydropumpLauncher target, address admin) internal returns (address deployer) {
        ILaunchAlgebraFactory factory = ILaunchAlgebraFactory(HydropumpAddresses.ALGEBRA_FACTORY);
        require(address(factory).code.length > 0, "Algebra factory missing");
        bytes memory code = abi.encodePacked(
            vm.getCode("out/plugins/HydropumpPoolDeployer.sol/HydropumpPoolDeployer.json"),
            abi.encode(address(factory), address(target), factory.defaultPluginFactory())
        );
        assembly {
            deployer := create(0, add(code, 32), mload(code))
        }
        require(deployer != address(0), "Plugin deployer creation failed");
        // Forge's test VM can allow oversized deployments: explicitly enforce EIP-170.
        assertLe(deployer.code.length, 24_576, "pool deployer must be deployable on Base");
        bytes32 role = factory.CUSTOM_POOL_DEPLOYER();
        vm.prank(factory.owner());
        factory.grantRole(role, deployer);
        vm.prank(admin);
        target.setPoolDeployer(deployer);
    }
}
