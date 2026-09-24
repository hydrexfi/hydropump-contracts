// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {HydropumpBuyback} from "../../contracts/core/HydropumpBuyback.sol";
import {HydropumpRewardDistributor} from "../../contracts/core/HydropumpRewardDistributor.sol";
import {PairDirectory} from "../../contracts/helpers/PairDirectory.sol";
import {FeeUseRegistry} from "../../contracts/helpers/FeeUseRegistry.sol";
import {CreatorBalanceFeeUse} from "../../contracts/feeuses/CreatorBalanceFeeUse.sol";
import {AutoLpFeeUse} from "../../contracts/feeuses/AutoLpFeeUse.sol";
import {BuybackBurnFeeUse} from "../../contracts/feeuses/BuybackBurnFeeUse.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @title DeployHydropump
/// @dev Two identities, nothing else to configure:
///        deployer  (DEPLOYER_KEY)        owns the directory and launcher
///        admin     (HYDROPUMP_ADMIN)     the Safe — upgrades, and owns the locker, registry, buyback
///                                        and distributor
///        operator  (HYDROPUMP_OPERATOR)  the backend key that runs the jobs; defaults to the deployer
///
///      Order is forced by the references. The registry needs the launcher, the launcher needs the locker
///      and directory, and the fee uses need the locker — so everything goes up under the deployer,
///      gets wired, and is handed to the admin last.
///
///      The launcher is deployed with the deployer as its own admin and reassigned at the end. Its pointer
///      setters are admin-gated on purpose — repointing the locker or the directory is as powerful as an
///      upgrade — and that same gate would otherwise stop the deployer wiring the registry in.
contract DeployHydropump is Script {
    uint64 internal constant CREATOR_FEE = 7_500; // 75%, to whatever the launch's fee use spends it on
    uint64 internal constant PROTOCOL_FEE = 2_500; // 25%, converted to the quote and held for the buyback
    uint96 internal constant LAUNCH_FEE = 0.0005 ether; // anti-spam, claimable by the admin

    function run() public {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer = vm.addr(deployerKey);
        address admin = vm.envAddress("HYDROPUMP_ADMIN");
        address gaugeBribe = vm.envOr("HYDROPUMP_GAUGE_BRIBE", HydropumpAddresses.GAUGE_BRIBE);
        address operator = vm.envOr("HYDROPUMP_OPERATOR", deployer);

        console2.log("=== Hydropump Deployment ===");
        console2.log("Deployer:", deployer);
        console2.log("Operator:", operator);
        console2.log("Admin (Safe):", admin);

        vm.startBroadcast(deployerKey);

        // --- the pieces that reference nothing ---
        HydropumpBuyback buyback = new HydropumpBuyback(admin, operator, HydropumpAddresses.HYDX, gaugeBribe);

        PairDirectory directory = PairDirectory(
            address(
                new ERC1967Proxy(
                    address(new PairDirectory()), abi.encodeCall(PairDirectory.initialize, (deployer, admin))
                )
            )
        );

        // --- locker, then launcher, then registry: each needs the one before it ---
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
                    abi.encodeCall(
                        HydropumpLauncher.initialize,
                        // Admin is the deployer for the length of this script; handed over below.
                        (deployer, deployer, address(locker), address(directory), LAUNCH_FEE)
                    )
                )
            )
        );

        FeeUseRegistry registry = FeeUseRegistry(
            address(
                new ERC1967Proxy(
                    address(new FeeUseRegistry()),
                    abi.encodeCall(FeeUseRegistry.initialize, (deployer, address(launcher)))
                )
            )
        );

        // --- the three things a creator share can be spent on ---
        // No owner on any of them: they hold nothing between calls, so there is nothing to administer
        // and nothing to rescue.
        CreatorBalanceFeeUse creatorBalance = new CreatorBalanceFeeUse(address(locker));
        AutoLpFeeUse autoLp = new AutoLpFeeUse(address(locker));
        BuybackBurnFeeUse buybackBurn = new BuybackBurnFeeUse(address(locker));

        registry.registerFeeUse(FeeUses.CREATOR_BALANCE, address(creatorBalance));
        registry.registerFeeUse(FeeUses.AUTO_LP, address(autoLp));
        registry.registerFeeUse(FeeUses.BUYBACK_BURN, address(buybackBurn));
        registry.setDefaultFeeUse(FeeUses.CREATOR_BALANCE);

        // Emissions: the operator credits, the admin can rewrite and withdraw. Nothing references it, so
        // it is wired to no one — the operator funds it out of band.
        HydropumpRewardDistributor distributor = new HydropumpRewardDistributor(admin, operator);

        // --- wire the back-references, then hand over ---
        locker.setLauncher(address(launcher));
        locker.setFeeUseRegistry(address(registry));
        launcher.setFeeUseRegistry(address(registry));

        // Ownable2Step for the two the admin owns outright, so the Safe has to accept. The launcher's admin
        // is a plain reassignment — there is no two-step for it, and losing it would brick the upgrade path,
        // so it goes last and is asserted afterwards.
        locker.transferOwnership(admin);
        registry.transferOwnership(admin);
        launcher.setAdmin(admin);

        require(launcher.admin() == admin, "launcher admin handover failed");
        require(directory.admin() == admin, "directory admin handover failed");

        vm.stopBroadcast();

        console2.log("\n=== Deployed ===");
        console2.log("PairDirectory:       ", address(directory));
        console2.log("HydropumpLauncher:   ", address(launcher));
        console2.log("HydropumpLocker:     ", address(locker));
        console2.log("FeeUseRegistry:      ", address(registry));
        console2.log("CreatorBalanceFeeUse:", address(creatorBalance));
        console2.log("AutoLpFeeUse:        ", address(autoLp));
        console2.log("BuybackBurnFeeUse:   ", address(buybackBurn));
        console2.log("HydropumpBuyback:    ", address(buyback));
        console2.log("RewardDistributor:   ", address(distributor));
        console2.log("operator:            ", operator);
        console2.log("Launch fee (wei):    ", uint256(LAUNCH_FEE));
        console2.log("\nSet LAUNCHER_ADDRESS and PAIR_DIRECTORY_ADDRESS in .env, then:");
        console2.log("  npm run quotes:build && npm run quotes:register:base");
        console2.log("From the Safe: accept the locker and registry ownership transfers (Ownable2Step).");
        console2.log("Launches stay disabled until the dedicated plugin deployer is deployed, granted CUSTOM_POOL_DEPLOYER, and bound by the admin.");
        console2.log("See contracts/plugins/README.md for the plugin deployment stage.");
    }
}
