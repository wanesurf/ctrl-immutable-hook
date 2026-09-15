// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CtrlFeeVault} from "../src/CtrlFeeVault.sol";
import {CtrlLaunchRouter} from "../src/CtrlLaunchRouter.sol";
import {CtrlToken} from "../src/CtrlToken.sol";
import {CtrlTestBase} from "./CtrlTestBase.sol";

contract CtrlSwapHandler is IUnlockCallback {
    error NotPoolManager();

    IPoolManager public immutable manager;
    CtrlFeeVault public immutable vault;
    CtrlLaunchRouter public immutable router;
    CtrlToken public immutable token;
    uint256 public totalDonatedClaims;

    constructor(address manager_, address vault_, address router_, address token_) {
        manager = IPoolManager(manager_);
        vault = CtrlFeeVault(vault_);
        router = CtrlLaunchRouter(payable(router_));
        token = CtrlToken(token_);
        token.approve(router_, type(uint256).max);
    }

    function buy(uint96 rawAmount) external {
        uint256 amount = 0.001 ether + (uint256(rawAmount) % 0.05 ether);
        if (address(this).balance < amount) return;
        router.buyExactIn{value: amount}(
            address(token), address(this), address(this), address(0), 1, block.timestamp + 1
        );
    }

    function sell(uint16 rawBps) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance < 10_000) return;
        uint256 amount = balance * (1 + (uint256(rawBps) % 2_000)) / 10_000;
        if (amount == 0) return;
        router.sellExactIn(address(token), amount, address(this), address(this), address(0), 1, block.timestamp + 1);
    }

    function donateClaims(uint96 rawAmount) external {
        uint256 amount = 0.001 ether + (uint256(rawAmount) % 0.05 ether);
        if (address(this).balance < amount) return;

        manager.unlock(abi.encode(amount));
        totalDonatedClaims += amount;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();

        uint256 amount = abi.decode(data, (uint256));
        manager.mint(address(vault), 0, amount);
        manager.settle{value: amount}();
        return bytes("");
    }

    receive() external payable {}
}

contract CtrlLaunchpadInvariantTest is CtrlTestBase {
    address private token;
    uint256 private positionId;
    CtrlSwapHandler private handler;

    function setUp() public override {
        super.setUp();
        (token,, positionId,) = _launch(bytes32("invariant"), 0);
        handler = new CtrlSwapHandler(address(manager), address(vault), address(router), token);
        vm.deal(address(handler), 100 ether);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = CtrlSwapHandler.buy.selector;
        selectors[1] = CtrlSwapHandler.sell.selector;
        selectors[2] = CtrlSwapHandler.donateClaims.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function testDonatedSurplusSurvivesCreatorClaim() public {
        handler.donateClaims(0);
        handler.buy(0);

        uint256 donatedClaims = handler.totalDonatedClaims();
        uint256 creatorClaim = vault.creatorClaimableEth(token, CREATOR_PAYOUT);
        assertGt(creatorClaim, 0);
        assertEq(manager.balanceOf(address(vault), 0) - vault.totalLiabilityEth(), donatedClaims);

        uint256 recipientBalanceBefore = CREATOR_PAYOUT.balance;
        vm.prank(CREATOR_PAYOUT);
        vault.claimCreator(token);

        assertEq(CREATOR_PAYOUT.balance - recipientBalanceBefore, creatorClaim);
        assertEq(manager.balanceOf(address(vault), 0) - vault.totalLiabilityEth(), donatedClaims);
    }

    function invariantVaultClaimsCoverAllLiabilities() public view {
        uint256 claimBalance = manager.balanceOf(address(vault), 0);
        uint256 totalLiability = vault.totalLiabilityEth();

        assertGe(claimBalance, totalLiability);
        assertEq(claimBalance - totalLiability, handler.totalDonatedClaims());
        assertEq(vault.totalClaimableEth() + vault.reservedBountyEth(), vault.totalLiabilityEth());
        assertTrue(vault.isSolvent());
    }

    function invariantHookAndRouterNeverRetainFeeAssets() public view {
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(IERC20(token).balanceOf(address(router)), 0);
    }

    function invariantLaunchAssetsRemainLocked() public view {
        assertEq(positionManager.ownerOf(positionId), address(locker));
        assertGt(positionManager.getPositionLiquidity(positionId), 0);
        assertEq(IERC20(token).balanceOf(address(factory)), 0);
    }
}
