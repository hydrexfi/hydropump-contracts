// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydropumpLaunchpad} from "../contracts/HydropumpLaunchpad.sol";

/// @title DeployHydropumpLaunchpad
/// @dev Deploys HydropumpLaunchpad. Each launch then deploys its own HydropumpLocker, tracked by the launchpad.
contract DeployHydropumpLaunchpad is Script {
    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);

        // Owner for each per-token locker (multisig, governance, etc.)
        address vaultOwner = vm.envOr("LAUNCHPAD_VAULT_OWNER", deployer);

        string memory networkName = vm.envOr("NETWORK", string("base"));

        console2.log("=== HydropumpLaunchpad Deployment ===");
        console2.log("Network:", networkName);
        console2.log("Deployer:", deployer);
        console2.log("Vault owner (per-token lockers):", vaultOwner);

        vm.startBroadcast(deployerKey);

        HydropumpLaunchpad launchpad = new HydropumpLaunchpad(vaultOwner);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Successful ===");
        console2.log("HydropumpLaunchpad deployed at:", address(launchpad));
        console2.log("NPM:", address(launchpad.nonfungiblePositionManager()));
        console2.log("WETH:", launchpad.WETH());
        console2.log("Vault owner:", launchpad.vaultOwner());

        _saveDeployment(networkName, address(launchpad), deployer);
    }

    function _saveDeployment(string memory networkName, address launchpadAddress, address deployer) internal {
        string memory deploymentPath =
            string.concat("deployments/", networkName, "-", vm.toString(launchpadAddress), ".json");

        string memory json = "deployment";
        vm.serializeString(json, "network", networkName);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "blockNumber", block.number);

        string memory launchpadJson = "HydropumpLaunchpad";
        vm.serializeAddress(launchpadJson, "address", launchpadAddress);
        vm.serializeAddress(launchpadJson, "vaultOwner", HydropumpLaunchpad(launchpadAddress).vaultOwner());
        vm.serializeAddress(launchpadJson, "deployer", deployer);
        string memory launchpadData = vm.serializeString(launchpadJson, "name", "HydropumpLaunchpad");

        string memory contractData = vm.serializeString("contracts", "HydropumpLaunchpad", launchpadData);
        string memory finalJson = vm.serializeString(json, "contracts", contractData);

        vm.writeFile(deploymentPath, finalJson);
        console2.log("\nDeployment saved to:", deploymentPath);
    }
}
