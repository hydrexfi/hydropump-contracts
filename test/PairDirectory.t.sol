// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PairDirectory} from "../contracts/helpers/PairDirectory.sol";
import {IPairDirectory} from "../contracts/interfaces/IPairDirectory.sol";
import {TickMath} from "../contracts/libraries/TickMath.sol";
import {HydropumpAddresses} from "../contracts/libraries/HydropumpAddresses.sol";

/// @notice The quote registry on its own: what is launchable, at what price, and who may say so.
contract PairDirectoryTest is Test {
    PairDirectory internal directory;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    address internal constant WETH = HydropumpAddresses.WETH;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function setUp() public {
        directory = PairDirectory(
            address(
                new ERC1967Proxy(address(new PairDirectory()), abi.encodeCall(PairDirectory.initialize, (owner, admin)))
            )
        );
        _configure(WETH, true, -228_200);
    }

    function _configure(address quoteToken, bool enabled, int24 startTick) internal {
        address[] memory tokens = new address[](1);
        bool[] memory enabledList = new bool[](1);
        int24[] memory ticks = new int24[](1);
        (tokens[0], enabledList[0], ticks[0]) = (quoteToken, enabled, startTick);
        vm.prank(owner);
        directory.configureQuoteTokens(tokens, enabledList, ticks);
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _oneTick(int24 t) internal pure returns (int24[] memory out) {
        out = new int24[](1);
        out[0] = t;
    }

    // =============================
    //  REGISTRY
    // =============================

    function test_ConfigureStoresEverything() public view {
        (bool enabled, int24 startTick, uint64 updatedAt) = directory.quoteTokens(WETH);
        assertTrue(enabled);
        assertEq(startTick, -228_200);
        assertEq(updatedAt, block.timestamp);
        assertTrue(directory.isEnabled(WETH));
    }

    /// A quote that has never been written is not launchable, and neither is one written and then disabled.
    function test_UnknownAndDisabledQuotesAreBothUnlaunchable() public {
        assertFalse(directory.isEnabled(USDC));

        vm.expectRevert(PairDirectory.QuoteTokenNotEnabled.selector);
        directory.requirePoolStartTick(address(uint160(1)), USDC);

        _configure(WETH, false, -228_200);
        assertFalse(directory.isEnabled(WETH), "disabled is not launchable");
        vm.expectRevert(PairDirectory.QuoteTokenNotEnabled.selector);
        directory.requirePoolStartTick(address(uint160(1)), WETH);
    }

    /// Delisting has to be an explicit write. Dropping a token from the list leaves it live on-chain, which
    /// is the whole reason the generator carries retired entries forward.
    function test_DelistingIsAWriteNotAnOmission() public {
        assertTrue(directory.isEnabled(WETH));
        _configure(USDC, true, -421_417);

        // Re-registering only USDC leaves WETH exactly as it was.
        assertTrue(directory.isEnabled(WETH), "omitting a token does not delist it");

        _configure(WETH, false, -228_200);
        assertFalse(directory.isEnabled(WETH));
        (,, uint64 updatedAt) = directory.quoteTokens(WETH);
        assertGt(updatedAt, 0, "and it stays registered, so it is not silently re-addable");
    }

    function test_ConfigureAppliesEveryEntry() public {
        address[] memory tokens = new address[](2);
        bool[] memory enabled = new bool[](2);
        int24[] memory ticks = new int24[](2);
        (tokens[0], enabled[0], ticks[0]) = (WETH, false, -1);
        (tokens[1], enabled[1], ticks[1]) = (USDC, true, -421_600);

        vm.prank(owner);
        directory.configureQuoteTokens(tokens, enabled, ticks);

        (bool wethEnabled, int24 wethTick,) = directory.quoteTokens(WETH);
        (bool usdcEnabled, int24 usdcTick,) = directory.quoteTokens(USDC);
        assertFalse(wethEnabled);
        assertEq(wethTick, -1);
        assertTrue(usdcEnabled);
        assertEq(usdcTick, -421_600);
    }

    function test_ConfigureRejectsRaggedInput() public {
        vm.prank(owner);
        vm.expectRevert(PairDirectory.LengthMismatch.selector);
        directory.configureQuoteTokens(_one(WETH), new bool[](2), _oneTick(-1000));
    }

    function test_QuoteConfigsReadsManyAtOnce() public {
        _configure(USDC, true, -421_417);

        address[] memory tokens = new address[](3);
        (tokens[0], tokens[1], tokens[2]) = (WETH, USDC, makeAddr("unknown"));
        IPairDirectory.QuoteConfig[] memory configs = directory.quoteConfigs(tokens);

        assertEq(configs.length, 3);
        assertEq(configs[0].startTick, -228_200);
        assertEq(configs[1].startTick, -421_417);
        assertFalse(configs[2].enabled, "an unknown quote reads as an empty config, not a revert");
    }

    // =============================
    //  THE DAILY REFRESH
    // =============================

    function test_SetStartTicksRepricesAndStamps() public {
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        directory.setStartTicks(_one(WETH), _oneTick(-230_000));

        (, int24 startTick, uint64 updatedAt) = directory.quoteTokens(WETH);
        assertEq(startTick, -230_000);
        assertEq(updatedAt, block.timestamp);
    }

    function test_SetStartTicksCoversEveryQuoteInTheBatch() public {
        _configure(USDC, true, -421_417);

        address[] memory tokens = new address[](2);
        int24[] memory ticks = new int24[](2);
        (tokens[0], ticks[0]) = (WETH, -228_400);
        (tokens[1], ticks[1]) = (USDC, -421_800);

        vm.prank(owner);
        directory.setStartTicks(tokens, ticks);

        (, int24 wethTick,) = directory.quoteTokens(WETH);
        (, int24 usdcTick,) = directory.quoteTokens(USDC);
        assertEq(wethTick, -228_400);
        assertEq(usdcTick, -421_800);
    }

    /// The refresh path is for repricing what is already listed. A disabled quote is not a pricing error,
    /// it is a token nobody should be launching against, so repricing it has to fail rather than re-list it.
    function test_RefreshingADisabledQuoteReverts() public {
        _configure(WETH, false, -228_200);
        vm.prank(owner);
        vm.expectRevert(PairDirectory.QuoteTokenNotEnabled.selector);
        directory.setStartTicks(_one(WETH), _oneTick(-230_000));
    }

    // =============================
    //  MIRRORING
    // =============================

    /// One number per quote, read both ways. A pool prices token1 in token0, so a launch token landing on
    /// the other side of the pair gets the reciprocal price, which is the same tick negated.
    function test_PoolStartTickMirrorsOnTheToken1Side() public view {
        address low = address(uint160(1));
        address high = address(type(uint160).max);

        assertTrue(directory.launchIsToken0(low, WETH));
        assertFalse(directory.launchIsToken0(high, WETH));
        assertEq(directory.poolStartTick(low, WETH), -228_200);
        assertEq(directory.poolStartTick(high, WETH), 228_200);
        assertEq(directory.requirePoolStartTick(high, WETH), 228_200);
    }

    function testFuzz_MirrorOfTheMirrorIsWhereItStarted(int24 startTick, address token) public {
        startTick = int24(bound(startTick, TickMath.MIN_TICK, TickMath.MAX_TICK));
        vm.assume(token != WETH);

        vm.prank(owner);
        directory.setStartTicks(_one(WETH), _oneTick(startTick));

        int24 tick = directory.poolStartTick(token, WETH);
        assertEq(tick, token < WETH ? startTick : -startTick);
        assertEq(token < WETH ? tick : -tick, startTick);
    }

    /// The negation has to land on a real tick, which an int24 does not guarantee on its own.
    function test_StartTickOutsideTheTickRangeIsRejected() public {
        vm.startPrank(owner);

        vm.expectRevert(PairDirectory.StartTickOutOfRange.selector);
        directory.configureQuoteTokens(_one(USDC), _oneBool(true), _oneTick(-900_000));

        vm.expectRevert(PairDirectory.StartTickOutOfRange.selector);
        directory.setStartTicks(_one(WETH), _oneTick(900_000));

        // The extreme an int24 holds but a tick does not; negating it would overflow outright.
        vm.expectRevert(PairDirectory.StartTickOutOfRange.selector);
        directory.setStartTicks(_one(WETH), _oneTick(type(int24).min));

        vm.stopPrank();
    }

    // =============================
    //  AUTHORITY
    // =============================

    /// The owner is the daily refresh key and writes prices all day. The admin is the Safe and holds the
    /// upgrade. Keeping them apart is the point of the split, so neither may reach the other's powers.
    function test_OwnerWritesPricesAndAdminHoldsTheUpgrade() public {
        address newImpl = address(new PairDirectory());

        vm.prank(owner);
        vm.expectRevert(PairDirectory.NotAdmin.selector);
        directory.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        vm.expectRevert();
        directory.setStartTicks(_one(WETH), _oneTick(-1));

        vm.prank(admin);
        directory.upgradeToAndCall(newImpl, "");
    }

    function test_StrangerCanDoNeither() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        directory.configureQuoteTokens(_one(WETH), _oneBool(true), _oneTick(-1));
        vm.expectRevert();
        directory.setStartTicks(_one(WETH), _oneTick(-1));
        vm.expectRevert(PairDirectory.NotAdmin.selector);
        directory.setAdmin(stranger);
        vm.stopPrank();
    }

    function test_OnlyAdminCanReassignAdmin() public {
        vm.prank(owner);
        vm.expectRevert(PairDirectory.NotAdmin.selector);
        directory.setAdmin(owner);

        vm.prank(admin);
        directory.setAdmin(stranger);
        assertEq(directory.admin(), stranger);
    }

    function test_ImplementationCannotBeInitialized() public {
        PairDirectory impl = new PairDirectory();
        vm.expectRevert();
        impl.initialize(owner, admin);
    }

    function _oneBool(bool b) internal pure returns (bool[] memory out) {
        out = new bool[](1);
        out[0] = b;
    }
}
