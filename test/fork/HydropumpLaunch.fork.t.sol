// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../../contracts/HydropumpLauncher.sol";
import {HydropumpAutoLP} from "../../contracts/HydropumpAutoLP.sol";
import {HydropumpStakingRewards} from "../../contracts/HydropumpStakingRewards.sol";
import {HydropumpLocker} from "../../contracts/HydropumpLocker.sol";
import {IAlgebraPool} from "../../contracts/interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "../../contracts/interfaces/INonfungiblePositionManager.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";

/// @notice Full launch against the live Hydrex deployment on Base.
/// @dev Requires BASE_RPC_URL; skipped when unset so `forge test` stays offline-clean.
contract HydropumpLaunchForkTest is Test {
    INonfungiblePositionManager internal constant NPM =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);
    address internal constant WETH = HydropumpAddresses.WETH;

    /// @dev ETH at ~$4,000: $5k FDV over 10B supply is 1.25e-10 WETH per token, floored to the 200 spacing.
    int24 internal constant WETH_START_TICK = -228_200;

    HydropumpLauncher internal launcher;
    HydropumpLocker internal locker;

    address internal owner = makeAddr("owner");
    address internal creator = makeAddr("creator");
    address internal buyback = makeAddr("buyback");

    uint96 internal constant LAUNCH_FEE = 0.0005 ether;
    uint256 internal saltCursor;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        vm.deal(creator, 100 ether);

        locker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(
                        HydropumpLocker.initialize, (owner, address(0), buyback, uint64(7_500), uint64(2_500))
                    )
                )
            )
        );
        launcher = HydropumpLauncher(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLauncher()),
                    abi.encodeCall(
                        HydropumpLauncher.initialize,
                        (
                            owner,
                            owner,
                            address(locker),
                            address(new HydropumpAutoLP()),
                            address(new HydropumpStakingRewards()),
                            LAUNCH_FEE
                        )
                    )
                )
            )
        );

        vm.startPrank(owner);
        locker.setLauncher(address(launcher));
        address[] memory quotes = new address[](1);
        bool[] memory enabled = new bool[](1);
        int24[] memory ticks = new int24[](1);
        (quotes[0], enabled[0], ticks[0]) = (WETH, true, WETH_START_TICK);
        launcher.configureQuoteTokens(quotes, enabled, ticks);
        vm.stopPrank();
    }

    /// @dev Advances a cursor: CREATE2 is deterministic, so reusing a salt resolves to an address that
    ///      already has a token deployed at it.
    function _mineSalt(address deployer) internal returns (bytes32 salt) {
        for (uint256 i = saltCursor; i < saltCursor + 20_000; i++) {
            salt = bytes32(i);
            if (launcher.isSaltValid(deployer, salt, WETH)) {
                saltCursor = i + 1;
                return salt;
            }
        }
        revert("no salt found");
    }

    function test_LaunchSeedsTheCurveAndLocksEveryPosition() public {
        if (!forked) {
            vm.skip(true);
        }

        bytes32 salt = _mineSalt(creator);

        vm.prank(creator);
        (address token, address pool, uint256[] memory positionIds) = launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: WETH,
                userSalt: salt,
                creatorRecipient: creator,
                buyAmount: 0
            })
        );

        // --- token0 invariant ---
        assertLt(uint160(token), uint160(WETH), "token must sort below the quote");
        assertEq(IAlgebraPool(pool).token0(), token, "launch token must be token0");
        assertEq(IAlgebraPool(pool).token1(), WETH, "quote must be token1");

        // --- pool opened at the configured start tick ---
        (, int24 currentTick,,,,) = IAlgebraPool(pool).globalState();
        assertEq(currentTick, WETH_START_TICK, "pool must open at the configured start tick");

        // --- the launch never needed a single wei of quote ---
        assertEq(IERC20(WETH).balanceOf(address(launcher)), 0);
        assertEq(IERC20(WETH).balanceOf(address(locker)), 0, "single-sided: no quote in any position");

        // --- full supply deployed, nothing stranded in the launcher ---
        assertEq(IERC20(token).totalSupply(), launcher.SUPPLY());
        assertEq(IERC20(token).balanceOf(address(launcher)), 0, "launcher must hold nothing after launch");
        uint256 dust = IERC20(token).balanceOf(creator);
        // Liquidity math rounds down per band; the remainder refunded to the creator is a rounding artefact,
        // not a meaningful allocation. 1e12 wei is one millionth of one token out of a 10B supply.
        assertLt(dust, 1e12, "mint remainder refunded to the creator must be dust");
        assertApproxEqRel(IERC20(token).balanceOf(pool), launcher.SUPPLY(), 1e12, "supply must sit in the pool");

        // --- five bands, all locked, monotonic and contiguous ---
        int24 spacing = IAlgebraPool(pool).tickSpacing();
        int24 previousUpper;
        uint128 totalLiquidity;
        for (uint256 i = 0; i < 5; i++) {
            (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) = NPM.positions(positionIds[i]);

            assertEq(NPM.ownerOf(positionIds[i]), address(locker), "position must be locked");
            assertGt(liquidity, 0, "band must hold liquidity");
            assertGe(tickLower, currentTick, "band must sit at or above the current tick");
            assertEq(tickLower % spacing, 0, "band must align to spacing");
            assertEq(tickUpper % spacing, 0, "band must align to spacing");
            if (i > 0) assertEq(tickLower, previousUpper, "bands must be contiguous");
            previousUpper = tickUpper;
            totalLiquidity += liquidity;
        }
        assertGt(totalLiquidity, 0);

        // --- the locker knows the launch ---
        HydropumpLocker.Launch memory launch = locker.getLaunch(token);
        assertEq(launch.pool, pool);
        assertEq(launch.creator, creator);
        assertEq(launch.creatorRecipient, creator);
        assertEq(launch.positionIds[4], positionIds[4]);

        console2.log("token", token);
        console2.log("pool ", pool);
        console2.log("tick spacing", int256(spacing));
        console2.log("creator dust refund", dust);
    }

    function test_LaunchWithBuyFillsInTheSameTransaction() public {
        if (!forked) {
            vm.skip(true);
        }

        uint256 buyAmount = 0.05 ether;
        deal(WETH, creator, buyAmount);

        bytes32 salt = _mineSalt(creator);

        vm.startPrank(creator);
        IERC20(WETH).approve(address(launcher), buyAmount);
        (address token, address pool,) = launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: WETH,
                userSalt: salt,
                creatorRecipient: creator,
                buyAmount: buyAmount
            })
        );
        vm.stopPrank();

        assertGt(IERC20(token).balanceOf(creator), 0, "buyer must receive tokens");
        assertEq(IERC20(WETH).balanceOf(creator), 0, "full buy amount must be spent");
        assertEq(IERC20(WETH).balanceOf(address(launcher)), 0, "no quote may be left in the launcher");
        assertEq(IERC20(WETH).balanceOf(pool), buyAmount, "quote must land in the pool");

        (, int24 tickAfter,,,,) = IAlgebraPool(pool).globalState();
        assertGt(tickAfter, WETH_START_TICK, "the buy must move the price up");
    }

    function test_ZeroBuyAmountSkipsTheSwap() public {
        if (!forked) {
            vm.skip(true);
        }

        bytes32 salt = _mineSalt(creator);
        vm.prank(creator);
        (address token, address pool,) = launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: WETH,
                userSalt: salt,
                creatorRecipient: creator,
                buyAmount: 0
            })
        );

        assertEq(IERC20(WETH).balanceOf(pool), 0, "no quote should enter the pool");
        assertLt(IERC20(token).balanceOf(creator), 1e12, "creator gets mint dust only, no bought tokens");

        (, int24 tickAfter,,,,) = IAlgebraPool(pool).globalState();
        assertEq(tickAfter, WETH_START_TICK);
    }

    function test_LaunchFeeAccumulatesAndIsClaimable() public {
        if (!forked) {
            vm.skip(true);
        }

        bytes32 salt = _mineSalt(creator);
        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: WETH,
                userSalt: salt,
                creatorRecipient: creator,
                buyAmount: 0
            })
        );

        assertEq(address(launcher).balance, LAUNCH_FEE, "fee stays in the launcher");

        // Overpayment is accepted and kept, not refunded.
        uint256 surplus = 0.002 ether;
        bytes32 salt2 = _mineSalt(creator);
        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE + surplus}(
            HydropumpLauncher.LaunchParams({
                name: "Beta",
                symbol: "BETA",
                quoteToken: WETH,
                userSalt: salt2,
                creatorRecipient: creator,
                buyAmount: 0
            })
        );
        assertEq(address(launcher).balance, LAUNCH_FEE * 2 + surplus, "surplus is kept");

        address sink = makeAddr("sink");
        vm.prank(owner);
        uint256 claimed = launcher.claimLaunchFees(sink);

        assertEq(claimed, LAUNCH_FEE * 2 + surplus);
        assertEq(sink.balance, LAUNCH_FEE * 2 + surplus);
        assertEq(address(launcher).balance, 0);
    }

    function test_LaunchPoolIsNotGauged() public {
        if (!forked) {
            vm.skip(true);
        }

        bytes32 salt = _mineSalt(creator);
        vm.prank(creator);
        (, address pool,) = launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: WETH,
                userSalt: salt,
                creatorRecipient: creator,
                buyAmount: 0
            })
        );

        // A gauged Hydrex CL pool runs at communityFee 1000/1000, which would send 100% of swap fees to the
        // community vault and leave the locked positions — and so the creator and the buyback — with nothing.
        (,,,, uint16 communityFee,) = IAlgebraPool(pool).globalState();
        assertEq(communityFee, 0, "launch pools must keep fees with the LP");
    }
}
