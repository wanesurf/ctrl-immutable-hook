// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";
import {CtrlFeeVault} from "../src/CtrlFeeVault.sol";
import {CtrlLaunchHookV1} from "../src/CtrlLaunchHookV1.sol";
import {CtrlLaunchRouter} from "../src/CtrlLaunchRouter.sol";
import {CtrlPositionLocker} from "../src/CtrlPositionLocker.sol";
import {CtrlReferralRegistry} from "../src/CtrlReferralRegistry.sol";
import {CtrlToken} from "../src/CtrlToken.sol";
import {CtrlV4Factory} from "../src/CtrlV4Factory.sol";
import {IPositionManagerMinimal} from "../src/interfaces/ICtrlProtocol.sol";
import {HookCreate2Deployer} from "./mocks/HookCreate2Deployer.sol";
import {MockUniversalV4Router} from "./mocks/MockUniversalV4Router.sol";

interface IPermit2View {
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice Production-periphery compatibility tests pinned to a Robinhood mainnet block.
/// @dev These tests never broadcast. Set RUN_RH_FORK_TESTS=true and
///      RH_MAINNET_RPC_URL to enable them.
contract CtrlRobinhoodForkTest is Test {
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant PINNED_FORK_BLOCK = 19_710_849;
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant CTRL_HOOK_FLAGS = 0x28cc;

    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant POOL_MANAGER_CODEHASH =
        0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626;
    bytes32 internal constant POSITION_MANAGER_CODEHASH =
        0xc873e135dc9aaec88489cfbad146b4cb49d6a32e0d80326377784b7ba17670b2;
    bytes32 internal constant PERMIT2_CODEHASH = 0x5208783f52488f7d3493e5e38311ab707c1d75457fe472a19b0b4d57d66a7fca;

    address internal constant TREASURY = address(0xBEEF);
    address internal constant CREATOR_PAYOUT = address(0xCAFE);
    address internal constant USER = address(0xA11CE);

    CtrlReferralRegistry internal registry;
    CtrlFeeVault internal vault;
    CtrlPositionLocker internal locker;
    CtrlLaunchHookV1 internal hook;
    CtrlLaunchRouter internal router;
    CtrlV4Factory internal factory;
    MockUniversalV4Router internal universalRouter;
    uint256 internal forkBlock;

    receive() external payable {}

    function setUp() public {
        if (!vm.envOr("RUN_RH_FORK_TESTS", false)) {
            vm.skip(true, "RUN_RH_FORK_TESTS is not enabled");
        }
        string memory rpcUrl = vm.envOr("RH_MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) vm.skip(true);

        forkBlock = vm.envOr("RH_FORK_BLOCK_NUMBER", PINNED_FORK_BLOCK);
        vm.createSelectFork(rpcUrl, forkBlock);
        vm.deal(address(this), 1_000 ether);
        vm.deal(USER, 1_000 ether);

        registry = new CtrlReferralRegistry();
        vault = new CtrlFeeVault(address(this), POOL_MANAGER, TREASURY, address(this));
        locker = new CtrlPositionLocker(POSITION_MANAGER, address(this));
        hook = _deployHook();
        router = new CtrlLaunchRouter(POOL_MANAGER, address(hook));
        factory = new CtrlV4Factory(
            address(this),
            POOL_MANAGER,
            POSITION_MANAGER,
            PERMIT2,
            address(locker),
            address(hook),
            address(router),
            address(vault)
        );
        universalRouter = new MockUniversalV4Router(POOL_MANAGER);

        hook.initializeFactory(address(factory));
        vault.initializeHook(address(hook));
        locker.initializeFactory(address(factory));
        factory.setLaunchesPaused(false);
    }

    function testOfficialDependencyFingerprints() public view {
        assertEq(block.chainid, 4663);
        assertEq(block.number, forkBlock);
        assertEq(POOL_MANAGER.codehash, POOL_MANAGER_CODEHASH);
        assertEq(POSITION_MANAGER.codehash, POSITION_MANAGER_CODEHASH);
        assertEq(PERMIT2.codehash, PERMIT2_CODEHASH);
        assertEq(uint160(address(hook)) & ALL_HOOK_MASK, CTRL_HOOK_FLAGS);
    }

    function testLaunchMintsAndLocksOfficialPositionWithNoResidualApprovals() public {
        uint256 nextPositionId = IPositionManagerMinimal(POSITION_MANAGER).nextTokenId();
        uint256 treasuryBefore = TREASURY.balance;

        (address token, PoolId poolId, uint256 positionId,) =
            factory.launchToken{value: 0.0005 ether}(_params(), keccak256("official-position"), 0, 0);

        CtrlPositionLocker.LockedPosition memory locked = locker.getPosition(token);
        (uint160 permitAmount,,) = IPermit2View(PERMIT2).allowance(address(factory), token, POSITION_MANAGER);

        assertEq(positionId, nextPositionId);
        assertEq(IPositionManagerMinimal(POSITION_MANAGER).ownerOf(positionId), address(locker));
        assertGt(IPositionManagerMinimal(POSITION_MANAGER).getPositionLiquidity(positionId), 0);
        assertEq(locked.positionId, positionId);
        assertEq(PoolId.unwrap(locked.poolId), PoolId.unwrap(poolId));
        assertEq(CtrlToken(token).balanceOf(address(factory)), 0);
        assertLt(CtrlToken(token).balanceOf(address(locker)), 100_000);
        assertEq(IERC20(token).allowance(address(factory), PERMIT2), 0);
        assertEq(permitAmount, 0);
        assertEq(TREASURY.balance - treasuryBefore, 0.0005 ether);
    }

    function testAllFourSwapModesSettleAgainstOfficialPoolManager() public {
        (address token,,,) = factory.launchToken{value: 0.0005 ether}(_params(), keccak256("four-swap-modes"), 0, 0);
        PoolKey memory key = hook.poolKey(token);
        IPoolManager manager = IPoolManager(POOL_MANAGER);

        vm.prank(USER);
        router.buyExactIn{value: 1 ether}(token, USER, USER, address(0), 1, block.timestamp + 1 hours);
        uint256 claimsAfterExactInputBuy = manager.balanceOf(address(vault), 0);
        assertEq(claimsAfterExactInputBuy, 0.01 ether);

        uint256 exactInputSellAmount = CtrlToken(token).balanceOf(USER) / 20;
        vm.prank(USER);
        IERC20(token).approve(address(router), exactInputSellAmount);
        vm.prank(USER);
        router.sellExactIn(token, exactInputSellAmount, USER, USER, address(0), 1, block.timestamp + 1 hours);
        uint256 claimsAfterExactInputSell = manager.balanceOf(address(vault), 0);
        assertGt(claimsAfterExactInputSell, claimsAfterExactInputBuy);

        vm.prank(USER);
        BalanceDelta exactOutputBuy = universalRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(1_000_000 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            abi.encode(USER, address(0)),
            USER,
            0
        );
        uint256 claimsAfterExactOutputBuy = manager.balanceOf(address(vault), 0);
        assertGt(exactOutputBuy.amount1(), 0);
        assertGt(claimsAfterExactOutputBuy, claimsAfterExactInputSell);

        uint256 maxTokenInput = CtrlToken(token).balanceOf(USER);
        vm.prank(USER);
        IERC20(token).approve(address(universalRouter), maxTokenInput);
        vm.prank(USER);
        BalanceDelta exactOutputSell = universalRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: int256(0.01 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            abi.encode(USER, address(0)),
            USER,
            maxTokenInput
        );
        uint256 claimsAfterExactOutputSell = manager.balanceOf(address(vault), 0);
        assertEq(uint256(uint128(exactOutputSell.amount0())), 0.01 ether);
        assertGt(claimsAfterExactOutputSell, claimsAfterExactOutputBuy);

        assertEq(claimsAfterExactOutputSell, vault.totalLiabilityEth());
        assertTrue(vault.isSolvent());
        assertEq(address(hook).balance, 0);
        assertEq(address(router).balance, 0);
        assertEq(address(universalRouter).balance, 0);
    }

    function _params() private pure returns (CtrlV4Factory.TokenParams memory) {
        return CtrlV4Factory.TokenParams({
            name: "Ctrl Fork Token",
            symbol: "CTRL-FORK",
            metadataURI: "ipfs://ctrl-fork-token",
            logoURI: "ipfs://ctrl-fork-logo",
            description: "Ctrl Robinhood mainnet fork test token",
            website: "https://ctrl.finance",
            x: "https://x.com/ctrlfinance",
            telegram: "https://t.me/ctrlfinance",
            discord: "https://discord.gg/ctrl",
            farcaster: "ctrl",
            creatorPayout: CREATOR_PAYOUT,
            initialBuyRecipient: address(0),
            initialBuyReferrer: address(0)
        });
    }

    function _deployHook() private returns (CtrlLaunchHookV1 deployedHook) {
        HookCreate2Deployer deployer = new HookCreate2Deployer();
        bytes memory creationCode = abi.encodePacked(
            type(CtrlLaunchHookV1).creationCode,
            abi.encode(POOL_MANAGER, POSITION_MANAGER, address(vault), address(registry), address(this))
        );
        bytes32 initCodeHash = keccak256(creationCode);

        for (uint256 i; i < 100_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(deployer), salt, initCodeHash))))
            );
            if (uint160(predicted) & ALL_HOOK_MASK == CTRL_HOOK_FLAGS) {
                address deployed = deployer.deploy(salt, creationCode);
                assertEq(deployed, predicted);
                return CtrlLaunchHookV1(deployed);
            }
        }
        revert("hook salt not found");
    }
}
