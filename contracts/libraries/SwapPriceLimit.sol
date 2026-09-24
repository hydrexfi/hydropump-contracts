// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAlgebraPlugin} from "../interfaces/IAlgebraPlugin.sol";
import {IAlgebraPool} from "../interfaces/IAlgebraPool.sol";
import {TickMath} from "./TickMath.sol";

/// @title SwapPriceLimit
/// @notice Stops a fee swap 5% worse than the pool's price at the start of the block, which a same-block
///         sandwich cannot move.
/// @dev The plugin records the tick before each block's first swap; no record this block means spot is it.
///      Without a plugin that records on every swap there is no trustworthy open, so the swap is skipped.
library SwapPriceLimit {
    /// @dev 1.0001^513 ≈ 1.0526, i.e. about 5% worse in either direction.
    int24 internal constant BUFFER_TICKS = 513;

    /// @dev Algebra's `Plugins.BEFORE_SWAP_FLAG`: the plugin runs, and records, before every swap.
    uint16 internal constant BEFORE_SWAP_FLAG = 1;

    /// @return limitSqrtPrice Where the swap must stop.
    /// @return room False when the swap must not be sent: spot is at or past the limit, or no open is known.
    function get(address pool, bool zeroToOne) internal view returns (uint160 limitSqrtPrice, bool room) {
        (uint160 spot, int24 open,, uint16 pluginConfig,,) = IAlgebraPool(pool).globalState();
        if (pluginConfig & BEFORE_SWAP_FLAG == 0) return (0, false);

        IAlgebraPlugin plugin = IAlgebraPlugin(IAlgebraPool(pool).plugin());
        if (address(plugin).code.length == 0) return (0, false);
        try plugin.lastTimepointTimestamp() returns (uint32 last) {
            if (last == uint32(block.timestamp)) {
                (,,,, open,,) = plugin.timepoints(plugin.timepointIndex());
            }
        } catch {
            return (0, false);
        }

        int24 limit = zeroToOne ? open - BUFFER_TICKS : open + BUFFER_TICKS;
        if (limit <= TickMath.MIN_TICK) limit = TickMath.MIN_TICK + 1;
        if (limit >= TickMath.MAX_TICK) limit = TickMath.MAX_TICK - 1;

        limitSqrtPrice = TickMath.getSqrtRatioAtTick(limit);
        room = zeroToOne ? spot > limitSqrtPrice : spot < limitSqrtPrice;
    }
}
