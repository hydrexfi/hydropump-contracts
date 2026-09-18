// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What a launch's creator share is spent on.
/// @dev The locker transfers every asset in and then calls this once, and the call is expected to spend
///      what it was given — nothing should be left behind afterwards.
///
///      One call with all the assets rather than one per asset, because auto-LP needs both sides of the
///      pair together to deposit into a band.
///
///      May revert. The locker zeroes its balances before calling, so a revert leaves the share booked
///      there rather than stranded here.
interface IFeeUse {
    function onFees(address token, address[] calldata assets, uint256[] calldata amounts) external;
}
