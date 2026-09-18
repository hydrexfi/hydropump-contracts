// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {HydropumpBuyback} from "../../contracts/core/HydropumpBuyback.sol";
import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @title RedeployBuyback
/// @notice Replaces the buyback and points the locker's protocol share at it.
/// @dev The old one hardcoded Hydrex's MultiRouter proxy as its swap target, which does not accept raw
///      aggregator calldata, so its swap leg could never fill. It is owned by the Safe and cannot be
///      repointed from here.
contract RedeployBuyback is Script {
    function run() public {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(key);
        HydropumpLocker locker = HydropumpLocker(vm.envAddress("LOCKER_ADDRESS"));
        address gaugeBribe = vm.envOr("HYDROPUMP_GAUGE_BRIBE", HydropumpAddresses.GAUGE_BRIBE);

        require(locker.owner() == deployer, "deployer does not own the locker");
        address previous = locker.protocolFeeRecipient();

        vm.startBroadcast(key);
        // Owner is the deployer while this is still being iterated on; hand to the Safe with the rest.
        address operator = vm.envOr("HYDROPUMP_OPERATOR", deployer);
        HydropumpBuyback buyback = new HydropumpBuyback(deployer, operator, HydropumpAddresses.HYDX, gaugeBribe);
        locker.setProtocolFeeRecipient(address(buyback));
        vm.stopBroadcast();

        require(locker.protocolFeeRecipient() == address(buyback), "locker not repointed");
        require(buyback.router() == HydropumpAddresses.KYBER_ROUTER, "router default wrong");

        console2.log("HydropumpBuyback was:", previous);
        console2.log("HydropumpBuyback now:", address(buyback));
        console2.log("swap router:         ", buyback.router());
        console2.log("operator:            ", buyback.operator());
    }
}
