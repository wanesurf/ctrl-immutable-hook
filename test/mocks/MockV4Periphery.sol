// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPermit2Allowance, IPositionManagerMinimal} from "../../src/interfaces/ICtrlProtocol.sol";

contract MockPermit2 is IPermit2Allowance {
    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }

    mapping(address owner => mapping(address token => mapping(address spender => Allowance))) public allowance;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        allowance[msg.sender][token][spender] = Allowance(amount, expiration);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage approved = allowance[from][token][msg.sender];
        require(approved.expiration >= block.timestamp, "permit expired");
        require(approved.amount >= amount, "permit amount");
        approved.amount -= amount;
        require(IERC20(token).transferFrom(from, to, amount), "transfer failed");
    }
}

contract MockPositionManager is IUnlockCallback, IPositionManagerMinimal {
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    struct PositionConfig {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
    }

    struct CallbackData {
        address payer;
        uint256 positionId;
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        bytes hookData;
    }

    IPoolManager public immutable manager;
    MockPermit2 public immutable permit2;
    uint256 public override nextTokenId = 1;

    mapping(uint256 tokenId => address owner) public override ownerOf;
    mapping(uint256 tokenId => PositionConfig config) private _config;

    constructor(address manager_, address permit2_) {
        manager = IPoolManager(manager_);
        permit2 = MockPermit2(permit2_);
    }

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        require(deadline >= block.timestamp, "deadline");
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        require(actions.length == 3 && uint8(actions[0]) == 0x02, "actions");
        require(params.length == 3, "params");

        (
            PoolKey memory key,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes memory hookData
        ) = abi.decode(params[0], (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));

        uint256 positionId = nextTokenId++;
        ownerOf[positionId] = owner;
        _config[positionId] = PositionConfig(key, tickLower, tickUpper);
        manager.unlock(
            abi.encode(
                CallbackData({
                    payer: msg.sender,
                    positionId: positionId,
                    key: key,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidity: liquidity,
                    amount0Max: amount0Max,
                    amount1Max: amount1Max,
                    hookData: hookData
                })
            )
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager");
        CallbackData memory callback = abi.decode(data, (CallbackData));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            callback.key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: callback.tickLower,
                tickUpper: callback.tickUpper,
                liquidityDelta: callback.liquidity.toInt256(),
                salt: bytes32(callback.positionId)
            }),
            callback.hookData
        );

        _settleDebt(callback.key.currency0, callback.payer, delta.amount0(), callback.amount0Max);
        _settleDebt(callback.key.currency1, callback.payer, delta.amount1(), callback.amount1Max);
        return bytes("");
    }

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity) {
        PositionConfig memory config = _config[tokenId];
        (liquidity,,) = manager.getPositionInfo(
            config.key.toId(), address(this), config.tickLower, config.tickUpper, bytes32(tokenId)
        );
    }

    function _settleDebt(Currency currency, address payer, int128 delta, uint128 amountMax) private {
        if (delta == 0) return;
        require(delta < 0, "unexpected credit");
        uint256 amount = uint256(uint128(-delta));
        require(amount <= amountMax, "max input");

        if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            permit2.transferFrom(payer, address(manager), amount.toUint160(), Currency.unwrap(currency));
            manager.settle();
        }
    }
}
