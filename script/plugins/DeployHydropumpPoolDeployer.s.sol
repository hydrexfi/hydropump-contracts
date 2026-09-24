// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {HydropumpPoolDeployer} from "../../contracts/plugins/HydropumpPoolDeployer.sol";
import {IAlgebraFactory} from "@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraFactory.sol";

/// @notice Deploy after the launcher proxy. Role grant and launcher binding are
/// separate governance transactions; this script does not impersonate either admin.
contract DeployHydropumpPoolDeployer is Script {
    address constant FACTORY = 0x36077D39cdC65E1e3FB65810430E5b2c4D5fA29E;

    function run() external returns (HydropumpPoolDeployer deployer) {
        require(block.chainid == 8453, "Base only");
        address launcher = vm.envAddress("LAUNCHER_ADDRESS");
        address source = address(IAlgebraFactory(FACTORY).defaultPluginFactory());
        vm.startBroadcast(vm.envUint("DEPLOYER_KEY"));
        deployer = new HydropumpPoolDeployer(FACTORY, launcher, source);
        vm.stopBroadcast();
        console2.log("Hydropump pool deployer:", address(deployer));
        console2.log("Algebra admin: grant CUSTOM_POOL_DEPLOYER to this address.");
        console2.log("Hydropump admin: call launcher.setPoolDeployer with this address.");
        console2.log("Use this deployer address in custom-pool swaps and positions.");
    }
}
