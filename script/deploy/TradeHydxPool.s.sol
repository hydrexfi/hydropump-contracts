// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HydropumpLauncher} from "../../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {ISwapRouter} from "../../contracts/interfaces/ISwapRouter.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @title TradeHydxPool
/// @notice Puts real volume through the HYDX-quoted launch, which `SeedLaunches` left untraded because
///         the deployer held no HYDX at the time.
/// @dev Buys HYDX out of the live WETH/HYDX pool first, then round-trips it against the launch and splits
///      the fees that produces. HYDX is the quote the mirrored curve exists for — nothing sorts below
///      0x00000e7e… — so leaving its pool with no trades would mean the one launch that proves the point
///      is also the one with nothing to show.
contract TradeHydxPool is Script {
    address internal constant WETH = HydropumpAddresses.WETH;
    address internal constant HYDX = HydropumpAddresses.HYDX;
    ISwapRouter internal constant ROUTER = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);

    /// @notice WETH spent acquiring HYDX to trade with.
    uint256 internal constant WETH_FOR_HYDX = 0.0008 ether;

    function run() public {
        uint256 key = vm.envUint("DEPLOYER_KEY");
        address me = vm.addr(key);

        HydropumpLauncher launcher = HydropumpLauncher(vm.envAddress("LAUNCHER_ADDRESS"));
        HydropumpLocker locker = HydropumpLocker(launcher.locker());

        // The HYDX-quoted launch, fourth of the six `SeedLaunches` made. Recorded rather than re-derived:
        // an address now depends on the name it launched with, and this one already exists.
        address token = 0xD6FC1E8881E96C4be08FEFdf447158a1625f4720;
        require(locker.quoteTokenOf(token) == HYDX, "index 3 is not the HYDX launch");

        vm.startBroadcast(key);

        // --- acquire the quote token, since a launch's own pool is the only place to spend it ---
        IERC20(WETH).approve(address(ROUTER), WETH_FOR_HYDX);
        uint256 hydx = _swap(WETH, HYDX, WETH_FOR_HYDX, me);
        console2.log("HYDX acquired", hydx);

        // --- round trip, so both sides of the pair accrue fees rather than just the quote ---
        IERC20(HYDX).approve(address(ROUTER), hydx);
        uint256 bought = _swap(HYDX, token, hydx, me);
        console2.log("DELTA bought  ", bought);

        IERC20(token).approve(address(ROUTER), bought / 2);
        uint256 back = _swap(token, HYDX, bought / 2, me);
        console2.log("HYDX back     ", back);

        // --- and put the fees through the whole path, so the launch has something to show ---
        locker.splitRewards(token);

        locker.spendCreatorShare(token);

        address[] memory assets = new address[](1);
        assets[0] = HYDX;
        locker.sweepProtocol(assets);

        vm.stopBroadcast();

        (uint128 grossLaunch, uint128 grossQuote) = locker.lifetimeFees(token);
        console2.log("token            ", token);
        console2.log("gross launch fees", uint256(grossLaunch));
        console2.log("gross quote fees ", uint256(grossQuote));
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address to) internal returns (uint256) {
        return ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                deployer: address(0),
                recipient: to,
                deadline: block.timestamp + 600,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
    }
}
