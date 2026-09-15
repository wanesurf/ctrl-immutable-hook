// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CtrlV4Factory} from "../src/CtrlV4Factory.sol";
import {IPermit2Allowance} from "../src/interfaces/ICtrlProtocol.sol";
import {CtrlRobinhoodForkTest} from "./CtrlRobinhoodFork.t.sol";

interface IImmutableHookUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Uses Robinhood's deployed Universal Router 2.1.1 on a read-only fork.
contract CtrlImmutableRouterForkTest is CtrlRobinhoodForkTest {
    address private constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    bytes32 private constant ROUTER_CODEHASH = 0x2ce6aaaf9f4151f5e1cbf774668772f17f532ae11b15e9284fd0a072a8b0fbde;

    // ExactInputSingleParams and ExactOutputSingleParams share this ABI layout.
    // https://github.com/Uniswap/v4-periphery/blob/main/src/interfaces/IV4Router.sol
    struct SingleSwapParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amount;
        uint128 limit;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    function testDeployedUniversalRouterAllFourModesWithEmptyHookData() public {
        assertEq(UNIVERSAL_ROUTER.codehash, ROUTER_CODEHASH, "unexpected Universal Router bytecode");
        CtrlV4Factory.TokenParams memory tokenParams;
        tokenParams.name = "Immutable routing fork test";
        tokenParams.symbol = "CTRL-IMM";
        tokenParams.creatorPayout = CREATOR_PAYOUT;
        (address token,,,) =
            factory.launchToken{value: 0.0005 ether}(tokenParams, keccak256("immutable-universal-router"), 0, 0);
        PoolKey memory key = hook.poolKey(token);

        _swap(key, true, true, uint128(1 ether), 1);
        uint256 bought = IERC20(token).balanceOf(USER);
        assertGt(bought, 0);
        assertEq(vault.totalLiabilityEth(), 0.01 ether);

        vm.prank(USER);
        IERC20(token).approve(PERMIT2, type(uint256).max);
        vm.prank(USER);
        IPermit2Allowance(PERMIT2).approve(token, UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        uint128 sold = uint128(bought / 20);
        uint256 ethBefore = USER.balance;
        _swap(key, false, true, sold, 1);
        assertEq(IERC20(token).balanceOf(USER), bought - sold);
        assertGt(USER.balance, ethBefore);

        uint256 tokensBefore = IERC20(token).balanceOf(USER);
        _swap(key, true, false, uint128(1_000_000 ether), uint128(1 ether));
        assertEq(IERC20(token).balanceOf(USER) - tokensBefore, 1_000_000 ether);

        ethBefore = USER.balance;
        _swap(key, false, false, uint128(0.01 ether), uint128(IERC20(token).balanceOf(USER)));
        assertEq(USER.balance - ethBefore, 0.01 ether);
        assertTrue(vault.isSolvent());
        assertEq(address(hook).balance, 0);
    }

    function _swap(PoolKey memory key, bool buy, bool exactInput, uint128 amount, uint128 limit) private {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(SingleSwapParams(key, buy, amount, limit, 0, bytes("")));
        params[1] = abi.encode(buy ? key.currency0 : key.currency1, exactInput ? amount : limit);
        params[2] = abi.encode(buy ? key.currency1 : key.currency0, exactInput ? limit : amount);
        bytes[] memory inputs = new bytes[](buy ? 2 : 1);
        // SWAP_EXACT_IN/OUT_SINGLE, SETTLE_ALL, TAKE_ALL.
        bytes memory actions = exactInput ? bytes(hex"060c0f") : bytes(hex"080c0f");
        inputs[0] = abi.encode(actions, params);
        // Refund unused native input for exact-output buys using Universal Router SWEEP.
        if (buy) inputs[1] = abi.encode(Currency.unwrap(key.currency0), USER, uint256(0));
        vm.prank(USER);
        IImmutableHookUniversalRouter(UNIVERSAL_ROUTER).execute{value: buy ? (exactInput ? amount : limit) : 0}(
            buy ? bytes(hex"1004") : bytes(hex"10"), inputs, block.timestamp + 1 hours
        );
    }
}
