// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title FeeUses
/// @notice Canonical ids for what a launch's creator share can be spent on.
/// @dev Ids rather than addresses, so an implementation can be swapped once instead of repointed across
///      every launch that chose it. Hashed from a name so a new one can be added without coordinating a
///      number, and so the id reads as itself in a trace.
library FeeUses {
    /// @notice A balance the creator withdraws. What a launch gets if it expresses no preference.
    bytes32 internal constant CREATOR_BALANCE = keccak256("hydropump.feeuse.creator-balance");

    /// @notice Fees go back into the launch's own locked curve and stay there.
    bytes32 internal constant AUTO_LP = keccak256("hydropump.feeuse.auto-lp");

    /// @notice Fees buy the launch token in its own pool and burn it.
    bytes32 internal constant BUYBACK_BURN = keccak256("hydropump.feeuse.buyback-burn");
}
