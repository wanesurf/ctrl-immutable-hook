// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CtrlFeeVault} from "../src/CtrlFeeVault.sol";
import {CtrlLaunchHookV1} from "../src/CtrlLaunchHookV1.sol";
import {CtrlLaunchRouter} from "../src/CtrlLaunchRouter.sol";
import {CtrlPositionLocker} from "../src/CtrlPositionLocker.sol";
import {CtrlToken} from "../src/CtrlToken.sol";
import {CtrlV4Factory} from "../src/CtrlV4Factory.sol";
import {CtrlTestBase} from "./CtrlTestBase.sol";

contract RevertingPayoutRecipient {
    error EthRejected();

    function claimCreator(CtrlFeeVault vault, address token) external returns (uint256) {
        return vault.claimCreator(token);
    }

    receive() external payable {
        revert EthRejected();
    }
}

contract CrossRoleReentrantPayout {
    CtrlFeeVault public immutable vault;

    address public claimToken;
    bool public attackEnabled;
    uint256 public attempts;
    uint256 public unexpectedSuccesses;

    constructor(CtrlFeeVault vault_) {
        vault = vault_;
    }

    function arm(address token) external {
        claimToken = token;
        attackEnabled = true;
    }

    function disarm() external {
        attackEnabled = false;
    }

    function claimCreator() external returns (uint256) {
        return vault.claimCreator(claimToken);
    }

    function claimReferral() external returns (uint256) {
        return vault.claimReferral();
    }

    function claimProtocol() external returns (uint256) {
        return vault.claimProtocol();
    }

    function claimGraduationBounty() external returns (uint256) {
        return vault.claimGraduationBounty();
    }

    receive() external payable {
        if (!attackEnabled) return;

        _attempt(abi.encodeWithSelector(CtrlFeeVault.claimCreator.selector, claimToken));
        _attempt(abi.encodeWithSelector(CtrlFeeVault.claimReferral.selector));
        _attempt(abi.encodeWithSelector(CtrlFeeVault.claimProtocol.selector));
        _attempt(abi.encodeWithSelector(CtrlFeeVault.claimGraduationBounty.selector));
    }

    function _attempt(bytes memory callData) private {
        attempts++;
        (bool success,) = address(vault).call(callData);
        if (success) unexpectedSuccesses++;
    }
}

contract CtrlLaunchpadTest is CtrlTestBase {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    function testFactoryDeploysPaused() public {
        CtrlV4Factory freshFactory = new CtrlV4Factory(
            address(this),
            address(manager),
            address(positionManager),
            address(permit2),
            address(locker),
            address(hook),
            address(router),
            address(vault)
        );

        assertTrue(freshFactory.launchesArePaused());
    }

    function testLaunchCreatesFixedPoolAndPermanentlyLocksPosition() public {
        uint256 treasuryBefore = TREASURY.balance;
        (address token, PoolId poolId, uint256 positionId,) = _launch(bytes32("locked"), 0);
        CtrlV4Factory.LaunchRecord memory launched = factory.getLaunch(token);
        CtrlPositionLocker.LockedPosition memory locked = locker.getPosition(token);
        PoolKey memory key = hook.poolKey(token);
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(poolId);

        assertTrue(launched.exists);
        assertEq(launched.creator, address(this));
        assertEq(launched.creatorPayout, CREATOR_PAYOUT);
        assertEq(PoolId.unwrap(launched.poolId), PoolId.unwrap(poolId));
        assertEq(positionManager.ownerOf(positionId), address(locker));
        assertEq(locked.positionId, positionId);
        assertEq(PoolId.unwrap(locked.poolId), PoolId.unwrap(poolId));
        assertGt(positionManager.getPositionLiquidity(positionId), 0);
        assertEq(CtrlToken(token).totalSupply(), 1_000_000_000 ether);
        assertEq(CtrlToken(token).balanceOf(address(factory)), 0);
        assertLt(CtrlToken(token).balanceOf(address(locker)), 100_000);
        assertEq(CtrlToken(token).poolId(), PoolId.unwrap(poolId));
        assertEq(key.fee, 0);
        assertEq(key.tickSpacing, 200);
        assertEq(address(key.hooks), address(hook));
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(204_200));
        assertEq(tick, 204_200);
        assertEq(lpFee, 0);
        assertEq(TREASURY.balance - treasuryBefore, 0.0005 ether);
        assertEq(factory.totalLaunches(), 1);
    }

    function testLaunchStoresMetadataWithoutTradingControls() public {
        (address token,,,) = _launch(bytes32("metadata"), 0);
        CtrlToken launched = CtrlToken(token);

        assertEq(launched.name(), "Ctrl Token");
        assertEq(launched.symbol(), "CTRL");
        assertEq(launched.metadataURI(), "ipfs://ctrl-token");
        assertEq(launched.logoURI(), "ipfs://ctrl-logo");
        assertEq(launched.description(), "A token launched with Ctrl");
        assertEq(launched.website(), "https://ctrl.finance");
        assertEq(launched.x(), "https://x.com/ctrlfinance");
        assertEq(launched.telegram(), "https://t.me/ctrlfinance");
        assertEq(launched.discord(), "https://discord.gg/ctrl");
        assertEq(launched.farcaster(), "ctrl");
    }

    function testPredictAddressMatchesCreatorScopedCreate2Launch() public {
        CtrlV4Factory.TokenParams memory params = _params();
        bytes32 salt = keccak256("predict");
        address predicted = factory.predictTokenAddress(params, salt, address(this));
        (address token,,,) = factory.launchToken{value: 0.0005 ether}(params, salt, 0, 0);
        assertEq(token, predicted);
    }

    function testRevertingTreasuryRollsBackEntireLaunch() public {
        RevertingPayoutRecipient revertingTreasury = new RevertingPayoutRecipient();
        vault.setTreasury(address(revertingTreasury));

        CtrlV4Factory.TokenParams memory params = _params();
        bytes32 salt = keccak256("reverting-treasury");
        address predicted = factory.predictTokenAddress(params, salt, address(this));
        uint256 launchesBefore = factory.totalLaunches();
        uint256 nextPositionBefore = positionManager.nextTokenId();

        vm.expectRevert(CtrlV4Factory.TreasuryTransferFailed.selector);
        factory.launchToken{value: 0.0005 ether}(params, salt, 0, 0);

        assertEq(predicted.code.length, 0);
        assertEq(factory.totalLaunches(), launchesBefore);
        assertFalse(factory.getLaunch(predicted).exists);
        assertEq(PoolId.unwrap(hook.poolIdForToken(predicted)), bytes32(0));
        assertFalse(locker.getPosition(predicted).exists);
        assertEq(positionManager.nextTokenId(), nextPositionBefore);
        assertEq(address(revertingTreasury).balance, 0);

        vm.expectRevert(CtrlLaunchHookV1.TokenNotRegistered.selector);
        hook.getLaunch(predicted);
    }

    function testExactInputBuyChargesOnePercentInEthAndSplitsFees() public {
        (address token,,,) = _launch(bytes32("buy-fee"), 0);

        vm.prank(USER);
        uint256 tokensOut =
            router.buyExactIn{value: 1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        CtrlLaunchHookV1.LaunchState memory launch = hook.getLaunch(token);
        assertGt(tokensOut, 0);
        assertEq(CtrlToken(token).balanceOf(USER), tokensOut);
        assertEq(launch.netEthPrincipal, 0.99 ether);
        assertEq(vault.creatorClaimableEth(token, CREATOR_PAYOUT), 0.008 ether);
        assertEq(vault.protocolClaimableEth(TREASURY), 0.00175 ether);
        assertEq(vault.reservedBountyEthForToken(token), 0.00025 ether);
        assertEq(vault.reservedBountyEth(), 0.00025 ether);
        assertEq(vault.totalLiabilityEth(), 0.01 ether);
        assertEq(manager.balanceOf(address(vault), 0), 0.01 ether);
        assertTrue(vault.isSolvent());
    }

    function testExactInputBuyClearsPreviouslySyncedCurrency() public {
        (address token,,,) = _launch(bytes32("dirty-sync-buy"), 0);

        // The PoolManager sync slot is transaction-scoped. A prior batched action or
        // account-abstraction user operation can leave a non-native currency selected.
        manager.sync(Currency.wrap(token));

        vm.prank(USER);
        uint256 tokensOut =
            router.buyExactIn{value: 1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        assertGt(tokensOut, 0);
        assertEq(CtrlToken(token).balanceOf(USER), tokensOut);
        assertEq(manager.balanceOf(address(vault), 0), 0.01 ether);
        assertTrue(vault.isSolvent());
    }

    function testReferralIsGlobalAcrossTokensAndClaimedByPayoutOnly() public {
        vm.prank(REFERRER);
        registry.registerReferrer(REFERRAL_PAYOUT);
        (address firstToken,,,) = _launch(bytes32("referral-a"), 0);
        (address secondToken,,,) = _launch(bytes32("referral-b"), 0);

        vm.prank(USER);
        router.buyExactIn{value: 1 ether}(firstToken, USER, USER, REFERRER, 1, block.timestamp + 1 hours);
        vm.prank(USER);
        router.buyExactIn{value: 0.5 ether}(secondToken, USER, USER, REFERRER, 1, block.timestamp + 1 hours);

        assertEq(registry.payoutOf(REFERRER), REFERRAL_PAYOUT);
        assertEq(vault.creatorClaimableEth(firstToken, CREATOR_PAYOUT), 0.008 ether);
        assertEq(vault.creatorClaimableEth(secondToken, CREATOR_PAYOUT), 0.004 ether);
        assertEq(vault.referralClaimableEth(REFERRAL_PAYOUT), 0.00075 ether);
        assertEq(vault.protocolClaimableEth(TREASURY), 0.001875 ether);
        assertEq(vault.reservedBountyEth(), 0.000375 ether);

        vm.prank(USER);
        vm.expectRevert(CtrlFeeVault.NoFees.selector);
        vault.claimReferral();

        uint256 payoutBefore = REFERRAL_PAYOUT.balance;
        vm.prank(REFERRAL_PAYOUT);
        uint256 claimed = vault.claimReferral();
        assertEq(claimed, 0.00075 ether);
        assertEq(REFERRAL_PAYOUT.balance - payoutBefore, claimed);
        assertEq(vault.referralClaimableEth(REFERRAL_PAYOUT), 0);
    }

    function testCreatorClaimsEachTokenIndependentlyAndNoOneCanClaimForThem() public {
        (address firstToken,,,) = _launch(bytes32("claim-a"), 0);
        (address secondToken,,,) = _launch(bytes32("claim-b"), 0);
        vm.prank(USER);
        router.buyExactIn{value: 1 ether}(firstToken, USER, USER, address(0), 1, block.timestamp + 1 hours);
        vm.prank(USER);
        router.buyExactIn{value: 0.5 ether}(secondToken, USER, USER, address(0), 1, block.timestamp + 1 hours);

        vm.prank(USER);
        vm.expectRevert(CtrlFeeVault.NoFees.selector);
        vault.claimCreator(firstToken);

        uint256 recipientBefore = CREATOR_PAYOUT.balance;
        vm.prank(CREATOR_PAYOUT);
        uint256 claimed = vault.claimCreator(firstToken);

        assertEq(claimed, 0.008 ether);
        assertEq(CREATOR_PAYOUT.balance - recipientBefore, claimed);
        assertEq(vault.creatorClaimableEth(firstToken, CREATOR_PAYOUT), 0);
        assertEq(vault.creatorClaimableEth(secondToken, CREATOR_PAYOUT), 0.004 ether);
        assertEq(manager.balanceOf(address(vault), 0), 0.007 ether);
        assertTrue(vault.isSolvent());
    }

    function testRevertingCreditedRecipientCannotCorruptAccountingOrBlockOtherClaims() public {
        RevertingPayoutRecipient revertingRecipient = new RevertingPayoutRecipient();
        CtrlV4Factory.TokenParams memory params = _params();
        params.creatorPayout = address(revertingRecipient);

        (address revertingToken,,,) =
            factory.launchToken{value: 0.0005 ether}(params, bytes32("reverting-recipient"), 0, 0);
        (address unrelatedToken,,,) = _launch(bytes32("unrelated-recipient"), 0);

        vm.prank(USER);
        router.buyExactIn{value: 1 ether}(revertingToken, USER, USER, address(0), 1, block.timestamp + 1 hours);
        vm.prank(USER);
        router.buyExactIn{value: 0.5 ether}(unrelatedToken, USER, USER, address(0), 1, block.timestamp + 1 hours);

        uint256 revertingClaim = vault.creatorClaimableEth(revertingToken, address(revertingRecipient));
        uint256 unrelatedClaim = vault.creatorClaimableEth(unrelatedToken, CREATOR_PAYOUT);
        uint256 totalClaimableBefore = vault.totalClaimableEth();
        uint256 totalLiabilityBefore = vault.totalLiabilityEth();
        uint256 backingBefore = manager.balanceOf(address(vault), 0);

        vm.expectRevert();
        revertingRecipient.claimCreator(vault, revertingToken);

        assertGt(revertingClaim, 0);
        assertEq(vault.creatorClaimableEth(revertingToken, address(revertingRecipient)), revertingClaim);
        assertEq(vault.creatorClaimableEth(unrelatedToken, CREATOR_PAYOUT), unrelatedClaim);
        assertEq(vault.totalClaimableEth(), totalClaimableBefore);
        assertEq(vault.totalLiabilityEth(), totalLiabilityBefore);
        assertEq(manager.balanceOf(address(vault), 0), backingBefore);
        assertTrue(vault.isSolvent());

        uint256 unrelatedBalanceBefore = CREATOR_PAYOUT.balance;
        vm.prank(CREATOR_PAYOUT);
        assertEq(vault.claimCreator(unrelatedToken), unrelatedClaim);
        assertEq(CREATOR_PAYOUT.balance - unrelatedBalanceBefore, unrelatedClaim);
        assertEq(vault.creatorClaimableEth(revertingToken, address(revertingRecipient)), revertingClaim);
        assertTrue(vault.isSolvent());
    }

    function testCrossRoleReentrancyCannotEscapeClaimGuard() public {
        CrossRoleReentrantPayout recipient = new CrossRoleReentrantPayout(vault);
        vault.setTreasury(address(recipient));
        vm.prank(REFERRER);
        registry.registerReferrer(address(recipient));

        CtrlV4Factory.TokenParams memory params = _params();
        params.creatorPayout = address(recipient);
        (address token,,,) = factory.launchToken{value: 0.0005 ether}(params, bytes32("reentrant-payout"), 0, 0);

        vm.prank(USER);
        router.buyExactIn{value: 4.25 ether}(token, USER, address(recipient), REFERRER, 1, block.timestamp + 1 hours);

        uint256 creatorClaim = vault.creatorClaimableEth(token, address(recipient));
        uint256 referralClaim = vault.referralClaimableEth(address(recipient));
        uint256 protocolClaim = vault.protocolClaimableEth(address(recipient));
        uint256 bountyClaim = vault.bountyClaimableEth(address(recipient));
        uint256 liabilityBefore = vault.totalLiabilityEth();
        uint256 backingBefore = manager.balanceOf(address(vault), 0);
        uint256 balanceBefore = address(recipient).balance;

        assertGt(creatorClaim, 0);
        assertGt(referralClaim, 0);
        assertGt(protocolClaim, 0);
        assertGt(bountyClaim, 0);

        recipient.arm(token);
        assertEq(recipient.claimCreator(), creatorClaim);

        assertEq(recipient.attempts(), 4);
        assertEq(recipient.unexpectedSuccesses(), 0);
        assertEq(address(recipient).balance - balanceBefore, creatorClaim);
        assertEq(vault.creatorClaimableEth(token, address(recipient)), 0);
        assertEq(vault.referralClaimableEth(address(recipient)), referralClaim);
        assertEq(vault.protocolClaimableEth(address(recipient)), protocolClaim);
        assertEq(vault.bountyClaimableEth(address(recipient)), bountyClaim);
        assertEq(vault.totalLiabilityEth(), liabilityBefore - creatorClaim);
        assertEq(manager.balanceOf(address(vault), 0), backingBefore - creatorClaim);
        assertTrue(vault.isSolvent());

        recipient.disarm();
        assertEq(recipient.claimReferral(), referralClaim);
        assertEq(recipient.claimProtocol(), protocolClaim);
        assertEq(recipient.claimGraduationBounty(), bountyClaim);
        assertEq(vault.totalLiabilityEth(), 0);
        assertEq(manager.balanceOf(address(vault), 0), 0);
        assertTrue(vault.isSolvent());
    }

    function testCreatorClaimDoesNotAlsoClaimReferralBalanceForSamePayout() public {
        vm.prank(REFERRER);
        registry.registerReferrer(CREATOR_PAYOUT);
        (address token,,,) = _launch(bytes32("separate-roles"), 0);
        vm.prank(USER);
        router.buyExactIn{value: 1 ether}(token, USER, USER, REFERRER, 1, block.timestamp + 1 hours);

        vm.prank(CREATOR_PAYOUT);
        uint256 creatorClaimed = vault.claimCreator(token);

        assertEq(creatorClaimed, 0.008 ether);
        assertEq(vault.creatorClaimableEth(token, CREATOR_PAYOUT), 0);
        assertEq(vault.referralClaimableEth(CREATOR_PAYOUT), 0.0005 ether);
    }

    function testCreatorCanRedirectOnlyFutureFees() public {
        (address token,,,) = _launch(bytes32("redirect"), 0);
        vm.prank(USER);
        router.buyExactIn{value: 1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        factory.setCreatorPayout(token, UPDATED_PAYOUT);
        vm.prank(USER);
        router.buyExactIn{value: 0.1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        assertEq(vault.creatorClaimableEth(token, CREATOR_PAYOUT), 0.008 ether);
        assertEq(vault.creatorClaimableEth(token, UPDATED_PAYOUT), 0.0008 ether);
        assertEq(factory.getLaunch(token).creatorPayout, UPDATED_PAYOUT);
        assertEq(hook.getLaunch(token).creatorPayout, UPDATED_PAYOUT);
    }

    function testProtocolFeesCanOnlyBeClaimedByCreditedTreasury() public {
        (address token,,,) = _launch(bytes32("protocol-claim"), 0);
        vm.prank(USER);
        router.buyExactIn{value: 1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        vm.prank(USER);
        vm.expectRevert(CtrlFeeVault.NoFees.selector);
        vault.claimProtocol();

        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(TREASURY);
        uint256 claimed = vault.claimProtocol();
        assertEq(claimed, 0.00175 ether);
        assertEq(TREASURY.balance - treasuryBefore, claimed);
        assertEq(vault.protocolClaimableEth(TREASURY), 0);
    }

    function testExactInputSellChargesFeeOnGrossEthOutput() public {
        (address token,,,) = _launch(bytes32("sell"), 0);
        vm.prank(USER);
        router.buyExactIn{value: 1.5 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        uint256 tokensToSell = CtrlToken(token).balanceOf(USER) / 10;
        vm.prank(USER);
        IERC20(token).approve(address(router), tokensToSell);
        uint256 claimsBefore = manager.balanceOf(address(vault), 0);
        uint256 principalBefore = hook.getLaunch(token).netEthPrincipal;

        vm.prank(USER);
        uint256 netEthOut =
            router.sellExactIn(token, tokensToSell, USER, USER, address(0), 1, block.timestamp + 1 hours);

        uint256 fee = manager.balanceOf(address(vault), 0) - claimsBefore;
        uint256 grossEthOut = netEthOut + fee;
        assertEq(fee, grossEthOut / 100);
        assertEq(hook.getLaunch(token).netEthPrincipal, principalBefore - grossEthOut);
        assertEq(USER.balance, 1_000 ether - 1.5 ether + netEthOut);
    }

    function testRouterRejectsItselfAsBuyRecipient() public {
        (address token,,,) = _launch(bytes32("router-buy-recipient"), 0);

        vm.prank(USER);
        vm.expectRevert(CtrlLaunchRouter.InvalidRecipient.selector);
        router.buyExactIn{value: 1 ether}(token, address(router), USER, address(0), 1, block.timestamp + 1 hours);

        assertEq(CtrlToken(token).balanceOf(address(router)), 0);
        assertEq(CtrlToken(token).balanceOf(USER), 0);
        assertEq(manager.balanceOf(address(vault), 0), 0);
    }

    function testRouterRejectsItselfAsSellRecipientBeforeTakingTokens() public {
        (address token,,,) = _launch(bytes32("router-sell-recipient"), 0);
        vm.prank(USER);
        router.buyExactIn{value: 1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        uint256 amountIn = CtrlToken(token).balanceOf(USER) / 10;
        vm.prank(USER);
        IERC20(token).approve(address(router), amountIn);
        uint256 userTokensBefore = CtrlToken(token).balanceOf(USER);
        uint256 routerBalanceBefore = address(router).balance;
        uint256 liabilityBefore = vault.totalLiabilityEth();

        vm.prank(USER);
        vm.expectRevert(CtrlLaunchRouter.InvalidRecipient.selector);
        router.sellExactIn(token, amountIn, address(router), USER, address(0), 1, block.timestamp + 1 hours);

        assertEq(CtrlToken(token).balanceOf(USER), userTokensBefore);
        assertEq(CtrlToken(token).balanceOf(address(router)), 0);
        assertEq(address(router).balance, routerBalanceBefore);
        assertEq(vault.totalLiabilityEth(), liabilityBefore);
    }

    function testGraduationTriggersAutomaticallyAndCreditsCrossingBuyer() public {
        (address token,,,) = _launch(bytes32("graduation"), 0);

        vm.prank(USER);
        router.buyExactIn{value: 4.25 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        CtrlLaunchHookV1.LaunchState memory launched = hook.getLaunch(token);
        assertTrue(launched.graduated);
        assertEq(launched.netEthPrincipal, 4.2075 ether);
        assertEq(launched.bountyAccrued, 0);
        assertEq(launched.graduatedAt, block.timestamp);
        assertEq(vault.reservedBountyEth(), 0);
        assertEq(vault.reservedBountyEthForToken(token), 0);
        assertEq(vault.bountyClaimableEth(USER), 0.0010625 ether);

        uint256 treasuryBefore = vault.protocolClaimableEth(TREASURY);
        vm.prank(USER);
        router.buyExactIn{value: 0.1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);
        assertEq(vault.bountyClaimableEth(USER), 0.0010625 ether);
        assertEq(vault.protocolClaimableEth(TREASURY) - treasuryBefore, 0.0002 ether);

        uint256 winnerBefore = USER.balance;
        vm.prank(USER);
        uint256 claimed = vault.claimGraduationBounty();
        assertEq(claimed, 0.0010625 ether);
        assertEq(USER.balance - winnerBefore, claimed);
        assertEq(vault.bountyClaimableEth(USER), 0);
    }

    function testGenericRouterWithEmptyHookDataTradesAndFallsBackOnGraduation() public {
        (address token,,,) = _launch(bytes32("generic"), 0);
        PoolKey memory key = hook.poolKey(token);

        vm.prank(USER);
        universalRouter.swap{value: 4.25 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(4.25 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            bytes(""),
            USER,
            0
        );

        assertTrue(hook.getLaunch(token).graduated);
        assertEq(vault.protocolClaimableEth(TREASURY), 0.0074375 ether);
        assertEq(vault.bountyClaimableEth(TREASURY), 0.0010625 ether);
    }

    function testExactOutputBuyChargesFeeOnTopOfActualEthInput() public {
        (address token,,,) = _launch(bytes32("exact-out-buy"), 0);
        PoolKey memory key = hook.poolKey(token);
        uint256 tokenOut = 1_000_000 ether;
        uint256 claimsBefore = manager.balanceOf(address(vault), 0);

        vm.prank(USER);
        BalanceDelta delta = universalRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: int256(tokenOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            abi.encode(USER, address(0)),
            USER,
            0
        );

        uint256 grossInput = uint256(uint128(-delta.amount0()));
        uint256 poolInput = hook.getLaunch(token).netEthPrincipal;
        uint256 fee = manager.balanceOf(address(vault), 0) - claimsBefore;
        assertEq(uint256(uint128(delta.amount1())), tokenOut);
        assertEq(grossInput, poolInput + fee);
        assertEq(fee, FullMath.mulDivRoundingUp(poolInput, 10_000, 9_900) - poolInput);
    }

    function testExactOutputSellGrossesUpPoolOutputAndPaysNetEth() public {
        (address token,,,) = _launch(bytes32("exact-out-sell"), 0);
        vm.prank(USER);
        router.buyExactIn{value: 1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        PoolKey memory key = hook.poolKey(token);
        uint256 requestedNetEth = 0.01 ether;
        uint256 maxTokenInput = CtrlToken(token).balanceOf(USER);
        uint256 principalBefore = hook.getLaunch(token).netEthPrincipal;
        uint256 claimsBefore = manager.balanceOf(address(vault), 0);
        vm.prank(USER);
        IERC20(token).approve(address(universalRouter), maxTokenInput);

        vm.prank(USER);
        BalanceDelta delta = universalRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: int256(requestedNetEth),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(USER, address(0)),
            USER,
            maxTokenInput
        );

        uint256 fee = manager.balanceOf(address(vault), 0) - claimsBefore;
        uint256 poolOutput = principalBefore - hook.getLaunch(token).netEthPrincipal;
        assertEq(uint256(uint128(delta.amount0())), requestedNetEth);
        assertEq(poolOutput, requestedNetEth + fee);
        assertEq(fee, FullMath.mulDivRoundingUp(requestedNetEth, 10_000, 9_900) - requestedNetEth);
    }

    function testPartialExactInputBuyRevertsInsteadOfOvercharging() public {
        (address token, PoolId poolId,,) = _launch(bytes32("partial"), 0);
        PoolKey memory key = hook.poolKey(token);
        (uint160 currentPrice,,,) = IPoolManager(address(manager)).getSlot0(poolId);

        vm.prank(USER);
        vm.expectRevert();
        universalRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: currentPrice - 1
            }),
            bytes(""),
            USER,
            0
        );
        assertEq(manager.balanceOf(address(vault), 0), 0);
    }

    function testPauseStopsOnlyFutureLaunches() public {
        (address token,,,) = _launch(bytes32("before-pause"), 0);
        factory.setLaunchesPaused(true);

        vm.expectRevert(CtrlV4Factory.LaunchesPaused.selector);
        _launch(bytes32("paused"), 0);

        vm.prank(USER);
        router.buyExactIn{value: 0.1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);
        assertGt(CtrlToken(token).balanceOf(USER), 0);
    }

    function testFuzzExactInputBuyMaintainsVaultSolvency(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 0.001 ether, 1 ether);
        (address token,,,) = _launch(keccak256(abi.encode(rawAmount)), 0);

        vm.prank(USER);
        router.buyExactIn{value: amount}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);

        uint256 expectedFee = amount / 100;
        assertEq(manager.balanceOf(address(vault), 0), expectedFee);
        assertEq(vault.totalLiabilityEth(), expectedFee);
        assertEq(vault.totalClaimableEth() + vault.reservedBountyEth(), expectedFee);
        assertTrue(vault.isSolvent());
    }
}
