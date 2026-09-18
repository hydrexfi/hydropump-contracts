// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {FeeUseRegistry} from "../../contracts/FeeUseRegistry.sol";
import {AutoLpFeeUse} from "../../contracts/feeuses/AutoLpFeeUse.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";

/// @title UpgradeRegistryAndAutoLp
/// @notice Adds `replaceFeeUse` to the registry, then uses it to point AUTO_LP at a fixed implementation.
contract UpgradeRegistryAndAutoLp is Script {
    function run() public {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        FeeUseRegistry registry = FeeUseRegistry(vm.envAddress("FEE_USE_REGISTRY_ADDRESS"));
        address locker = vm.envAddress("LOCKER_ADDRESS");

        require(registry.owner() == vm.addr(key), "deployer is not the upgrade authority");
        address previous = registry.feeUseImpl(FeeUses.AUTO_LP);

        vm.startBroadcast(key);
        registry.upgradeToAndCall(address(new FeeUseRegistry()), "");

        AutoLpFeeUse autoLp = new AutoLpFeeUse(locker);
        registry.replaceFeeUse(FeeUses.AUTO_LP, address(autoLp));
        vm.stopBroadcast();

        require(registry.feeUseImpl(FeeUses.AUTO_LP) == address(autoLp), "auto-LP not repointed");
        require(registry.feeUseImpl(FeeUses.CREATOR_BALANCE) != address(0), "creator balance lost");
        require(registry.feeUseImpl(FeeUses.BUYBACK_BURN) != address(0), "buyback burn lost");

        console2.log("AutoLpFeeUse was:", previous);
        console2.log("AutoLpFeeUse now:", address(autoLp));
    }
}
