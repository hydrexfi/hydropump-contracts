// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../../contracts/core/HydropumpLocker.sol";
import {PairDirectory} from "../../contracts/helpers/PairDirectory.sol";
import {FeeUseRegistry} from "../../contracts/helpers/FeeUseRegistry.sol";
import {CreatorBalanceFeeUse} from "../../contracts/feeuses/CreatorBalanceFeeUse.sol";
import {AutoLpFeeUse} from "../../contracts/feeuses/AutoLpFeeUse.sol";
import {BuybackBurnFeeUse} from "../../contracts/feeuses/BuybackBurnFeeUse.sol";
import {FeeUses} from "../../contracts/libraries/FeeUses.sol";
import {HydropumpAddresses} from "../../contracts/libraries/HydropumpAddresses.sol";
import {TickMath} from "../../contracts/libraries/TickMath.sol";
import {MockAlgebra, MockAlgebraPool, MockSwapRouter} from "../mocks/MockAlgebra.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice The whole stack, wired the way the deploy script wires it, against a stand-in Algebra.
/// @dev Every suite inherits this rather than repeating the wiring, so a change to how the pieces reference
///      each other is caught by all of them at once instead of drifting per-file.
///
///      Two quote tokens are etched at fixed addresses, one near the bottom of the address space and one
///      near the top. A launch token's address falls out of `CREATE` and cannot be chosen, so that is how a
///      test picks the pair ordering it means to exercise: nothing sorts below `LOW_QUOTE` and nothing
///      sorts above `HIGH_QUOTE`.
abstract contract HydropumpFixture is Test {
    address internal constant NPM = HydropumpAddresses.NONFUNGIBLE_POSITION_MANAGER;
    address internal constant ROUTER = HydropumpAddresses.SWAP_ROUTER;

    /// @dev No launch address sorts below this, so a launch against it is always token1.
    address internal constant LOW_QUOTE = address(uint160(0x77));
    /// @dev And none sorts above this, so a launch against it is always token0.
    address internal constant HIGH_QUOTE = address(uint160(type(uint160).max - 0x77));

    int24 internal constant WETH_START_TICK = -228_200;
    uint96 internal constant LAUNCH_FEE = 0.0005 ether;
    uint64 internal constant CREATOR_FEE = 7_500;
    uint64 internal constant PROTOCOL_FEE = 2_500;

    PairDirectory internal directory;
    HydropumpLauncher internal launcher;
    HydropumpLocker internal locker;
    FeeUseRegistry internal registry;
    CreatorBalanceFeeUse internal creatorBalance;
    AutoLpFeeUse internal autoLp;
    BuybackBurnFeeUse internal buybackBurn;

    MockAlgebra internal npm;
    MockSwapRouter internal router;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal creator = makeAddr("creator");
    address internal buyback = makeAddr("buyback");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.etch(NPM, address(new MockAlgebra()).code);
        npm = MockAlgebra(NPM);
        npm.setTickSpacing(200);

        vm.etch(ROUTER, address(new MockSwapRouter(MockAlgebra(NPM))).code);
        router = MockSwapRouter(ROUTER);
        router.configure(3_000, 500); // etching leaves storage empty, so set the defaults by hand

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

        _deployQuote(LOW_QUOTE);
        _deployQuote(HIGH_QUOTE);
        _registerQuote(LOW_QUOTE, WETH_START_TICK);
        _registerQuote(HIGH_QUOTE, WETH_START_TICK);

        vm.deal(creator, 100 ether);
    }

    // ---------------------------------------------------------------- helpers

    function _deployQuote(address at) internal {
        vm.etch(at, address(new MockERC20("Quote", "Q")).code);
    }

    function _registerQuote(address quoteToken, int24 startTick) internal {
        address[] memory tokens = new address[](1);
        bool[] memory enabled = new bool[](1);
        int24[] memory ticks = new int24[](1);
        (tokens[0], enabled[0], ticks[0]) = (quoteToken, true, startTick);
        vm.prank(owner);
        directory.configureQuoteTokens(tokens, enabled, ticks);
    }

    function _launch(address quoteToken, bytes32 feeUse, uint256 buyAmount)
        internal
        returns (address token, address pool, uint256[] memory positionIds)
    {
        if (buyAmount > 0) {
            MockERC20(quoteToken).mint(creator, buyAmount);
            vm.prank(creator);
            IERC20(quoteToken).approve(address(launcher), buyAmount);
        }
        vm.warp(vm.getBlockTimestamp() + 1); // one launch per sender per second
        vm.prank(creator);
        (token, pool, positionIds) = launcher.launch{value: LAUNCH_FEE}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: quoteToken,
                creatorRecipient: creator,
                buyAmount: buyAmount,
                feeUse: feeUse
            })
        );
    }

    function _launch(address quoteToken) internal returns (address token, address pool, uint256[] memory ids) {
        return _launch(quoteToken, bytes32(0), 0);
    }

    /// @dev Credits fees to a launch's first band, in launch/quote terms rather than pool slots.
    ///      The launch token is a real HydropumpToken with no mint, so its side is moved out of the pool —
    ///      which is where a real swap fee comes from anyway. The quote is a mock and can be minted.
    function _accrueFees(address token, uint256 launchAmount, uint256 quoteAmount) internal {
        address quoteToken = locker.quoteTokenOf(token);
        address pool = locker.poolOf(token);
        uint256[] memory positionIds = locker.getPositions(token);

        if (launchAmount > 0) _moveOutOfPool(token, pool, launchAmount);
        if (quoteAmount > 0) MockERC20(quoteToken).mint(NPM, quoteAmount);

        bool isToken0 = token < quoteToken;
        (uint128 owed0, uint128 owed1) =
            isToken0 ? (uint128(launchAmount), uint128(quoteAmount)) : (uint128(quoteAmount), uint128(launchAmount));

        // All of it on band 0; the split does not care which band produced what.
        npm.setOwed(positionIds[0], owed0, owed1);
    }

    /// @dev Moves launch-token fees to the mock NPM, which pays collects from its own balance. A transfer
    ///      would pay the launch tax; real fees go from the pool to the locker, which is exempt.
    function _moveOutOfPool(address token, address pool, uint256 amount) internal {
        deal(token, pool, IERC20(token).balanceOf(pool) - amount);
        deal(token, NPM, IERC20(token).balanceOf(NPM) + amount);
    }

    /// @dev `_accrueFees`, but onto a band the caller names.
    function _accrueFeesOn(address token, uint256 index, uint256 launchAmount, uint256 quoteAmount) internal {
        address quoteToken = locker.quoteTokenOf(token);
        address pool = locker.poolOf(token);

        if (launchAmount > 0) _moveOutOfPool(token, pool, launchAmount);
        if (quoteAmount > 0) MockERC20(quoteToken).mint(NPM, quoteAmount);

        bool isToken0 = token < quoteToken;
        (uint128 owed0, uint128 owed1) =
            isToken0 ? (uint128(launchAmount), uint128(quoteAmount)) : (uint128(quoteAmount), uint128(launchAmount));

        npm.setOwed(locker.getPositions(token)[index], owed0, owed1);
    }

    function _currentTick(address pool) internal view returns (int24 tick) {
        (, tick,,,,) = MockAlgebraPool(pool).globalState();
    }

    /// @dev Puts quote into the pool so a sell can actually be filled out of it. A launch pool opens
    ///      single-sided and only holds quote once someone has bought, so a test that converts has to say
    ///      that trading happened.
    function _seedPoolQuote(address token, uint256 amount) internal {
        MockERC20(locker.quoteTokenOf(token)).mint(locker.poolOf(token), amount);
    }

    /// @dev Moves the pool's price, for tests that care where a swap fills.
    function _setSpot(address pool, int24 tick) internal {
        MockAlgebraPool(pool).setPrice(TickMath.getSqrtRatioAtTick(tick));
    }

    /// @dev Moves spot as a swap earlier in this block would, leaving the block's opening tick recorded.
    function _moveSpotThisBlock(address pool, int24 tick) internal {
        MockAlgebraPool(pool).writeTimepoint();
        _setSpot(pool, tick);
    }

    /// @dev Tick offset that moves the launch token's price by `ticks`, whichever side it is.
    function _launchPriceOffset(address token, int24 ticks) internal view returns (int24) {
        return token < locker.quoteTokenOf(token) ? ticks : -ticks;
    }
}
