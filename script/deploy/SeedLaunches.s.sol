// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpLauncher} from "../../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {ISwapRouter} from "../../contracts/interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

interface IWETH {
    function deposit() external payable;
}

/// @title SeedLaunches
/// @notice Puts real launches on mainnet: every fee use on both sides of the pair, traded against, split,
///         and spent. Leaves the indexer and the API with genuine data rather than empty pools.
contract SeedLaunches is Script {
    address internal constant WETH = HydropumpAddresses.WETH;
    address internal constant HYDX = HydropumpAddresses.HYDX;
    ISwapRouter internal constant ROUTER = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    uint256 internal constant WRAP_AMOUNT = 0.004 ether;
    uint256 internal constant BUY_PER_POOL = 0.0005 ether;

    HydropumpLauncher internal launcher;
    HydropumpLocker internal locker;

    struct Plan {
        string name;
        string symbol;
        address quoteToken;
        bytes32 feeUse;
    }

    /// @dev Every fee use on both sides of a WETH pair, plus one quoted in HYDX — the token at 0x00000e7e…
    ///      that nothing can sort below, and so was unlaunchable before the curve could mirror.
    function _plans() internal pure returns (Plan[6] memory) {
        return [
            Plan("Hydropump Alpha", "ALPHA", WETH, FeeUses.CREATOR_BALANCE),
            Plan("Hydropump Bravo", "BRAVO", WETH, FeeUses.AUTO_LP),
            Plan("Hydropump Cielo", "CIELO", WETH, FeeUses.BUYBACK_BURN),
            Plan("Hydropump Delta", "DELTA", HYDX, FeeUses.CREATOR_BALANCE),
            Plan("Hydropump Echo", "ECHO", WETH, FeeUses.AUTO_LP),
            Plan("Hydropump Foxtrot", "FOX", WETH, FeeUses.BUYBACK_BURN)
        ];
    }

    /// @dev One pass. This was two phases when the protocol-side swap priced against the pool's
    ///      time-weighted tick and a pool younger than the window could not be converted; nothing reads
    ///      an oracle now, so a launch can be traded, split and spent in the same transaction.
    function run() public {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        address me = vm.addr(key);
        launcher = HydropumpLauncher(vm.envAddress("LAUNCHER_ADDRESS"));
        locker = HydropumpLocker(launcher.locker());

        Plan[6] memory plans = _plans();
        address[6] memory tokens;
        address[6] memory pools;

        vm.startBroadcast(key);

        IWETH(WETH).deposit{value: WRAP_AMOUNT}();
        IERC20(WETH).approve(address(ROUTER), type(uint256).max);

        for (uint256 i = 0; i < plans.length; i++) {
            (tokens[i], pools[i],) = launcher.launch{value: launcher.launchFee()}(
                HydropumpLauncher.LaunchParams({
                    name: plans[i].name,
                    symbol: plans[i].symbol,
                    quoteToken: plans[i].quoteToken,
                    creatorRecipient: me,
                    buyAmount: 0,
                    feeUse: plans[i].feeUse
                })
            );
        }

        for (uint256 i = 0; i < plans.length; i++) {
            if (plans[i].quoteToken != WETH) continue; // no HYDX on hand to trade the HYDX pair with

            // Both ways, so both sides of the pair accrue fees rather than only the quote.
            uint256 bought = _swap(WETH, tokens[i], BUY_PER_POOL, me);
            IERC20(tokens[i]).approve(address(ROUTER), bought / 2);
            _swap(tokens[i], WETH, bought / 2, me);

            // One call: sweep, spend the creator's share, convert the protocol's.
            locker.handleAllRewards(tokens[i]);
        }

        // And the protocol share reaches the buyback, which is where it ends up in production.
        address[] memory assets = new address[](1);
        assets[0] = WETH;
        locker.sweepProtocol(assets);

        vm.stopBroadcast();

        console2.log("=== Seeded ===");
        for (uint256 i = 0; i < plans.length; i++) {
            console2.log(plans[i].symbol);
            console2.log("  token   ", tokens[i]);
            console2.log("  pool    ", pools[i]);
            console2.log("  quote   ", plans[i].quoteToken);
            console2.log("  token0? ", tokens[i] < plans[i].quoteToken);
        }
        console2.log("protocol WETH still owed", locker.protocolOwed(WETH));
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address to) internal returns (uint256) {
        return ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                deployer: launcher.poolDeployer(),
                recipient: to,
                deadline: block.timestamp + 600,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
    }
}
