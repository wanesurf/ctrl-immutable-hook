// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract MockUniversalV4Router is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    struct SwapCallback {
        address payer;
        address recipient;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    IPoolManager public immutable manager;

    constructor(address manager_) {
        manager = IPoolManager(manager_);
    }

    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes memory hookData,
        address recipient,
        uint256 maxTokenInput
    ) external payable returns (BalanceDelta delta) {
        if (maxTokenInput != 0) {
            require(IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), maxTokenInput));
        }

        delta = abi.decode(
            manager.unlock(
                abi.encode(
                    SwapCallback({
                        payer: msg.sender, recipient: recipient, key: key, params: params, hookData: hookData
                    })
                )
            ),
            (BalanceDelta)
        );

        uint256 tokenRefund = IERC20(Currency.unwrap(key.currency1)).balanceOf(address(this));
        if (tokenRefund != 0) {
            require(IERC20(Currency.unwrap(key.currency1)).transfer(msg.sender, tokenRefund));
        }
        uint256 ethRefund = address(this).balance;
        if (ethRefund != 0) {
            (bool sent,) = payable(msg.sender).call{value: ethRefund}("");
            require(sent);
        }
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        SwapCallback memory callback = abi.decode(data, (SwapCallback));
        BalanceDelta delta = manager.swap(callback.key, callback.params, callback.hookData);

        _settleOrTake(callback.key.currency0, callback.recipient, delta.amount0());
        _settleOrTake(callback.key.currency1, callback.recipient, delta.amount1());
        return abi.encode(delta);
    }

    function _settleOrTake(Currency currency, address recipient, int128 delta) private {
        if (delta < 0) {
            uint256 amount = uint256(uint128(-delta));
            if (currency.isAddressZero()) {
                require(address(this).balance >= amount, "insufficient eth");
                manager.settle{value: amount}();
            } else {
                manager.sync(currency);
                require(IERC20(Currency.unwrap(currency)).transfer(address(manager), amount));
                manager.settle();
            }
        } else if (delta > 0) {
            manager.take(currency, recipient, uint256(uint128(delta)));
        }
    }

    receive() external payable {}
}
