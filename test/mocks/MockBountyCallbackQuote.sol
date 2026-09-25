// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {MockERC20} from "./MockERC20.sol";

contract MockBountyCallbackQuote is MockERC20 {
    address private target;
    address private recipient;
    bytes private payload;
    bool public attempted;
    bool public succeeded;
    bytes4 public failure;

    constructor() MockERC20("Callback", "CB") {}

    function setCallback(address target_, address recipient_, bytes calldata payload_) external {
        target = target_;
        recipient = recipient_;
        payload = payload_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == recipient && !attempted) {
            attempted = true;
            bytes memory reason;
            (succeeded, reason) = target.call(payload);
            if (reason.length >= 4) failure = bytes4(reason);
        }
    }
}
