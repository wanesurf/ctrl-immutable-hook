// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ICtrlFeeVault, ICtrlReferralRegistry} from "./interfaces/ICtrlProtocol.sol";

/// @notice Shared V4 hook for every Ctrl V1 pool.
/// @dev The hook charges a 1% custom-accounting fee exclusively in native ETH.
contract CtrlLaunchHookV1 is IHooks {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant TRADING_FEE_BPS = 100;
    uint256 public constant CREATOR_SHARE_BPS = 8_000;
    uint256 public constant REFERRAL_SHARE_BPS = 500;
    uint256 public constant BOUNTY_SHARE_BPS = 250;
    uint256 public constant GRADUATION_THRESHOLD = 4.2 ether;

    uint24 public constant LP_FEE = 0;
    int24 public constant TICK_SPACING = 200;
    int24 public constant INITIAL_TICK = 204_200;
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = INITIAL_TICK;
    bytes32 public constant SEED_HOOK_DATA = keccak256("CTRL_INITIAL_LIQUIDITY_V1");

    struct LaunchState {
        address token;
        address creator;
        address creatorPayout;
        uint256 netEthPrincipal;
        uint256 bountyAccrued;
        uint64 graduatedAt;
        bool seeded;
        bool graduated;
        bool exists;
    }

    struct SwapContext {
        address beneficiary;
        address referrer;
    }

    error AlreadyInitialized();
    error CallbackNotEnabled();
    error InitialLiquidityAlreadySeeded();
    error InvalidInitialLiquidity();
    error InvalidPool();
    error InvalidSwapDelta();
    error NotCreator();
    error NotFactory();
    error NotInitializer();
    error NotPoolManager();
    error PartialFill();
    error TokenAlreadyRegistered();
    error TokenNotRegistered();
    error ZeroAddress();

    event FactoryInitialized(address indexed factory);
    event LaunchRegistered(
        address indexed token, PoolId indexed poolId, address indexed creator, address creatorPayout
    );
    event InitialLiquiditySeeded(address indexed token, PoolId indexed poolId, int256 liquidityDelta);
    event CreatorPayoutUpdated(address indexed token, address indexed previousPayout, address indexed newPayout);
    event FeeAccrued(
        address indexed token,
        PoolId indexed poolId,
        address indexed beneficiary,
        address referrer,
        address referralPayout,
        uint256 feeAmount,
        uint256 creatorAmount,
        uint256 referralAmount,
        uint256 protocolAmount,
        uint256 bountyAmount
    );
    event PrincipalUpdated(
        address indexed token, PoolId indexed poolId, uint256 previousPrincipal, uint256 newPrincipal
    );
    event TokenGraduated(
        address indexed token,
        PoolId indexed poolId,
        address indexed beneficiary,
        uint256 principal,
        uint256 bounty,
        uint64 graduatedAt
    );

    IPoolManager public immutable poolManager;
    address public immutable positionManager;
    ICtrlFeeVault public immutable feeVault;
    ICtrlReferralRegistry public immutable referralRegistry;
    address public immutable initializer;
    address public factory;

    mapping(PoolId poolId => LaunchState launch) private _launches;
    mapping(address token => PoolId poolId) public poolIdForToken;

    constructor(
        address poolManager_,
        address positionManager_,
        address feeVault_,
        address referralRegistry_,
        address initializer_
    ) {
        if (
            poolManager_ == address(0) || positionManager_ == address(0) || feeVault_ == address(0)
                || referralRegistry_ == address(0) || initializer_ == address(0)
        ) {
            revert ZeroAddress();
        }
        poolManager = IPoolManager(poolManager_);
        positionManager = positionManager_;
        feeVault = ICtrlFeeVault(feeVault_);
        referralRegistry = ICtrlReferralRegistry(referralRegistry_);
        initializer = initializer_;

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    function initializeFactory(address factory_) external {
        if (msg.sender != initializer) revert NotInitializer();
        if (factory != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
        emit FactoryInitialized(factory_);
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function poolKey(address token) public view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function registerLaunch(address token, address creator, address creatorPayout)
        external
        onlyFactory
        returns (PoolId poolId)
    {
        if (token == address(0) || creator == address(0) || creatorPayout == address(0)) {
            revert ZeroAddress();
        }
        if (PoolId.unwrap(poolIdForToken[token]) != bytes32(0)) revert TokenAlreadyRegistered();

        PoolKey memory key = poolKey(token);
        poolId = key.toId();
        if (_launches[poolId].exists) revert TokenAlreadyRegistered();

        _launches[poolId] = LaunchState({
            token: token,
            creator: creator,
            creatorPayout: creatorPayout,
            netEthPrincipal: 0,
            bountyAccrued: 0,
            graduatedAt: 0,
            seeded: false,
            graduated: false,
            exists: true
        });
        poolIdForToken[token] = poolId;
        emit LaunchRegistered(token, poolId, creator, creatorPayout);
    }

    function updateCreatorPayout(address token, address newPayout) external onlyFactory {
        if (newPayout == address(0)) revert ZeroAddress();
        LaunchState storage launch = _launchForToken(token);
        address previousPayout = launch.creatorPayout;
        launch.creatorPayout = newPayout;
        emit CreatorPayoutUpdated(token, previousPayout, newPayout);
    }

    function getLaunch(address token) external view returns (LaunchState memory) {
        return _launchForToken(token);
    }

    function getLaunchByPoolId(PoolId poolId) external view returns (LaunchState memory) {
        LaunchState memory launch = _launches[poolId];
        if (!launch.exists) revert TokenNotRegistered();
        return launch;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        LaunchState storage launch = _validatedLaunch(key);
        if (sender != factory || sqrtPriceX96 != TickMath.getSqrtPriceAtTick(INITIAL_TICK)) revert InvalidPool();
        if (launch.seeded) revert InvalidPool();
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        LaunchState storage launch = _validatedLaunch(key);
        if (launch.seeded) revert InitialLiquidityAlreadySeeded();
        if (
            sender != positionManager || params.tickLower != TICK_LOWER || params.tickUpper != TICK_UPPER
                || params.liquidityDelta <= 0 || hookData.length != 32
                || keccak256(hookData) != keccak256(abi.encodePacked(SEED_HOOK_DATA))
        ) {
            revert InvalidInitialLiquidity();
        }

        launch.seeded = true;
        emit InitialLiquiditySeeded(launch.token, key.toId(), params.liquidityDelta);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        LaunchState storage launch = _validatedLaunch(key);
        if (!launch.seeded) revert InvalidPool();

        bool exactInput = params.amountSpecified < 0;
        bool nativeSpecified = exactInput == params.zeroForOne;
        uint256 feeAmount;

        if (nativeSpecified) {
            uint256 nativeAmount = _absoluteAmount(params.amountSpecified);
            feeAmount = exactInput ? _feeFromGross(nativeAmount) : _feeOnTop(nativeAmount);
            _mintAndAccrue(key.toId(), launch, feeAmount, hookData);
        }

        return (
            IHooks.beforeSwap.selector,
            feeAmount == 0 ? BeforeSwapDeltaLibrary.ZERO_DELTA : toBeforeSwapDelta(feeAmount.toInt128(), 0),
            0
        );
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        LaunchState storage launch = _validatedLaunch(key);
        bool exactInput = params.amountSpecified < 0;
        bool buy = params.zeroForOne;
        bool nativeSpecified = exactInput == params.zeroForOne;
        int128 nativeDelta = delta.amount0();
        uint256 feeAmount;
        if ((buy && nativeDelta >= 0) || (!buy && nativeDelta <= 0)) revert InvalidSwapDelta();

        if (nativeSpecified) {
            uint256 requestedNative = _absoluteAmount(params.amountSpecified);
            feeAmount = exactInput ? _feeFromGross(requestedNative) : _feeOnTop(requestedNative);
            uint256 expectedPoolNative = exactInput ? requestedNative - feeAmount : requestedNative + feeAmount;
            if (_absoluteAmount(nativeDelta) != expectedPoolNative) revert PartialFill();
        } else {
            uint256 actualPoolNative = _absoluteAmount(nativeDelta);
            feeAmount = buy ? _feeOnTop(actualPoolNative) : _feeFromGross(actualPoolNative);
            _mintAndAccrue(poolId, launch, feeAmount, hookData);
        }

        _updatePrincipalAndGraduate(poolId, launch, buy, _absoluteAmount(nativeDelta), hookData);
        return (IHooks.afterSwap.selector, nativeSpecified ? int128(0) : feeAmount.toInt128());
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert CallbackNotEnabled();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert CallbackNotEnabled();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert CallbackNotEnabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert CallbackNotEnabled();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert CallbackNotEnabled();
    }

    function _mintAndAccrue(PoolId poolId, LaunchState storage launch, uint256 feeAmount, bytes calldata hookData)
        private
    {
        if (feeAmount == 0) return;

        SwapContext memory context = _parseContext(hookData);
        address referralPayout =
            context.referrer == address(0) ? address(0) : referralRegistry.payoutOf(context.referrer);
        uint256 creatorAmount = FullMath.mulDiv(feeAmount, CREATOR_SHARE_BPS, BPS);
        uint256 referralAmount = referralPayout == address(0) ? 0 : FullMath.mulDiv(feeAmount, REFERRAL_SHARE_BPS, BPS);
        uint256 bountyAmount = launch.graduated ? 0 : FullMath.mulDiv(feeAmount, BOUNTY_SHARE_BPS, BPS);
        uint256 protocolAmount = feeAmount - creatorAmount - referralAmount - bountyAmount;

        poolManager.mint(address(feeVault), 0, feeAmount);
        feeVault.accrue(
            launch.token,
            launch.creatorPayout,
            creatorAmount,
            referralPayout,
            referralAmount,
            protocolAmount,
            bountyAmount
        );
        launch.bountyAccrued += bountyAmount;

        emit FeeAccrued(
            launch.token,
            poolId,
            context.beneficiary,
            context.referrer,
            referralPayout,
            feeAmount,
            creatorAmount,
            referralAmount,
            protocolAmount,
            bountyAmount
        );
    }

    function _updatePrincipalAndGraduate(
        PoolId poolId,
        LaunchState storage launch,
        bool buy,
        uint256 poolNativeAmount,
        bytes calldata hookData
    ) private {
        uint256 previousPrincipal = launch.netEthPrincipal;
        uint256 newPrincipal;

        if (buy) {
            newPrincipal = previousPrincipal + poolNativeAmount;
        } else {
            newPrincipal = poolNativeAmount >= previousPrincipal ? 0 : previousPrincipal - poolNativeAmount;
        }
        launch.netEthPrincipal = newPrincipal;
        emit PrincipalUpdated(launch.token, poolId, previousPrincipal, newPrincipal);

        if (!launch.graduated && previousPrincipal < GRADUATION_THRESHOLD && newPrincipal >= GRADUATION_THRESHOLD) {
            SwapContext memory context = _parseContext(hookData);
            address beneficiary = context.beneficiary;
            if (beneficiary == address(0)) beneficiary = feeVault.treasury();

            uint256 bounty = launch.bountyAccrued;
            launch.bountyAccrued = 0;
            launch.graduated = true;
            launch.graduatedAt = uint64(block.timestamp);
            if (bounty != 0) feeVault.releaseBounty(launch.token, beneficiary, bounty);

            emit TokenGraduated(launch.token, poolId, beneficiary, newPrincipal, bounty, launch.graduatedAt);
        }
    }

    function _validatedLaunch(PoolKey calldata key) private view returns (LaunchState storage launch) {
        if (
            !key.currency0.isAddressZero() || key.fee != LP_FEE || key.tickSpacing != TICK_SPACING
                || address(key.hooks) != address(this)
        ) {
            revert InvalidPool();
        }
        PoolId poolId = key.toId();
        launch = _launches[poolId];
        if (!launch.exists || Currency.unwrap(key.currency1) != launch.token) revert InvalidPool();
    }

    function _launchForToken(address token) private view returns (LaunchState storage launch) {
        PoolId poolId = poolIdForToken[token];
        launch = _launches[poolId];
        if (!launch.exists) revert TokenNotRegistered();
    }

    function _parseContext(bytes calldata hookData) private pure returns (SwapContext memory context) {
        if (hookData.length != 64) return context;

        uint256 beneficiaryWord;
        uint256 referrerWord;
        assembly ("memory-safe") {
            beneficiaryWord := calldataload(hookData.offset)
            referrerWord := calldataload(add(hookData.offset, 0x20))
        }
        if (beneficiaryWord >> 160 != 0 || referrerWord >> 160 != 0) return context;
        context.beneficiary = address(uint160(beneficiaryWord));
        context.referrer = address(uint160(referrerWord));
    }

    function _feeFromGross(uint256 gross) private pure returns (uint256) {
        return FullMath.mulDiv(gross, TRADING_FEE_BPS, BPS);
    }

    function _feeOnTop(uint256 net) private pure returns (uint256) {
        uint256 gross = FullMath.mulDivRoundingUp(net, BPS, BPS - TRADING_FEE_BPS);
        return gross - net;
    }

    function _absoluteAmount(int256 amount) private pure returns (uint256) {
        return amount < 0 ? uint256(-amount) : uint256(amount);
    }
}
