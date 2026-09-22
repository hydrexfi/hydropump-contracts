// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {FeeUseRegistry} from "../../contracts/helpers/FeeUseRegistry.sol";

/// @notice Read-only deployment gate. Does not broadcast or accept ownership.
contract CheckAdminHandover is Script {
    function run() public view {
        verify(
            vm.envAddress("LOCKER_ADDRESS"), vm.envAddress("FEE_USE_REGISTRY_ADDRESS"), vm.envAddress("HYDROPUMP_ADMIN")
        );
    }

    function verify(address locker, address registry, address admin) public view {
        require(admin != address(0), "zero admin");
        require(HydropumpLocker(locker).owner() == admin, "locker handover incomplete");
        require(FeeUseRegistry(registry).owner() == admin, "registry handover incomplete");
        require(HydropumpLocker(locker).pendingOwner() == address(0), "locker transfer still pending");
        require(FeeUseRegistry(registry).pendingOwner() == address(0), "registry transfer still pending");
    }
}
