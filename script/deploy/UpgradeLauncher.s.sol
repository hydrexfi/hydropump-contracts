// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {HydropumpLauncher} from "../../contracts/HydropumpLauncher.sol";

/// @title UpgradeLauncher
/// @notice Deploys a launcher implementation and points the proxy at it.
/// @dev The launcher's upgrade authority is `admin`, which the deploy script hands to the Safe outright —
///      there is no two-step to leave pending — so unless the deployer still holds it, this deploys the
///      implementation and prints the call for the Safe to make.
contract UpgradeLauncher is Script {
    function run() public {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        HydropumpLauncher launcher = HydropumpLauncher(vm.envAddress("LAUNCHER_ADDRESS"));

        address locker = launcher.locker();
        address directory = launcher.pairDirectory();
        address registry = launcher.feeUseRegistry();
        uint96 launchFee = launcher.launchFee();

        vm.startBroadcast(key);
        address implementation = address(new HydropumpLauncher());

        bool canUpgrade = launcher.admin() == vm.addr(key);
        if (canUpgrade) launcher.upgradeToAndCall(implementation, "");
        vm.stopBroadcast();

        console2.log("HydropumpLauncher proxy:", address(launcher));
        console2.log("new implementation:     ", implementation);

        if (!canUpgrade) {
            console2.log("\nUpgrade authority is the admin, which is:", launcher.admin());
            console2.log("Have it call, on the proxy:");
            console2.log("  upgradeToAndCall(address,bytes)");
            console2.logBytes(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", implementation, ""));
            return;
        }

        require(launcher.locker() == locker, "locker moved");
        require(launcher.pairDirectory() == directory, "directory moved");
        require(launcher.feeUseRegistry() == registry, "registry moved");
        require(launcher.launchFee() == launchFee, "launch fee moved");
        console2.log("upgraded");
    }
}
