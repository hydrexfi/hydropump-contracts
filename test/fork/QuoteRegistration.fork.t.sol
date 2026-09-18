// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PairDirectory} from "../../contracts/helpers/PairDirectory.sol";

/// @notice Replays the arrays `RegisterQuoteTokens` builds against a real directory, so a reconfiguration
///         is proven on a fork before it is broadcast.
/// @dev The registry lives in `PairDirectory` now rather than the launcher, so this deploys one on the fork
///      rather than pranking a live owner. What it checks is the same: that the generated file applies
///      cleanly, that every entry lands, and that a retired quote ends up registered-but-disabled.
contract QuoteRegistrationForkTest is Test {
    PairDirectory internal directory;
    address internal owner = makeAddr("owner");
    address internal admin = makeAddr("admin");

    function test_ReconfigurationMatchesTheGeneratedList() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);

        directory = PairDirectory(
            address(
                new ERC1967Proxy(address(new PairDirectory()), abi.encodeCall(PairDirectory.initialize, (owner, admin)))
            )
        );

        string memory json = vm.readFile("script/quotes/quote-tokens.json");
        address[] memory active = vm.parseJsonAddressArray(json, ".addresses");
        int256[] memory activeTicks = vm.parseJsonIntArray(json, ".startTicks");
        bool[] memory activeEnabled = vm.parseJsonBoolArray(json, ".enabled");
        address[] memory retired = vm.parseJsonAddressArray(json, ".retired.addresses");
        int256[] memory retiredTicks = vm.parseJsonIntArray(json, ".retired.startTicks");

        uint256 total = active.length + retired.length;
        address[] memory addresses = new address[](total);
        bool[] memory enabled = new bool[](total);
        int24[] memory startTicks = new int24[](total);

        for (uint256 i = 0; i < active.length; i++) {
            (addresses[i], enabled[i], startTicks[i]) = (active[i], activeEnabled[i], int24(activeTicks[i]));
        }
        for (uint256 i = 0; i < retired.length; i++) {
            uint256 at = active.length + i;
            (addresses[at], enabled[at], startTicks[at]) = (retired[i], false, int24(retiredTicks[i]));
        }

        uint256 gasBefore = gasleft();
        vm.prank(owner);
        directory.configureQuoteTokens(addresses, enabled, startTicks);
        console2.log("entries                 ", total);
        console2.log("configureQuoteTokens gas", gasBefore - gasleft());

        for (uint256 i = 0; i < total; i++) {
            (bool isEnabled, int24 tick, uint64 updatedAt) = directory.quoteTokens(addresses[i]);
            assertEq(isEnabled, enabled[i], "enabled mismatch");
            assertEq(tick, startTicks[i], "tick mismatch");
            assertGt(updatedAt, 0, "updatedAt unset");

            // And every listed quote must be launchable in both orientations, which is the reading the
            // launcher actually takes off this file.
            if (isEnabled) {
                assertEq(directory.poolStartTick(address(uint160(1)), addresses[i]), tick);
                assertEq(directory.poolStartTick(address(type(uint160).max), addresses[i]), -tick);
            }
        }

        // A delisting stays registered and stops being launchable, rather than disappearing — asserted
        // over whatever the file marks disabled rather than a named token, since which token that is
        // changes every time the generator runs.
        for (uint256 i = 0; i < total; i++) {
            if (enabled[i]) continue;

            (bool isEnabled,, uint64 updatedAt) = directory.quoteTokens(addresses[i]);
            assertFalse(isEnabled, "a delisted quote must not be launchable");
            assertGt(updatedAt, 0, "a delisted quote must stay registered");
            assertFalse(directory.isEnabled(addresses[i]));
        }
    }

    /// The daily job only ever reprices what is already listed, so replaying the same file through the
    /// refresh path has to leave every active quote where the generator put it.
    function test_RefreshOnlyPathRepricesEveryActiveQuote() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);

        directory = PairDirectory(
            address(
                new ERC1967Proxy(address(new PairDirectory()), abi.encodeCall(PairDirectory.initialize, (owner, admin)))
            )
        );

        string memory json = vm.readFile("script/quotes/quote-tokens.json");
        address[] memory active = vm.parseJsonAddressArray(json, ".addresses");
        int256[] memory activeTicks = vm.parseJsonIntArray(json, ".startTicks");
        bool[] memory activeEnabled = vm.parseJsonBoolArray(json, ".enabled");

        int24[] memory ticks = new int24[](active.length);
        for (uint256 i = 0; i < active.length; i++) {
            ticks[i] = int24(activeTicks[i]);
        }

        vm.startPrank(owner);
        directory.configureQuoteTokens(active, activeEnabled, ticks);

        // A day later, every price has moved a little.
        vm.warp(block.timestamp + 1 days);
        for (uint256 i = 0; i < ticks.length; i++) {
            ticks[i] = ticks[i] + 100;
        }
        directory.setStartTicks(active, ticks);
        vm.stopPrank();

        for (uint256 i = 0; i < active.length; i++) {
            (, int24 tick, uint64 updatedAt) = directory.quoteTokens(active[i]);
            assertEq(tick, int24(activeTicks[i]) + 100, "reprice did not land");
            assertEq(updatedAt, block.timestamp, "and it was stamped");
        }
    }
}
