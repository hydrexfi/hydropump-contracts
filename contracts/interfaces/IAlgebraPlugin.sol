// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

/// @notice What `SwapPriceLimit` reads from Algebra's base plugin.
interface IAlgebraPlugin {
    function timepointIndex() external view returns (uint16);

    function lastTimepointTimestamp() external view returns (uint32);

    function timepoints(uint256 index)
        external
        view
        returns (
            bool initialized,
            uint32 blockTimestamp,
            int56 tickCumulative,
            uint88 volatilityCumulative,
            int24 tick,
            int24 averageTick,
            uint16 windowStartIndex
        );
}
