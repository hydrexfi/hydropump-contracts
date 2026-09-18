// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../../../contracts/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../../contracts/HydropumpLocker.sol";
import {PairDirectory} from "../../../contracts/PairDirectory.sol";
import {FeeUseRegistry} from "../../../contracts/FeeUseRegistry.sol";
import {CreatorBalanceFeeUse} from "../../../contracts/feeuses/CreatorBalanceFeeUse.sol";
import {AutoLpFeeUse} from "../../../contracts/feeuses/AutoLpFeeUse.sol";
import {BuybackBurnFeeUse} from "../../../contracts/feeuses/BuybackBurnFeeUse.sol";
import {FeeUses} from "../../../contracts/libraries/FeeUses.sol";
import {HydropumpAddresses} from "../../../contracts/libraries/HydropumpAddresses.sol";
import {IAlgebraPool} from "../../../contracts/interfaces/IAlgebraPool.sol";
import {INonfungiblePositionManager} from "../../../contracts/interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter} from "../../../contracts/interfaces/ISwapRouter.sol";

/// @notice The whole stack deployed against live Hydrex on Base, wired exactly as the deploy script wires it.
/// @dev Requires BASE_RPC_URL; `forked` is false without it and every suite skips, so `forge test` stays
///      offline-clean.
///
///      Orientation is chosen rather than accepted. Addresses come out of a per-sender counter now, so a
///      test that means to exercise one side of the pair launches from a throwaway account until it lands
///      there — cheap, and it keeps each case honest about which orientation it is actually testing.
abstract contract ForkFixture is Test {
    INonfungiblePositionManager internal constant NPM =
        INonfungiblePositionManager(HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER);
    ISwapRouter internal constant ROUTER = ISwapRouter(HydropumpAddresses.SWAP_ROUTER);
    address internal constant WETH = HydropumpAddresses.WETH;

    /// @dev HYDX sits at 0x00000e7e..., low enough that no launch token can ever sort below it.
    address internal constant HYDX = HydropumpAddresses.HYDX;

    int24 internal constant WETH_START_TICK = -228_200;
    int24 internal constant HYDX_START_TICK = -107_655;
    uint96 internal constant LAUNCH_FEE = 0.0005 ether;
    uint64 internal constant CREATOR_FEE = 7_500;
    uint64 internal constant PROTOCOL_FEE = 2_500;
    uint256 internal constant TARGET_FDV_USD = 5_000;

    PairDirectory internal directory;
    HydropumpLauncher internal launcher;
    HydropumpLocker internal locker;
    FeeUseRegistry internal registry;
    CreatorBalanceFeeUse internal creatorBalance;
    AutoLpFeeUse internal autoLp;
    BuybackBurnFeeUse internal buybackBurn;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal creator = makeAddr("creator");
    address internal buyback = makeAddr("buyback");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    /// @dev Used only to poke a pool so its oracle writes a timepoint, kept apart from the accounts a test
    ///      asserts balances on.
    address internal poker = makeAddr("poker");

    bool internal forked;

    function setUp() public virtual {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        directory = PairDirectory(
            address(
                new ERC1967Proxy(address(new PairDirectory()), abi.encodeCall(PairDirectory.initialize, (owner, admin)))
            )
        );

        locker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(HydropumpLocker.initialize, (owner, address(0), buyback, CREATOR_FEE, PROTOCOL_FEE))
                )
            )
        );

        launcher = HydropumpLauncher(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLauncher()),
                    abi.encodeCall(
                        HydropumpLauncher.initialize, (owner, admin, address(locker), address(directory), LAUNCH_FEE)
                    )
                )
            )
        );

        registry = FeeUseRegistry(
            address(
                new ERC1967Proxy(
                    address(new FeeUseRegistry()), abi.encodeCall(FeeUseRegistry.initialize, (owner, address(launcher)))
                )
            )
        );

        creatorBalance = new CreatorBalanceFeeUse(address(locker));
        autoLp = new AutoLpFeeUse(address(locker));
        buybackBurn = new BuybackBurnFeeUse(address(locker));

        vm.startPrank(owner);
        registry.registerFeeUse(FeeUses.CREATOR_BALANCE, address(creatorBalance));
        registry.registerFeeUse(FeeUses.AUTO_LP, address(autoLp));
        registry.registerFeeUse(FeeUses.BUYBACK_BURN, address(buybackBurn));
        registry.setDefaultFeeUse(FeeUses.CREATOR_BALANCE);
        locker.setLauncher(address(launcher));
        locker.setFeeUseRegistry(address(registry));
        vm.stopPrank();

        vm.prank(admin);
        launcher.setFeeUseRegistry(address(registry));

        _registerQuote(WETH, WETH_START_TICK);
        _registerQuote(HYDX, HYDX_START_TICK);

        vm.deal(creator, 1_000 ether);
    }

    modifier onlyForked() {
        if (!forked) {
            vm.skip(true);
        }
        _;
    }

    // ---------------------------------------------------------------- helpers

    function _registerQuote(address quoteToken, int24 startTick) internal {
        address[] memory tokens = new address[](1);
        bool[] memory enabled = new bool[](1);
        int24[] memory ticks = new int24[](1);
        (tokens[0], enabled[0], ticks[0]) = (quoteToken, true, startTick);
        vm.prank(owner);
        directory.configureQuoteTokens(tokens, enabled, ticks);
    }

    /// @dev Arranges the launcher so its next `CREATE` lands on the requested side of `quoteToken`.
    ///
    ///      A launch address is no longer chosen by anything — not a salt, not the sender, not the name.
    ///      It falls out of the launcher's own nonce. So a test that means to exercise one orientation
    ///      winds that nonce forward until the address it would produce sorts the right way, rather than
    ///      searching for an account or burning real launches to get there.
    function _arrangeSide(address quoteToken, bool wantToken0) internal {
        uint64 nonce = vm.getNonce(address(launcher));
        for (uint64 i = 0; i < 256; i++) {
            address next = vm.computeCreateAddress(address(launcher), nonce + i);
            if ((next < quoteToken) == wantToken0) {
                vm.setNonce(address(launcher), nonce + i);
                return;
            }
        }
        revert("no nonce within reach lands on that side");
    }

    function _launchFrom(address account, address quoteToken, bytes32 feeUse, uint256 buyAmount)
        internal
        returns (address token, address pool, uint256[] memory positionIds)
    {
        if (buyAmount > 0) {
            deal(quoteToken, account, buyAmount);
            vm.prank(account);
            IERC20(quoteToken).approve(address(launcher), buyAmount);
        }
        vm.prank(account);
        (token, pool, positionIds) = launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: quoteToken,
                creatorRecipient: account,
                buyAmount: buyAmount,
                feeUse: feeUse
            })
        );
    }

    function _launchOnSide(address quoteToken, bool wantToken0, bytes32 feeUse)
        internal
        returns (address token, address pool, uint256[] memory positionIds, address account)
    {
        _arrangeSide(quoteToken, wantToken0);
        account = creator;
        (token, pool, positionIds) = _launchFrom(account, quoteToken, feeUse, 0);
        require((token < quoteToken) == wantToken0, "fixture: wrong side");
    }

    function _currentTick(address pool) internal view returns (int24 tick) {
        (, tick,,,,) = IAlgebraPool(pool).globalState();
    }

    function _swapIn(address who, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 out) {
        deal(tokenIn, who, amountIn);
        vm.startPrank(who);
        IERC20(tokenIn).approve(address(ROUTER), amountIn);
        out = ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                deployer: address(0),
                recipient: who,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    /// @dev Sells `amountIn` of a token the account already holds.
    function _sell(address who, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 out) {
        vm.startPrank(who);
        IERC20(tokenIn).approve(address(ROUTER), amountIn);
        out = ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                deployer: address(0),
                recipient: who,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();
    }

    /// @dev Trades both ways so both sides of the pair accrue fees, then lets the pool's price history
    ///      cover the TWAP window the conversion is priced over.
    function _tradeBothWaysAndAge(address token, address quoteToken, uint256 quoteIn) internal {
        uint256 bought = _swapIn(alice, quoteToken, token, quoteIn);
        _sell(alice, token, quoteToken, bought / 2);
        _ageTwapWindow(token, quoteToken);
    }

    /// @dev Kept as a plain "let some time pass" so tests that want a pool with history still read that
    ///      way. Nothing prices off an oracle any more, so it is no longer load-bearing.
    function _ageTwapWindow(address token, address quoteToken) internal {
        vm.warp(block.timestamp + 1_200);
        vm.roll(block.number + 600);
        _swapIn(poker, quoteToken, token, 1e12);
    }

    /// @dev Quote raw units per one whole launch token, scaled by 1e18. A pool quotes token1 in token0, so
    ///      this inverts when the launch token is token1. Squaring goes through mulDiv because a mirrored
    ///      tick can be large and positive, where sqrtPriceX96 squared overflows a uint256.
    function _priceE18(address pool, address token, address quoteToken) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,) = IAlgebraPool(pool).globalState();
        uint256 priceQ96 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 96);
        return token < quoteToken ? Math.mulDiv(priceQ96, 1e36, 1 << 96) : Math.mulDiv(1e36, 1 << 96, priceQ96);
    }

    /// @dev The shape a seeded curve must have whichever side of the pair it landed on.
    function _assertCurveShape(address token, address quoteToken, address pool, uint256[] memory positionIds)
        internal
        view
    {
        bool isToken0 = token < quoteToken;
        int24 spacing = IAlgebraPool(pool).tickSpacing();
        int24 tick = _currentTick(pool);
        int24 edge;

        assertEq(positionIds.length, 5, "band count");
        for (uint256 i = 0; i < positionIds.length; i++) {
            (,,,,, int24 lower, int24 upper, uint128 liquidity,,,,) = NPM.positions(positionIds[i]);

            assertGt(liquidity, 0, "band must hold liquidity");
            assertEq(NPM.ownerOf(positionIds[i]), address(locker), "band must be locked");
            assertEq(lower % spacing, 0, "lower must align to spacing");
            assertEq(upper % spacing, 0, "upper must align to spacing");

            if (isToken0) {
                assertGe(lower, tick, "token0 band must sit at or above the price");
                if (i > 0) assertEq(lower, edge, "bands must be contiguous");
                edge = upper;
            } else {
                assertLe(upper, tick, "token1 band must sit at or below the price");
                if (i > 0) assertEq(upper, edge, "bands must be contiguous");
                edge = lower;
            }
        }
        assertEq(IERC20(quoteToken).balanceOf(pool), 0, "no quote may enter the pool at launch");
    }
}
