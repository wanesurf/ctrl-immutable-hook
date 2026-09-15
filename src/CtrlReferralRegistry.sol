// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Global, non-enumerable referral payout registry shared by every Ctrl pool.
contract CtrlReferralRegistry {
    error AlreadyRegistered();
    error NotRegistered();
    error ZeroAddress();

    event ReferrerRegistered(address indexed referrer, address indexed payout);
    event ReferralPayoutUpdated(address indexed referrer, address indexed previousPayout, address indexed newPayout);

    mapping(address referrer => address payout) public payoutOf;

    function registerReferrer(address payout) external {
        if (payout == address(0)) revert ZeroAddress();
        if (payoutOf[msg.sender] != address(0)) revert AlreadyRegistered();

        payoutOf[msg.sender] = payout;
        emit ReferrerRegistered(msg.sender, payout);
    }

    function updatePayout(address newPayout) external {
        if (newPayout == address(0)) revert ZeroAddress();
        address previousPayout = payoutOf[msg.sender];
        if (previousPayout == address(0)) revert NotRegistered();

        payoutOf[msg.sender] = newPayout;
        emit ReferralPayoutUpdated(msg.sender, previousPayout, newPayout);
    }
}
