// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ICtrlLaunchHook} from "../../src/interfaces/ICtrlProtocol.sol";

contract MockPoolBindingHook is ICtrlLaunchHook {
    using PoolIdLibrary for PoolKey;

    enum Fault {
        None,
        ReturnedPoolId,
        PoolIdForToken,
        Currency0,
        Currency1,
        Fee,
        TickSpacing,
        Hooks
    }

    bytes32 public constant override SEED_HOOK_DATA = keccak256("CTRL_SEED_V1");

    Fault public fault;

    mapping(address token => PoolId poolId) private _poolIds;

    function setFault(Fault fault_) external {
        fault = fault_;
    }

    function poolKey(address token) external view returns (PoolKey memory) {
        return _poolKey(token);
    }

    function poolIdForToken(address token) external view returns (PoolId) {
        return _poolIds[token];
    }

    function registerLaunch(address token, address, address) external returns (PoolId poolId) {
        poolId = _poolKey(token).toId();

        if (fault == Fault.ReturnedPoolId) {
            poolId = _differentPoolId(poolId, 1);
            _poolIds[token] = poolId;
        } else if (fault == Fault.PoolIdForToken) {
            _poolIds[token] = _differentPoolId(poolId, 2);
        } else {
            _poolIds[token] = poolId;
        }
    }

    function updateCreatorPayout(address, address) external pure {}

    function _poolKey(address token) private view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(this))
        });

        if (fault == Fault.Currency0) {
            key.currency0 = Currency.wrap(address(1));
        } else if (fault == Fault.Currency1) {
            key.currency1 = Currency.wrap(address(2));
        } else if (fault == Fault.Fee) {
            key.fee = 1;
        } else if (fault == Fault.TickSpacing) {
            key.tickSpacing = 201;
        } else if (fault == Fault.Hooks) {
            key.hooks = IHooks(address(3));
        }
    }

    function _differentPoolId(PoolId poolId, uint256 mask) private pure returns (PoolId) {
        return PoolId.wrap(bytes32(uint256(PoolId.unwrap(poolId)) ^ mask));
    }
}
