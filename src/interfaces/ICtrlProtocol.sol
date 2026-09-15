// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface ICtrlFeeVault {
    function treasury() external view returns (address);

    function accrue(
        address token,
        address creatorPayout,
        uint256 creatorAmount,
        address referralPayout,
        uint256 referralAmount,
        uint256 protocolAmount,
        uint256 bountyAmount
    ) external;

    function releaseBounty(address token, address recipient, uint256 amount) external;
}

interface ICtrlReferralRegistry {
    function payoutOf(address referrer) external view returns (address);
}

interface ICtrlLaunchHook {
    function SEED_HOOK_DATA() external view returns (bytes32);
    function poolKey(address token) external view returns (PoolKey memory);
    function poolIdForToken(address token) external view returns (PoolId);
    function registerLaunch(address token, address creator, address creatorPayout) external returns (PoolId);
    function updateCreatorPayout(address token, address newPayout) external;
}

interface ICtrlPositionLocker {
    function registerPosition(address token, PoolId poolId, uint256 positionId) external;
    function noteTokenDust(address token, uint256 amount) external;
}

interface ICtrlLaunchRouter {
    function buyExactIn(
        address token,
        address recipient,
        address beneficiary,
        address referrer,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external payable returns (uint256 amountOut);
}

interface IPositionManagerMinimal {
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}
