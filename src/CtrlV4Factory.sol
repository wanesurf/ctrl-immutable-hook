// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CtrlToken} from "./CtrlToken.sol";
import {CtrlLiquidityAmounts} from "./libraries/CtrlLiquidityAmounts.sol";
import {
    ICtrlFeeVault,
    ICtrlLaunchHook,
    ICtrlLaunchRouter,
    ICtrlPositionLocker,
    IPermit2Allowance,
    IPositionManagerMinimal
} from "./interfaces/ICtrlProtocol.sol";

/// @notice Permissionless, fixed-configuration Ctrl token factory.
contract CtrlV4Factory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TOKEN_SUPPLY = 1_000_000_000 ether;
    uint256 public constant LAUNCH_FEE = 0.0005 ether;
    int24 public constant INITIAL_TICK = 204_200;
    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = INITIAL_TICK;

    uint256 public constant MAX_URI_LENGTH = 2_048;
    uint256 public constant MAX_DESCRIPTION_LENGTH = 4_096;
    uint256 public constant MAX_SOCIAL_LENGTH = 512;

    uint256 private constant ACTION_MINT_POSITION = 0x02;
    uint256 private constant ACTION_CLOSE_CURRENCY = 0x12;

    struct TokenParams {
        string name;
        string symbol;
        string metadataURI;
        string logoURI;
        string description;
        string website;
        string x;
        string telegram;
        string discord;
        string farcaster;
        address creatorPayout;
        address initialBuyRecipient;
        address initialBuyReferrer;
    }

    struct LaunchRecord {
        address token;
        address creator;
        address creatorPayout;
        PoolId poolId;
        uint256 positionId;
        uint256 supply;
        bool exists;
    }

    error DeadlineExpired();
    error ExternalContractMissing(address target);
    error InitialBuyNeedsSlippage();
    error InsufficientLaunchFee();
    error InvalidMetadata();
    error InvalidPool();
    error InvalidPosition();
    error LaunchesPaused();
    error NotCreator();
    error TokenDeploymentFailed();
    error TokenNotFound();
    error TreasuryTransferFailed();
    error ZeroAddress();

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        PoolId indexed poolId,
        uint256 positionId,
        address creatorPayout,
        uint256 launchFeePaid,
        uint256 initialBuyEth,
        uint256 initialBuyTokens,
        address initialBuyRecipient,
        address initialBuyReferrer,
        bytes32 userSalt
    );
    event CreatorPayoutUpdated(address indexed token, address indexed previousPayout, address indexed newPayout);
    event LaunchPauseUpdated(bool paused);

    IPoolManager public immutable poolManager;
    IPositionManagerMinimal public immutable positionManager;
    IPermit2Allowance public immutable permit2;
    ICtrlPositionLocker public immutable locker;
    ICtrlLaunchHook public immutable hook;
    ICtrlLaunchRouter public immutable launchRouter;
    ICtrlFeeVault public immutable feeVault;

    /// @notice New deployments fail closed until the configured owner explicitly opens launches.
    bool public launchesArePaused = true;
    uint256 public totalLaunches;

    mapping(address token => LaunchRecord record) private _launches;

    constructor(
        address initialOwner,
        address poolManager_,
        address positionManager_,
        address permit2_,
        address locker_,
        address hook_,
        address launchRouter_,
        address feeVault_
    ) Ownable(initialOwner) {
        if (
            initialOwner == address(0) || poolManager_ == address(0) || positionManager_ == address(0)
                || permit2_ == address(0) || locker_ == address(0) || hook_ == address(0) || launchRouter_ == address(0)
                || feeVault_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _requireCode(poolManager_);
        _requireCode(positionManager_);
        _requireCode(permit2_);
        _requireCode(locker_);
        _requireCode(hook_);
        _requireCode(launchRouter_);
        _requireCode(feeVault_);

        poolManager = IPoolManager(poolManager_);
        positionManager = IPositionManagerMinimal(positionManager_);
        permit2 = IPermit2Allowance(permit2_);
        locker = ICtrlPositionLocker(locker_);
        hook = ICtrlLaunchHook(hook_);
        launchRouter = ICtrlLaunchRouter(launchRouter_);
        feeVault = ICtrlFeeVault(feeVault_);
    }

    function launchToken(TokenParams calldata params, bytes32 userSalt, uint256 initialBuyMinimum, uint256 deadline)
        external
        payable
        nonReentrant
        returns (address token, PoolId poolId, uint256 positionId, uint256 initialBuyTokens)
    {
        if (launchesArePaused) revert LaunchesPaused();
        if (msg.value < LAUNCH_FEE) revert InsufficientLaunchFee();
        _validateTokenParams(params);

        uint256 initialBuyEth = msg.value - LAUNCH_FEE;
        if (initialBuyEth != 0) {
            if (initialBuyMinimum == 0) revert InitialBuyNeedsSlippage();
            if (deadline < block.timestamp) revert DeadlineExpired();
        }

        address creatorPayout = params.creatorPayout == address(0) ? msg.sender : params.creatorPayout;
        bytes32 derivedSalt = keccak256(abi.encode(msg.sender, userSalt));
        bytes memory creationCode = _tokenCreationCode(params, msg.sender);
        token = _deployToken(derivedSalt, creationCode);

        poolId = hook.registerLaunch(token, msg.sender, creatorPayout);
        PoolKey memory key = hook.poolKey(token);
        _validatePool(token, key, poolId);
        CtrlToken(token).setPoolId(PoolId.unwrap(poolId));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));

        positionId = _mintAndLockPosition(token, key, poolId);
        _launches[token] = LaunchRecord({
            token: token,
            creator: msg.sender,
            creatorPayout: creatorPayout,
            poolId: poolId,
            positionId: positionId,
            supply: TOKEN_SUPPLY,
            exists: true
        });
        totalLaunches++;

        _payLaunchFee();

        address initialBuyRecipient;
        if (initialBuyEth != 0) {
            initialBuyRecipient = params.initialBuyRecipient == address(0) ? msg.sender : params.initialBuyRecipient;
            initialBuyTokens = launchRouter.buyExactIn{value: initialBuyEth}(
                token, initialBuyRecipient, msg.sender, params.initialBuyReferrer, initialBuyMinimum, deadline
            );
        }

        emit TokenLaunched(
            token,
            msg.sender,
            poolId,
            positionId,
            creatorPayout,
            LAUNCH_FEE,
            initialBuyEth,
            initialBuyTokens,
            initialBuyRecipient,
            params.initialBuyReferrer,
            userSalt
        );
    }

    function predictTokenAddress(TokenParams calldata params, bytes32 userSalt, address creator)
        external
        view
        returns (address)
    {
        if (creator == address(0)) revert ZeroAddress();
        bytes32 derivedSalt = keccak256(abi.encode(creator, userSalt));
        return _computeCreate2Address(derivedSalt, keccak256(_tokenCreationCode(params, creator)));
    }

    function setCreatorPayout(address token, address newPayout) external {
        if (newPayout == address(0)) revert ZeroAddress();
        LaunchRecord storage launched = _launches[token];
        if (!launched.exists) revert TokenNotFound();
        if (launched.creator != msg.sender) revert NotCreator();

        address previousPayout = launched.creatorPayout;
        launched.creatorPayout = newPayout;
        hook.updateCreatorPayout(token, newPayout);
        emit CreatorPayoutUpdated(token, previousPayout, newPayout);
    }

    function setLaunchesPaused(bool paused) external onlyOwner {
        launchesArePaused = paused;
        emit LaunchPauseUpdated(paused);
    }

    function getLaunch(address token) external view returns (LaunchRecord memory) {
        return _launches[token];
    }

    function _mintAndLockPosition(address token, PoolKey memory key, PoolId poolId)
        private
        returns (uint256 positionId)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        uint128 liquidity = CtrlLiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, TOKEN_SUPPLY);
        if (liquidity == 0) revert InvalidPosition();

        positionId = positionManager.nextTokenId();
        IERC20(token).forceApprove(address(permit2), TOKEN_SUPPLY);
        permit2.approve(token, address(positionManager), uint160(TOKEN_SUPPLY), uint48(block.timestamp + 1));

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(ACTION_MINT_POSITION)),
            bytes1(uint8(ACTION_CLOSE_CURRENCY)),
            bytes1(uint8(ACTION_CLOSE_CURRENCY))
        );
        bytes[] memory actionParams = new bytes[](3);
        actionParams[0] = abi.encode(
            key,
            TICK_LOWER,
            TICK_UPPER,
            uint256(liquidity),
            uint128(0),
            uint128(TOKEN_SUPPLY),
            address(locker),
            abi.encodePacked(hook.SEED_HOOK_DATA())
        );
        actionParams[1] = abi.encode(key.currency0);
        actionParams[2] = abi.encode(key.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, actionParams), block.timestamp);

        permit2.approve(token, address(positionManager), 0, 0);
        IERC20(token).forceApprove(address(permit2), 0);
        if (positionManager.ownerOf(positionId) != address(locker)) revert InvalidPosition();
        if (positionManager.getPositionLiquidity(positionId) != liquidity) revert InvalidPosition();

        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust != 0) {
            IERC20(token).safeTransfer(address(locker), dust);
            locker.noteTokenDust(token, dust);
        }
        locker.registerPosition(token, poolId, positionId);
    }

    function _validatePool(address token, PoolKey memory key, PoolId poolId) private view {
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != token || key.fee != 0
                || key.tickSpacing != TICK_SPACING || address(key.hooks) != address(hook)
                || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)
                || PoolId.unwrap(hook.poolIdForToken(token)) != PoolId.unwrap(poolId)
        ) {
            revert InvalidPool();
        }
    }

    function _payLaunchFee() private {
        (bool sent,) = payable(feeVault.treasury()).call{value: LAUNCH_FEE}("");
        if (!sent) revert TreasuryTransferFailed();
    }

    function _tokenCreationCode(TokenParams calldata params, address creator) private pure returns (bytes memory) {
        return abi.encodePacked(
            type(CtrlToken).creationCode,
            abi.encode(
                params.name,
                params.symbol,
                params.metadataURI,
                params.logoURI,
                params.description,
                params.website,
                params.x,
                params.telegram,
                params.discord,
                params.farcaster,
                creator,
                TOKEN_SUPPLY
            )
        );
    }

    function _deployToken(bytes32 salt, bytes memory creationCode) private returns (address token) {
        assembly ("memory-safe") {
            token := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (token == address(0)) revert TokenDeploymentFailed();
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash) private view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }

    function _validateTokenParams(TokenParams calldata params) private pure {
        uint256 nameLength = bytes(params.name).length;
        uint256 symbolLength = bytes(params.symbol).length;
        if (
            nameLength == 0 || nameLength > 64 || symbolLength == 0 || symbolLength > 32
                || bytes(params.metadataURI).length > MAX_URI_LENGTH || bytes(params.logoURI).length > MAX_URI_LENGTH
                || bytes(params.description).length > MAX_DESCRIPTION_LENGTH
                || bytes(params.website).length > MAX_SOCIAL_LENGTH || bytes(params.x).length > MAX_SOCIAL_LENGTH
                || bytes(params.telegram).length > MAX_SOCIAL_LENGTH || bytes(params.discord).length > MAX_SOCIAL_LENGTH
                || bytes(params.farcaster).length > MAX_SOCIAL_LENGTH
        ) {
            revert InvalidMetadata();
        }
    }

    function _requireCode(address target) private view {
        if (target.code.length == 0) revert ExternalContractMissing(target);
    }
}
