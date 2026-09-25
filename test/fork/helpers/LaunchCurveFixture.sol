// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ForkFixture} from "./ForkFixture.sol";

/// @notice Reads the generated quote list, shared by the launch-curve fork suites.
abstract contract LaunchCurveFixture is ForkFixture {
    struct Quote {
        string symbol;
        address token;
        uint8 decimals;
        int24 startTick;
        uint256 priceUsdE8;
    }

    string internal quotesJson;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        quotesJson = vm.readFile("script/quotes/quote-tokens.json");
    }

    // ---------------------------------------------------------------- helpers

    function _quote(string memory symbol) internal view returns (Quote memory) {
        string[] memory symbols = vm.parseJsonStringArray(quotesJson, ".symbols");
        address[] memory addresses = vm.parseJsonAddressArray(quotesJson, ".addresses");
        int256[] memory ticks = vm.parseJsonIntArray(quotesJson, ".startTicks");
        uint256[] memory decimals = vm.parseJsonUintArray(quotesJson, ".decimals");
        uint256[] memory prices = vm.parseJsonUintArray(quotesJson, ".priceUsdE8");

        for (uint256 i = 0; i < symbols.length; i++) {
            if (keccak256(bytes(symbols[i])) == keccak256(bytes(symbol))) {
                return Quote(symbol, addresses[i], uint8(decimals[i]), int24(ticks[i]), prices[i]);
            }
        }
        revert("quote not in generated list");
    }

    /// @dev B20 tokenized stocks are native Base precompiles rather than deployed contracts, so they hold no
    ///      bytecode — Base's node services their calls natively. revm only sees the 0xef marker byte and
    ///      halts with OpcodeNotFound, so they cannot be exercised on a fork. They work on mainnet; the live
    ///      AAPLc/WETH Algebra pool is proof, and LaunchB20.fork.t.sol covers them against a faithful mock.
    function _isB20(address token) internal view returns (bool) {
        return token.code.length <= 1;
    }

    /// @dev Fully diluted valuation in USD, scaled by 1e8, implied by the pool's current price. Carries 1e18
    ///      of extra precision: a 6-decimal quote prices one whole launch token at about half a raw unit, so
    ///      anything less floors straight to zero.
    function _fdvUsdE8(address pool, Quote memory q, address token) internal view returns (uint256) {
        uint256 quoteRawPerTokenE18 = _priceE18(pool, token, q.token);
        // * USD price (1e8), * 10e9 supply, / 10**decimals, / the 1e18 scale
        return Math.mulDiv(quoteRawPerTokenE18, q.priceUsdE8 * 1e10, 10 ** q.decimals * 1e18);
    }
}
