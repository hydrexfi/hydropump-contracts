// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAlgebraPlugin} from "../interfaces/IAlgebraPlugin.sol";
import {IAlgebraPool} from "../interfaces/IAlgebraPool.sol";
import {TickMath} from "./TickMath.sol";

/// @title SwapPriceLimit
/// @notice Stops a fee swap 5% worse than the stricter of two prices: the pool's price at the start of the
///         block, and its average over the last `AVERAGE_WINDOW` seconds. A same-block sandwich cannot move
///         the first, and a push held into a later block moves the second only in proportion to how long
///         it is held.
/// @dev The plugin records the tick before each block's first swap; no record this block means spot is it.
///      Without a plugin that records on every swap there is no trustworthy open, so the swap is skipped.
///      A pool younger than the window has no average yet and uses the open alone. The limit is also never
///      more than twice the buffer from spot, so an anchor dragged far from spot cannot pull the limit with it.
library SwapPriceLimit {
    /// @dev 1.0001^513 ≈ 1.0526, i.e. about 5% worse in either direction.
    int24 internal constant BUFFER_TICKS = 513;

    /// @dev Two minutes, about 60 Base blocks.
    uint32 internal constant AVERAGE_WINDOW = 120;

    /// @dev Algebra's `Plugins.BEFORE_SWAP_FLAG`: the plugin runs, and records, before every swap.
    uint16 internal constant BEFORE_SWAP_FLAG = 1;

    /// @return limitSqrtPrice Where the swap must stop.
    /// @return room False when the swap must not be sent: spot is at or past the limit, or no open is known.
    function get(address pool, bool zeroToOne) internal view returns (uint160 limitSqrtPrice, bool room) {
        (uint160 spot, int24 spotTick,, uint16 pluginConfig,,) = IAlgebraPool(pool).globalState();
        if (pluginConfig & BEFORE_SWAP_FLAG == 0) return (0, false);

        IAlgebraPlugin plugin = IAlgebraPlugin(IAlgebraPool(pool).plugin());
        if (address(plugin).code.length == 0) return (0, false);
        int24 open = spotTick;
        try plugin.lastTimepointTimestamp() returns (uint32 last) {
            if (last == uint32(block.timestamp)) {
                (,,,, open,,) = plugin.timepoints(plugin.timepointIndex());
            }
        } catch {
            return (0, false);
        }

        // zeroToOne lowers the tick, so the stricter anchor is the higher one; oneToZero, the lower.
        int24 anchor = open;
        (int24 average, bool known) = _averageTick(plugin);
        if (known) anchor = zeroToOne ? (open > average ? open : average) : (open < average ? open : average);

        int24 limit = zeroToOne ? anchor - BUFFER_TICKS : anchor + BUFFER_TICKS;
        int24 spotBound = zeroToOne ? spotTick - 2 * BUFFER_TICKS : spotTick + 2 * BUFFER_TICKS;
        if (zeroToOne ? spotBound > limit : spotBound < limit) limit = spotBound;
        if (limit <= TickMath.MIN_TICK) limit = TickMath.MIN_TICK + 1;
        if (limit >= TickMath.MAX_TICK) limit = TickMath.MAX_TICK - 1;

        limitSqrtPrice = TickMath.getSqrtRatioAtTick(limit);
        room = zeroToOne ? spot > limitSqrtPrice : spot < limitSqrtPrice;
    }

    /// @dev Time-weighted average tick over `AVERAGE_WINDOW`. `known` is false when the plugin cannot say,
    ///      including `targetIsTooOld` for a pool younger than the window.
    function _averageTick(IAlgebraPlugin plugin) private view returns (int24 average, bool known) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = AVERAGE_WINDOW;
        try plugin.getTimepoints(secondsAgos) returns (int56[] memory tickCumulatives, uint88[] memory) {
            if (tickCumulatives.length != 2) return (0, false);
            average = int24((tickCumulatives[1] - tickCumulatives[0]) / int56(uint56(AVERAGE_WINDOW)));
            known = true;
        } catch {}
    }
}
