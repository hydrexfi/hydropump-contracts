// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {HydropumpRotator} from "../../contracts/core/HydropumpRotator.sol";

/// @title DeployRotator
/// @notice Deploys the rotator against the live locker. Wiring it in is the locker owner's to do.
/// @dev Release only works once the locker owner has (1) upgraded the locker to an implementation with
///      `releaseLiquidity` and (2) called `setRotator` with this address. That first `setRotator` fixes
///      `rotationStart`: every launch registered before it stays locked for good.
contract DeployRotator is Script {
    function run() public {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        address locker = vm.envAddress("LOCKER_ADDRESS");
        address admin = vm.envAddress("HYDROPUMP_ADMIN");
        address owner = vm.envOr("HYDROPUMP_OWNER", admin);
        address operator = vm.envAddress("HYDROPUMP_OPERATOR");

        require(HydropumpLocker(locker).launcher() != address(0), "not a wired locker");

        vm.startBroadcast(key);
        HydropumpRotator rotator = new HydropumpRotator(owner, operator, locker);
        vm.stopBroadcast();

        require(address(rotator.locker()) == locker, "locker not set");

        console2.log("HydropumpRotator:", address(rotator));
        console2.log("owner:           ", rotator.owner());
        console2.log("operator:        ", rotator.operator());
        console2.log("next, from the locker owner: upgrade the locker, then setRotator(rotator)");
    }
}
