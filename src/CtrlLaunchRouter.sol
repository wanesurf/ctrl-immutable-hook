// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CtrlLaunchHookV1} from "./CtrlLaunchHookV1.sol";

/// @notice Adminless exact-input ETH adapter for Ctrl pools.
/// @dev Universal Router and other V4 routers may be used directly; this router provides
///      predictable full-fill and attribution semantics for Ctrl-native flows.
contract CtrlLaunchRouter is IUnlockCallback, ReentrancyGuard {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    enum Action {
        BuyExactIn,
        SellExactIn
    }

    struct CallbackData {
        Action action;
        address token;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        bytes hookData;
    }

    error DeadlineExpired();
    error InvalidEthSender();
    error InvalidRecipient();
    error NotPoolManager();
    error PartialFill();
    error SlippageExceeded(uint256 amountOut, uint256 minimum);
    error SlippageRequired();
    error ZeroAddress();
    error ZeroAmount();

    event Bought(
        address indexed payer,
        address indexed recipient,
        address indexed token,
        uint256 ethIn,
        uint256 tokensOut,
        address beneficiary,
        address referrer
    );
    event Sold(
        address indexed payer,
        address indexed recipient,
        address indexed token,
        uint256 tokensIn,
        uint256 ethOut,
        address beneficiary,
        address referrer
    );

    IPoolManager public immutable poolManager;
    CtrlLaunchHookV1 public immutable hook;

    constructor(address poolManager_, address hook_) {
        if (poolManager_ == address(0) || hook_ == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(poolManager_);
        hook = CtrlLaunchHookV1(hook_);
    }

    function buyExactIn(
        address token,
        address recipient,
        address beneficiary,
        address referrer,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountOut) {
        if (token == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroAmount();
        if (amountOutMinimum == 0) revert SlippageRequired();
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (recipient == address(0)) recipient = msg.sender;
        if (recipient == address(this)) revert InvalidRecipient();
        if (beneficiary == address(0)) beneficiary = msg.sender;

        amountOut = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        action: Action.BuyExactIn,
                        token: token,
                        recipient: recipient,
                        amountIn: msg.value,
                        amountOutMinimum: amountOutMinimum,
                        hookData: abi.encode(beneficiary, referrer)
                    })
                )
            ),
            (uint256)
        );
        emit Bought(msg.sender, recipient, token, msg.value, amountOut, beneficiary, referrer);
    }

    function sellExactIn(
        address token,
        uint256 amountIn,
        address recipient,
        address beneficiary,
        address referrer,
        uint256 amountOutMinimum,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (token == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        if (amountOutMinimum == 0) revert SlippageRequired();
        if (deadline < block.timestamp) revert DeadlineExpired();
        if (recipient == address(0)) recipient = msg.sender;
        if (recipient == address(this)) revert InvalidRecipient();
        if (beneficiary == address(0)) beneficiary = msg.sender;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = abi.decode(
            poolManager.unlock(
                abi.encode(
                    CallbackData({
                        action: Action.SellExactIn,
                        token: token,
                        recipient: recipient,
                        amountIn: amountIn,
                        amountOutMinimum: amountOutMinimum,
                        hookData: abi.encode(beneficiary, referrer)
                    })
                )
            ),
            (uint256)
        );
        emit Sold(msg.sender, recipient, token, amountIn, amountOut, beneficiary, referrer);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory callback = abi.decode(data, (CallbackData));
        PoolKey memory key = hook.poolKey(callback.token);

        if (callback.action == Action.BuyExactIn) {
            return abi.encode(_buy(key, callback));
        }
        return abi.encode(_sell(key, callback));
    }

    function _buy(PoolKey memory key, CallbackData memory callback) private returns (uint256 amountOut) {
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -callback.amountIn.toInt256(),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            callback.hookData
        );

        uint256 nativeDebt = uint256(uint128(-delta.amount0()));
        amountOut = uint256(uint128(delta.amount1()));
        if (nativeDebt != callback.amountIn) revert PartialFill();
        if (amountOut < callback.amountOutMinimum) {
            revert SlippageExceeded(amountOut, callback.amountOutMinimum);
        }

        // PoolManager's synced-currency slot is transient and shared for the whole
        // transaction. Clear any ERC-20 selected by an earlier batched action so
        // this native settlement cannot be forced down the ERC-20 branch.
        poolManager.sync(CurrencyLibrary.ADDRESS_ZERO);
        poolManager.settle{value: nativeDebt}();
        poolManager.take(key.currency1, callback.recipient, amountOut);
    }

    function _sell(PoolKey memory key, CallbackData memory callback) private returns (uint256 amountOut) {
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -callback.amountIn.toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            callback.hookData
        );

        uint256 tokenDebt = uint256(uint128(-delta.amount1()));
        amountOut = uint256(uint128(delta.amount0()));
        if (tokenDebt != callback.amountIn) revert PartialFill();
        if (amountOut < callback.amountOutMinimum) {
            revert SlippageExceeded(amountOut, callback.amountOutMinimum);
        }

        poolManager.sync(key.currency1);
        IERC20(callback.token).safeTransfer(address(poolManager), tokenDebt);
        poolManager.settle();
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, callback.recipient, amountOut);
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert InvalidEthSender();
    }
}
