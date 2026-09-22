// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "./TickMath.sol";

interface IFeeOraclePool {
    function plugin() external view returns (address);
}

interface IFeeOracle {
    function getTimepoints(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint88[] memory volatilityCumulatives);
}

/// @notice Caller-independent floor for fee swaps. Missing history fails closed.
/// @dev A TWAP bounds execution; it does not eliminate sustained oracle manipulation or all MEV.
library FeeSwapProtection {
    uint32 internal constant WINDOW = 30 minutes;
    uint256 internal constant MIN_OUTPUT_BPS = 9_800;

    error InvalidOracle();
    error DustSwap();

    function minimumOutput(address pool, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256 minimum)
    {
        address plugin = IFeeOraclePool(pool).plugin();
        if (plugin == address(0)) revert InvalidOracle();
        uint32[] memory ago = new uint32[](2);
        ago[0] = WINDOW;
        (int56[] memory cumulative,) = IFeeOracle(plugin).getTimepoints(ago);
        if (cumulative.length != 2) revert InvalidOracle();
        int56 delta;
        // Algebra accumulators are wrapping int56 values.
        unchecked {
            delta = cumulative[1] - cumulative[0];
        }
        int56 average = delta / int56(uint56(WINDOW));
        if (delta < 0 && delta % int56(uint56(WINDOW)) != 0) average--;
        if (average < TickMath.MIN_TICK || average > TickMath.MAX_TICK) revert InvalidOracle();
        uint160 sqrtRatio = TickMath.getSqrtRatioAtTick(int24(average));
        uint256 quote;
        if (sqrtRatio <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatio) * sqrtRatio;
            quote = tokenIn < tokenOut
                ? Math.mulDiv(amountIn, ratioX192, 1 << 192)
                : Math.mulDiv(amountIn, 1 << 192, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtRatio, sqrtRatio, 1 << 64);
            quote = tokenIn < tokenOut
                ? Math.mulDiv(amountIn, ratioX128, 1 << 128)
                : Math.mulDiv(amountIn, 1 << 128, ratioX128);
        }
        minimum = Math.mulDiv(quote, MIN_OUTPUT_BPS, 10_000);
        if (minimum == 0) revert DustSwap();
    }
}
