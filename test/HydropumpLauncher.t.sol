// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HydropumpLauncher} from "../contracts/core/HydropumpLauncher.sol";
import {HydropumpLocker} from "../contracts/core/HydropumpLocker.sol";
import {HydropumpToken} from "../contracts/core/HydropumpToken.sol";
import {PairDirectory} from "../contracts/helpers/PairDirectory.sol";
import {FeeUseRegistry} from "../contracts/helpers/FeeUseRegistry.sol";
import {FeeUses} from "../contracts/libraries/FeeUses.sol";
import {ISwapRouter} from "../contracts/interfaces/ISwapRouter.sol";
import {HydropumpFixture} from "./helpers/HydropumpFixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice The launcher after the registry moved out: what it still owns, and what it now asks for.
contract HydropumpLauncherTest is HydropumpFixture {
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

    /// Offsets are distances, not directions — the sign comes from the pair's ordering at mint time.
    function test_CurveOffsetsAreUnsigned() public view {
        for (uint256 i = 0; i < launcher.bandCount(); i++) {
            (int24 lower, int24 upper,) = launcher.band(i);
            assertGe(lower, 0, "band offsets must be distances from the start tick");
            assertGt(upper, 0);
        }
    }

    // =============================
    //  THE DIRECTORY
    // =============================

    /// The launcher no longer holds a quote registry; it asks the directory on every launch. Which means a
    /// reprice takes effect immediately, with no write to the launcher at all.
    function test_ARepriceInTheDirectoryMovesTheNextLaunch() public {
        (, address firstPool,) = _launch(HIGH_QUOTE);
        assertEq(_currentTick(firstPool), WETH_START_TICK);

        address[] memory tokens = new address[](1);
        int24[] memory ticks = new int24[](1);
        (tokens[0], ticks[0]) = (HIGH_QUOTE, -230_000);
        vm.prank(owner);
        directory.setStartTicks(tokens, ticks);

        (, address secondPool,) = _launch(HIGH_QUOTE);
        assertEq(_currentTick(secondPool), -230_000, "no launcher write was needed");
    }

    function test_LaunchRevertsOnAQuoteTheDirectoryDoesNotList() public {
        HydropumpLauncher.LaunchParams memory params = HydropumpLauncher.LaunchParams({
            name: "Alpha",
            symbol: "ALPHA",
            quoteToken: makeAddr("unlisted"),
            creatorRecipient: creator,
            buyAmount: 0,
            feeUse: bytes32(0)
        });

        vm.prank(creator);
        vm.expectRevert(PairDirectory.QuoteTokenNotEnabled.selector);
        launcher.launch{value: LAUNCH_FEE}(params);
    }

    function test_ReadsPassThroughToTheDirectory() public {
        assertTrue(launcher.isQuoteEnabled(HIGH_QUOTE));
        assertFalse(launcher.isQuoteEnabled(makeAddr("unlisted")));
        assertEq(launcher.poolStartTick(address(uint160(1)), HIGH_QUOTE), WETH_START_TICK);
        assertEq(launcher.poolStartTick(address(type(uint160).max), HIGH_QUOTE), -WETH_START_TICK);
    }

    function test_OnlyAdminCanRepointTheDirectory() public {
        vm.prank(owner);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.setPairDirectory(stranger);

        vm.prank(admin);
        launcher.setPairDirectory(stranger);
        assertEq(launcher.pairDirectory(), stranger);
    }

    // =============================
    //  FEE USE
    // =============================

    /// A creator picks what their fees are spent on at launch, and the escrow records it.
    function test_CreatorPicksAFeeUseAtLaunch() public {
        (address token,,) = _launch(HIGH_QUOTE, FeeUses.AUTO_LP, 0);

        assertEq(registry.feeUseOf(token), FeeUses.AUTO_LP);
        assertEq(registry.implementationFor(token), address(autoLp));
        assertTrue(registry.hasExplicitFeeUse(token));
    }

    /// Leaving it blank is a valid choice, not an error — the launch rides whatever the default is.
    function test_NoChoiceLeavesALaunchOnTheDefault() public {
        (address token,,) = _launch(HIGH_QUOTE, bytes32(0), 0);

        assertEq(registry.feeUseOf(token), FeeUses.CREATOR_BALANCE);
        assertEq(registry.implementationFor(token), address(creatorBalance));
        assertFalse(registry.hasExplicitFeeUse(token), "it is riding the default, not pinned to it");
    }

    function test_AnUnregisteredFeeUseIsRejectedRatherThanIgnored() public {
        HydropumpLauncher.LaunchParams memory params = HydropumpLauncher.LaunchParams({
            name: "Alpha",
            symbol: "ALPHA",
            quoteToken: HIGH_QUOTE,
            creatorRecipient: creator,
            buyAmount: 0,
            feeUse: keccak256("not.a.registered.fee.use")
        });

        vm.prank(creator);
        vm.expectRevert(FeeUseRegistry.UnknownFeeUse.selector);
        launcher.launch{value: LAUNCH_FEE}(params);
    }

    /// A launcher and locker on different escrows would record a choice where it is never spent.
    function test_LaunchRevertsWhenTheEscrowsDisagree() public {
        vm.prank(admin);
        launcher.setFeeUseRegistry(address(0));

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.FeeUseRegistryMismatch.selector);
        launcher.launch{value: LAUNCH_FEE}(_params(creator, FeeUses.AUTO_LP));

        vm.prank(admin);
        launcher.setFeeUseRegistry(stranger);

        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.FeeUseRegistryMismatch.selector);
        launcher.launch{value: LAUNCH_FEE}(_params(creator, FeeUses.AUTO_LP));
    }

    /// A pair with no escrow wired on either side still launches.
    function test_LaunchingStillWorksWithNoEscrowOnEitherSide() public {
        HydropumpLocker freshLocker = HydropumpLocker(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLocker()),
                    abi.encodeCall(HydropumpLocker.initialize, (owner, address(0), buyback, CREATOR_FEE, PROTOCOL_FEE))
                )
            )
        );
        HydropumpLauncher freshLauncher = HydropumpLauncher(
            address(
                new ERC1967Proxy(
                    address(new HydropumpLauncher()),
                    abi.encodeCall(
                        HydropumpLauncher.initialize,
                        (owner, admin, address(freshLocker), address(directory), LAUNCH_FEE)
                    )
                )
            )
        );
        vm.prank(owner);
        freshLocker.setLauncher(address(freshLauncher));

        vm.prank(creator);
        (address token,,) = freshLauncher.launch{value: LAUNCH_FEE}(_params(creator, bytes32(0)));
        assertTrue(token != address(0));
    }

    /// The locker or registry as recipient would trap the creator's share for good.
    function test_LaunchRejectsTheLockerOrRegistryAsRecipient() public {
        vm.startPrank(creator);
        vm.expectRevert(HydropumpLocker.InvalidCreatorRecipient.selector);
        launcher.launch{value: LAUNCH_FEE}(_params(address(locker), FeeUses.CREATOR_BALANCE));
        vm.expectRevert(HydropumpLocker.InvalidCreatorRecipient.selector);
        launcher.launch{value: LAUNCH_FEE}(_params(address(registry), FeeUses.CREATOR_BALANCE));
        vm.stopPrank();
    }

    function test_OnlyAdminCanRepointTheEscrow() public {
        vm.prank(owner);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.setFeeUseRegistry(stranger);

        vm.prank(admin);
        launcher.setFeeUseRegistry(stranger);
        assertEq(launcher.feeUseRegistry(), stranger);
    }

    // =============================
    //  TOKEN ADDRESS
    // =============================

    /// Nothing about a launch is chosen by its address any more. It comes out of `CREATE`, it is not
    /// predictable, and both orientations of the pair it lands in are launchable — which is the whole
    /// reason the curve mirrors.
    function test_AnAddressIsNeverRejectedForWhereItSorts() public {
        (address asToken0,,) = _launch(HIGH_QUOTE);
        (address asToken1,,) = _launch(LOW_QUOTE);

        assertTrue(asToken0 < HIGH_QUOTE, "landed on the token0 side of one");
        assertTrue(asToken1 > LOW_QUOTE, "and the token1 side of the other");
    }

    /// The contract the frontend actually depends on: the address is only knowable after the fact, and
    /// `Launched` is where it is announced. If the event and the return value could disagree, a launch
    /// would write its metadata against a token that does not exist.
    function test_TheLaunchedEventCarriesTheAddressThatWasDeployed() public {
        vm.recordLogs();
        (address token, address pool,) = _launch(HIGH_QUOTE);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature =
            keccak256("Launched(address,address,address,address,int24,uint256[],string,string,bytes32,uint64)");

        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != signature) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), token, "event token must be the real one");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), creator, "and the creator");
        }
        assertTrue(found, "a launch must announce itself");
        assertTrue(pool != address(0));
        assertGt(token.code.length, 0, "and the address it names must hold the token");
    }

    /// Every launch is a fresh `CREATE` from the launcher, so two in a row cannot collide however similar
    /// their parameters are.
    function test_TwoIdenticalLaunchesGetDifferentAddresses() public {
        (address first,,) = _launch(HIGH_QUOTE);
        (address second,,) = _launch(HIGH_QUOTE);

        assertTrue(first != second);
        assertEq(IERC20(first).totalSupply(), launcher.SUPPLY());
        assertEq(IERC20(second).totalSupply(), launcher.SUPPLY());
    }

    /// The launcher points the token at its pool only after the creator's buy, so that buy is the one
    /// that escapes the launch tax, and it exempts the locker so fee collection is never taxed.
    function test_OnlyTheCreatorsBuyEscapesTheLaunchTax() public {
        (address token, address pool,) = _launch(HIGH_QUOTE, bytes32(0), 1e18);
        assertEq(HydropumpToken(token).pool(), pool);
        assertEq(HydropumpToken(token).taxExempt(), address(locker));
        uint256 creatorFill = IERC20(token).balanceOf(creator);
        assertGt(creatorFill, 0);

        MockERC20(HIGH_QUOTE).mint(stranger, 1e9);
        vm.startPrank(stranger);
        IERC20(HIGH_QUOTE).approve(ROUTER, 1e9);
        uint256 poolOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: HIGH_QUOTE,
                tokenOut: token,
                deployer: address(0),
                recipient: stranger,
                deadline: block.timestamp,
                amountIn: 1e9,
                amountOutMinimum: 0,
                limitSqrtPrice: 0
            })
        );
        vm.stopPrank();

        assertEq(IERC20(token).balanceOf(stranger), poolOut - poolOut * 9_900 / 10_000, "a later buy keeps 1%");
    }

    // =============================
    //  FEES + ADMIN
    // =============================

    function test_LaunchFeeIsAMinimumAndSurplusIsKept() public {
        _launch(HIGH_QUOTE);
        assertEq(address(launcher).balance, LAUNCH_FEE);

        vm.prank(creator);
        launcher.launch{value: LAUNCH_FEE + 1 ether}(
            HydropumpLauncher.LaunchParams({
                name: "Beta",
                symbol: "BETA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: creator,
                buyAmount: 0,
                feeUse: bytes32(0)
            })
        );
        assertEq(address(launcher).balance, LAUNCH_FEE * 2 + 1 ether, "surplus is kept, not refunded");

        address sink = makeAddr("sink");
        vm.prank(admin);
        assertEq(launcher.claimLaunchFees(sink), LAUNCH_FEE * 2 + 1 ether);
        assertEq(sink.balance, LAUNCH_FEE * 2 + 1 ether);
    }

    function test_LaunchRevertsBelowTheFee() public {
        vm.prank(creator);
        vm.expectRevert(HydropumpLauncher.InsufficientLaunchFee.selector);
        launcher.launch{value: LAUNCH_FEE - 1}(
            HydropumpLauncher.LaunchParams({
                name: "Alpha",
                symbol: "ALPHA",
                quoteToken: HIGH_QUOTE,
                creatorRecipient: creator,
                buyAmount: 0,
                feeUse: bytes32(0)
            })
        );
    }

    function test_OnlyAdminCanUpgrade() public {
        address newImpl = address(new HydropumpLauncher());

        // The owner runs configuration but must not be able to upgrade.
        vm.prank(owner);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        launcher.upgradeToAndCall(newImpl, "");
    }

    function test_OnlyAdminCanRepointTheLockerOrReassignAdmin() public {
        vm.startPrank(owner);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.setLocker(stranger);
        vm.expectRevert(HydropumpLauncher.NotAdmin.selector);
        launcher.setAdmin(owner);
        vm.stopPrank();

        vm.startPrank(admin);
        launcher.setLocker(stranger);
        launcher.setAdmin(stranger);
        vm.stopPrank();

        assertEq(launcher.locker(), stranger);
        assertEq(launcher.admin(), stranger);
    }

    function test_ImplementationCannotBeInitialized() public {
        HydropumpLauncher impl = new HydropumpLauncher();
        vm.expectRevert();
        impl.initialize(owner, admin, address(locker), address(directory), LAUNCH_FEE);
    }

    function _params(address recipient, bytes32 feeUse) internal pure returns (HydropumpLauncher.LaunchParams memory) {
        return HydropumpLauncher.LaunchParams({
            name: "Alpha",
            symbol: "ALPHA",
            quoteToken: HIGH_QUOTE,
            creatorRecipient: recipient,
            buyAmount: 0,
            feeUse: feeUse
        });
    }
}
