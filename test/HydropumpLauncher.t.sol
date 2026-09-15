// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../contracts/HydropumpLauncher.sol";
import {HydropumpAutoLP} from "../contracts/HydropumpAutoLP.sol";
import {HydropumpAddresses} from "../contracts/libraries/HydropumpAddresses.sol";

contract HydropumpLauncherTest is Test {
    HydropumpLauncher internal launcher;

    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");
    address internal locker = makeAddr("locker");
    address internal creator = makeAddr("creator");
    address internal stranger = makeAddr("stranger");

    address internal constant WETH = HydropumpAddresses.WETH;
    uint96 internal constant LAUNCH_FEE = 0.0005 ether;

    function setUp() public {
        vm.deal(creator, 1 ether);
        vm.deal(stranger, 1 ether);
        launcher = HydropumpLauncher(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLauncher()),
                    abi.encodeCall(
                        HydropumpLauncher.initialize, (owner, admin, locker, address(new HydropumpAutoLP()), LAUNCH_FEE)
                    )
                )
            )
        );
        vm.prank(owner);
        launcher.configureQuoteTokens(_one(WETH), _one(true), _oneTick(-228_200));
    }

    /// @dev What the frontend's Web Worker does: bump the salt until the token sorts below the quote.
    function _mineSalt(address deployer) internal view returns (bytes32 salt, uint256 attempts) {
        for (uint256 i = 0; i < 20_000; i++) {
            salt = bytes32(i);
            attempts = i + 1;
            if (launcher.isSaltValid(deployer, salt, WETH)) return (salt, attempts);
        }
        revert("no salt found");
    }

    // =============================
    //  CURVE
    // =============================

    function test_CurveSharesSumToFullSupply() public view {
        uint256 total;
        int24 previousUpper;
        for (uint256 i = 0; i < launcher.bandCount(); i++) {
            (int24 lower, int24 upper, uint256 shareBps) = launcher.band(i);
            total += shareBps;

            assertEq(lower, previousUpper, "bands must be contiguous");
            assertLt(lower, upper, "band must be non-empty");
            assertEq(lower % 200, 0, "offsets must divide the 200 spacing");
            assertEq(upper % 200, 0, "offsets must divide the 200 spacing");
            previousUpper = upper;
        }
        assertEq(total, 10_000, "shares must sum to 100%");
        assertEq(previousUpper, 887_200, "tail must reach the max usable tick");
    }

    // =============================
    //  SALT MINING / TOKEN0 INVARIANT
    // =============================

    function test_MinedSaltSortsBelowTheQuoteToken() public view {
        (bytes32 salt, uint256 attempts) = _mineSalt(creator);

        assertLt(uint160(launcher.predictToken(creator, salt)), uint160(WETH));
        assertLt(attempts, 500, "mining against WETH should take a handful of attempts");
    }

    function test_SaltValidityIsPerQuoteToken() public view {
        (bytes32 salt,) = _mineSalt(creator);
        address predicted = launcher.predictToken(creator, salt);

        assertTrue(launcher.isSaltValid(creator, salt, WETH));
        // A quote token below the mined address invalidates the same salt.
        assertFalse(launcher.isSaltValid(creator, salt, address(uint160(predicted) - 1)));
    }

    function test_LaunchRevertsOnUnminedSalt() public {
        bytes32 salt;
        for (uint256 i = 0; i < 20_000; i++) {
            salt = bytes32(i);
            if (!launcher.isSaltValid(creator, salt, WETH)) break;
        }

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.TokenNotBelowQuote.selector);
        launcher.launch{value: LAUNCH_FEE}(_params(salt));
    }

    function test_SaltIsBoundToTheSender() public {
        (bytes32 salt,) = _mineSalt(creator);

        // Same salt, different sender, different token address - so a mined salt cannot be lifted from
        // the mempool and used by someone else.
        assertTrue(launcher.predictToken(creator, salt) != launcher.predictToken(stranger, salt));

        // Find a salt that works for the creator but not the stranger, and confirm the stranger is stopped.
        bytes32 exclusive;
        for (uint256 i = 0; i < 20_000; i++) {
            exclusive = bytes32(i);
            if (launcher.isSaltValid(creator, exclusive, WETH) && !launcher.isSaltValid(stranger, exclusive, WETH)) {
                break;
            }
        }
        vm.prank(stranger);
        vm.expectRevert(HydropumpLauncher.TokenNotBelowQuote.selector);
        launcher.launch{value: LAUNCH_FEE}(_params(exclusive));
    }

    // =============================
    //  QUOTE REGISTRY
    // =============================

    function test_LaunchRevertsOnUnknownQuoteToken() public {
        (bytes32 salt,) = _mineSalt(creator);
        HydropumpLauncher.LaunchParams memory params = _params(salt);
        params.quoteToken = makeAddr("randomToken");

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.QuoteTokenNotEnabled.selector);
        launcher.launch{value: LAUNCH_FEE}(params);
    }

    function test_ConfigureQuoteTokenIsOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert();
        launcher.configureQuoteTokens(_one(WETH), _one(true), _oneTick(-1000));
    }

    function test_ConfigureQuoteTokensRejectsRaggedInput() public {
        vm.prank(owner);
        vm.expectRevert(HydropumpLauncher.LengthMismatch.selector);
        launcher.configureQuoteTokens(_one(WETH), new bool[](2), _oneTick(-1000));
    }

    function test_ConfigureQuoteTokensAppliesEveryEntry() public {
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        address[] memory quotes = new address[](2);
        bool[] memory enabled = new bool[](2);
        int24[] memory ticks = new int24[](2);
        (quotes[0], enabled[0], ticks[0]) = (WETH, false, -1);
        (quotes[1], enabled[1], ticks[1]) = (usdc, true, -421_600);

        vm.prank(owner);
        launcher.configureQuoteTokens(quotes, enabled, ticks);

        (bool wethEnabled, int24 wethTick,) = launcher.quoteTokens(WETH);
        (bool usdcEnabled, int24 usdcTick,) = launcher.quoteTokens(usdc);
        assertFalse(wethEnabled);
        assertEq(wethTick, -1);
        assertTrue(usdcEnabled);
        assertEq(usdcTick, -421_600);
    }

    // =============================
    //  START TICK
    // =============================

    function test_OwnerRefreshesStartTick() public {
        vm.prank(owner);
        launcher.setStartTicks(_one(WETH), _oneTick(-230_000));

        (, int24 startTick, uint64 updatedAt) = launcher.quoteTokens(WETH);
        assertEq(startTick, -230_000);
        assertEq(updatedAt, block.timestamp);
    }

    function test_BatchRefreshUpdatesEveryQuote() public {
        address usdc = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        vm.prank(owner);
        launcher.configureQuoteTokens(_one(usdc), _one(true), _oneTick(-421_600));

        address[] memory quotes = new address[](2);
        int24[] memory ticks = new int24[](2);
        (quotes[0], ticks[0]) = (WETH, -228_400);
        (quotes[1], ticks[1]) = (usdc, -421_800);

        vm.prank(owner);
        launcher.setStartTicks(quotes, ticks);

        (, int24 wethTick,) = launcher.quoteTokens(WETH);
        (, int24 usdcTick,) = launcher.quoteTokens(usdc);
        assertEq(wethTick, -228_400);
        assertEq(usdcTick, -421_800);
    }

    function test_StrangerCannotRefreshStartTick() public {
        vm.prank(stranger);
        vm.expectRevert();
        launcher.setStartTicks(_one(WETH), _oneTick(-1));
    }

    function test_StartTickOnDisabledQuoteReverts() public {
        vm.prank(owner);
        vm.expectRevert(HydropumpLauncher.QuoteTokenNotEnabled.selector);
        launcher.setStartTicks(_one(makeAddr("other")), _oneTick(-1));
    }

    // =============================
    //  ADMIN
    // =============================

    function test_OnlyAdminCanUpgrade() public {
        address newImpl = address(new HydropumpLauncher());

        // The owner runs configuration but must not be able to upgrade.
        vm.prank(owner);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.upgradeToAndCall(newImpl, "");

        vm.prank(stranger);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        launcher.upgradeToAndCall(newImpl, "");
    }

    function test_OnlyAdminCanReassignAdmin() public {
        vm.prank(owner);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.setAdmin(owner);

        vm.prank(admin);
        launcher.setAdmin(stranger);
        assertEq(launcher.admin(), stranger);
    }

    function test_OwnerRunsConfiguration() public {
        vm.startPrank(owner);
        launcher.configureQuoteTokens(_one(WETH), _one(true), _oneTick(-228_000));
        launcher.setStartTicks(_one(WETH), _oneTick(-228_400));
        vm.stopPrank();

        (, int24 tick,) = launcher.quoteTokens(WETH);
        assertEq(tick, -228_400);
    }

    /// Repointing the locker redirects every future launch's liquidity, so the hot key must not hold it.
    function test_OnlyAdminCanRepointTheLocker() public {
        vm.prank(owner);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.setLocker(stranger);

        vm.prank(stranger);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.setLocker(stranger);

        vm.prank(admin);
        launcher.setLocker(stranger);
        assertEq(launcher.locker(), stranger);
    }

    function test_ImplementationCannotBeInitialized() public {
        HydropumpLauncher impl = new HydropumpLauncher();
        HydropumpAutoLP autoLp = new HydropumpAutoLP();
        vm.expectRevert();
        impl.initialize(owner, admin, locker, address(autoLp), LAUNCH_FEE);
    }

    function test_FeeRoutesRejectUnsupportedTypes() public {
        HydropumpLauncher.FeeRouteConfig[] memory routes = new HydropumpLauncher.FeeRouteConfig[](1);
        routes[0] = HydropumpLauncher.FeeRouteConfig({routeType: 2, bps: 1_000, config: ""});

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.UnsupportedFeeRoute.selector);
        launcher.launch{value: LAUNCH_FEE}(_params(bytes32(0)), routes);
    }

    function test_FeeRoutesRejectDuplicates() public {
        HydropumpLauncher.FeeRouteConfig[] memory routes = new HydropumpLauncher.FeeRouteConfig[](2);
        routes[0] = HydropumpLauncher.FeeRouteConfig({routeType: 1, bps: 500, config: ""});
        routes[1] = HydropumpLauncher.FeeRouteConfig({routeType: 1, bps: 500, config: ""});

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.DuplicateFeeRoute.selector);
        launcher.launch{value: LAUNCH_FEE}(_params(bytes32(0)), routes);
    }

    function test_FeeRoutesRejectUnexpectedConfig() public {
        HydropumpLauncher.FeeRouteConfig[] memory routes = new HydropumpLauncher.FeeRouteConfig[](1);
        routes[0] = HydropumpLauncher.FeeRouteConfig({routeType: 1, bps: 500, config: hex"01"});

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.InvalidFeeRouteConfig.selector);
        launcher.launch{value: LAUNCH_FEE}(_params(bytes32(0)), routes);
    }

    function _params(bytes32 salt) internal view returns (HydropumpLauncher.LaunchParams memory) {
        return HydropumpLauncher.LaunchParams({
            name: "Alpha",
            symbol: "ALPHA",
            quoteToken: WETH,
            userSalt: salt,
            creatorRecipient: creator,
            buyAmount: 0
        });
    }

    function _one(address a) internal pure returns (address[] memory out) {
        out = new address[](1);
        out[0] = a;
    }

    function _one(bool b) internal pure returns (bool[] memory out) {
        out = new bool[](1);
        out[0] = b;
    }

    function _one(uint256 v) internal pure returns (uint256[] memory out) {
        out = new uint256[](1);
        out[0] = v;
    }

    function _oneTick(int24 t) internal pure returns (int24[] memory out) {
        out = new int24[](1);
        out[0] = t;
    }
}
