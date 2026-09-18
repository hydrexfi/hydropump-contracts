// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";

/// @title UpgradeLocker
/// @notice Points the locker proxy at a fresh implementation.
/// @dev Only valid while the upgrade authority is still the deployer. Once the Safe accepts ownership
///      this has to be proposed there instead.
contract UpgradeLocker is Script {
    function run() public {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        HydropumpLocker locker = HydropumpLocker(vm.envAddress("LOCKER_ADDRESS"));

        require(locker.owner() == vm.addr(key), "deployer is not the upgrade authority");

        // Read before, so the upgrade can be shown not to have moved anything.
        address launcher = locker.launcher();
        address registry = locker.feeUseRegistry();
        uint64 creatorFee = locker.creatorFee();
        uint64 protocolFee = locker.protocolFee();

        vm.startBroadcast(key);
        address implementation = address(new HydropumpLocker());
        locker.upgradeToAndCall(implementation, "");
        vm.stopBroadcast();

        require(locker.launcher() == launcher, "launcher moved");
        require(locker.feeUseRegistry() == registry, "registry moved");
        require(locker.creatorFee() == creatorFee && locker.protocolFee() == protocolFee, "fee split moved");

        console2.log("HydropumpLocker proxy:", address(locker));
        console2.log("new implementation:   ", implementation);
    }
}
