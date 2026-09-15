// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Ownerless, fixed-supply token created by the Ctrl launchpad.
contract CtrlToken is ERC20 {
    error AlreadyConfigured();
    error NotFactory();
    error ZeroAddress();

    address public immutable creator;
    address public immutable launchFactory;

    string public metadataURI;
    string public logoURI;
    string public description;
    string public website;
    string public x;
    string public telegram;
    string public discord;
    string public farcaster;

    bytes32 public poolId;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory metadataURI_,
        string memory logoURI_,
        string memory description_,
        string memory website_,
        string memory x_,
        string memory telegram_,
        string memory discord_,
        string memory farcaster_,
        address creator_,
        uint256 supply_
    ) ERC20(name_, symbol_) {
        if (creator_ == address(0)) revert ZeroAddress();

        creator = creator_;
        launchFactory = msg.sender;
        metadataURI = metadataURI_;
        logoURI = logoURI_;
        description = description_;
        website = website_;
        x = x_;
        telegram = telegram_;
        discord = discord_;
        farcaster = farcaster_;

        _mint(msg.sender, supply_);
    }

    function setPoolId(bytes32 poolId_) external {
        if (msg.sender != launchFactory) revert NotFactory();
        if (poolId != bytes32(0)) revert AlreadyConfigured();
        if (poolId_ == bytes32(0)) revert AlreadyConfigured();
        poolId = poolId_;
    }
}
