// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPairDirectory {
    struct QuoteConfig {
        bool enabled;
        int24 startTick;
        uint64 updatedAt;
    }

    function quoteTokens(address quoteToken) external view returns (bool enabled, int24 startTick, uint64 updatedAt);

    function isEnabled(address quoteToken) external view returns (bool);

    /// @notice The tick a pool for this pair opens at, reverting if the quote is not launchable.
    function requirePoolStartTick(address token, address quoteToken) external view returns (int24);

    function poolStartTick(address token, address quoteToken) external view returns (int24);

    function launchIsToken0(address token, address quoteToken) external pure returns (bool);
}
