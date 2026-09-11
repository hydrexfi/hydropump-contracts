// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HydropumpAddresses
/// @notice Base mainnet addresses Hydropump launches against
/// @dev Single source of truth for the hardcoded constants used across the protocol
library HydropumpAddresses {
    /// @notice Hydrex (Algebra Integral) NonfungiblePositionManager on Base
    address internal constant NONFUNGIBLE_POSITION_MANAGER = 0xC63E9672f8e93234C73cE954a1d1292e4103Ab86;

    /// @notice Canonical WETH on Base, the quote asset every launch is paired against
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    /// @notice oHYDX, whitelisted by default for `claimAndForward` on every locker
    address internal constant OHYDX = 0xA1136031150E50B015b41f1ca6B2e99e49D8cB78;
}
