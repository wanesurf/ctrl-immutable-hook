// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CtrlTestBase} from "./CtrlTestBase.sol";

/// @notice Routing review regressions against the real V4 core and a generic settlement adapter.
/// @dev The adapter is a test fixture, not Uniswap Labs' deployed Universal Router.
contract CtrlImmutableRoutingTest is CtrlTestBase {
    using BalanceDeltaLibrary for BalanceDelta;

    function testAllFourModesAcceptEmptyHookData() public {
        _exerciseFourModes(false);
    }

    function testAllFourModesPreserveEnabledCoreProtocolFees() public {
        _exerciseFourModes(true);
    }

    function _exerciseFourModes(bool protocolFees) private {
        (address token,,,) = _launch(bytes32("immutable-routing"), 0);
        PoolKey memory key = hook.poolKey(token);
        if (protocolFees) {
            manager.setProtocolFeeController(address(this));
            // Each 12-bit direction is 1000 pips (0.1%), independent of Ctrl's 1% hook fee.
            manager.setProtocolFee(key, uint24(1000 | (1000 << 12)));
        }

        vm.prank(USER);
        BalanceDelta bought =
            universalRouter.swap{value: 1 ether}(key, _params(true, -int256(1 ether)), bytes(""), USER, 0);
        assertEq(bought.amount0(), -int128(1 ether));
        assertGt(bought.amount1(), 0);
        assertEq(vault.totalLiabilityEth(), 0.01 ether);

        uint256 sellAmount = IERC20(token).balanceOf(USER) / 20;
        vm.prank(USER);
        IERC20(token).approve(address(universalRouter), type(uint256).max);
        vm.prank(USER);
        BalanceDelta sold = universalRouter.swap(key, _params(false, -int256(sellAmount)), bytes(""), USER, sellAmount);
        assertEq(sold.amount1(), -int128(int256(sellAmount)));
        assertGt(sold.amount0(), 0);

        vm.prank(USER);
        BalanceDelta exactOutputBuy =
            universalRouter.swap{value: 1 ether}(key, _params(true, int256(1_000_000 ether)), bytes(""), USER, 0);
        assertEq(exactOutputBuy.amount1(), int128(1_000_000 ether));
        assertLt(exactOutputBuy.amount0(), 0);

        uint256 maxTokens = IERC20(token).balanceOf(USER);
        vm.prank(USER);
        BalanceDelta exactOutputSell =
            universalRouter.swap(key, _params(false, int256(0.01 ether)), bytes(""), USER, maxTokens);
        assertEq(exactOutputSell.amount0(), int128(0.01 ether));
        assertLt(exactOutputSell.amount1(), 0);

        assertEq(manager.balanceOf(address(vault), 0), vault.totalLiabilityEth());
        assertTrue(vault.isSolvent());
        assertEq(address(hook).balance, 0);
        assertEq(address(universalRouter).balance, 0);
        assertEq(IERC20(token).balanceOf(address(universalRouter)), 0);
        if (protocolFees) {
            assertGt(manager.protocolFeesAccrued(Currency.wrap(address(0))), 0);
            assertGt(manager.protocolFeesAccrued(Currency.wrap(token)), 0);
        }
    }

    function _params(bool buy, int256 amount) private pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({
            zeroForOne: buy,
            amountSpecified: amount,
            sqrtPriceLimitX96: buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }
}
