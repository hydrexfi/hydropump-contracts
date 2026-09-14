// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../../contracts/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/HydropumpLocker.sol";
import {HydropumpBuyback} from "../../contracts/HydropumpBuyback.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @title DeployHydropump
/// @dev Two identities, nothing else to configure:
///        deployer  (DEPLOYER_KEY)      also the operator — owns the launcher, runs the jobs
///        admin     (HYDROPUMP_ADMIN)   the Safe — upgrades, and owns the locker and buyback
///      The locker and launcher reference each other, so the locker goes up under the deployer, gets wired,
///      and is then handed to the admin.
contract DeployHydropump is Script {
    uint64 internal constant CREATOR_FEE = 7_500; // 75% of collected fees
    uint64 internal constant PROTOCOL_FEE = 2_500; // 25%, funds the HYDX buyback
    uint96 internal constant LAUNCH_FEE = 0.00001 ether; // anti-spam, claimable by the admin

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        address admin = vm.envAddress("HYDROPUMP_ADMIN");
        address gaugeBribe = vm.envOr("HYDROPUMP_GAUGE_BRIBE", HydropumpAddresses.GAUGE_BRIBE);

        console2.log("=== Hydropump Deployment ===");
        console2.log("Deployer / operator:", deployer);
        console2.log("Admin (Safe):       ", admin);

        vm.startBroadcast(deployerKey);

        HydropumpBuyback buyback = new HydropumpBuyback(admin, deployer, HydropumpAddresses.HYDX, gaugeBribe);

        HydropumpLocker locker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(
                        HydropumpLocker.initialize, (deployer, address(0), address(buyback), CREATOR_FEE, PROTOCOL_FEE)
                    )
                )
            )
        );

        HydropumpLauncher launcher = HydropumpLauncher(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLauncher()),
                    abi.encodeCall(HydropumpLauncher.initialize, (deployer, admin, address(locker), LAUNCH_FEE))
                )
            )
        );

        locker.setLauncher(address(launcher));
        locker.transferOwnership(admin);

        vm.stopBroadcast();

        console2.log("\n=== Deployed ===");
        console2.log("HydropumpLauncher:", address(launcher));
        console2.log("HydropumpLocker:  ", address(locker));
        console2.log("HydropumpBuyback: ", address(buyback));
        console2.log("Launch fee (wei):  ", uint256(LAUNCH_FEE));
        console2.log("\nSet LAUNCHER_ADDRESS in .env, then: npm run quotes:build && npm run quotes:register:base");
        console2.log("From the Safe: accept the locker ownership transfer (Ownable2Step).");
    }
}
