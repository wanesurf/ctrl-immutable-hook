// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CtrlFeeVault} from "../src/CtrlFeeVault.sol";
import {CtrlLaunchHookV1} from "../src/CtrlLaunchHookV1.sol";
import {CtrlLaunchRouter} from "../src/CtrlLaunchRouter.sol";
import {CtrlPositionLocker} from "../src/CtrlPositionLocker.sol";
import {CtrlReferralRegistry} from "../src/CtrlReferralRegistry.sol";
import {CtrlV4Factory} from "../src/CtrlV4Factory.sol";
import {HookCreate2Deployer} from "./mocks/HookCreate2Deployer.sol";
import {MockPermit2, MockPositionManager} from "./mocks/MockV4Periphery.sol";
import {MockUniversalV4Router} from "./mocks/MockUniversalV4Router.sol";

abstract contract CtrlTestBase is Test {
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 internal constant CTRL_HOOK_FLAGS = 0x28cc;

    address internal constant TREASURY = address(0xBEEF);
    address internal constant CREATOR_PAYOUT = address(0xCAFE);
    address internal constant UPDATED_PAYOUT = address(0xC0FFEE);
    address internal constant USER = address(0xA11CE);
    address internal constant REFERRER = address(0xFEE1);
    address internal constant REFERRAL_PAYOUT = address(0xFEE2);

    PoolManager internal manager;
    MockPermit2 internal permit2;
    MockPositionManager internal positionManager;
    CtrlReferralRegistry internal registry;
    CtrlFeeVault internal vault;
    CtrlPositionLocker internal locker;
    CtrlLaunchHookV1 internal hook;
    CtrlLaunchRouter internal router;
    CtrlV4Factory internal factory;
    MockUniversalV4Router internal universalRouter;

    receive() external payable {}

    function setUp() public virtual {
        vm.deal(address(this), 1_000 ether);
        vm.deal(USER, 1_000 ether);
        vm.deal(REFERRER, 1 ether);

        manager = new PoolManager(address(this));
        permit2 = new MockPermit2();
        positionManager = new MockPositionManager(address(manager), address(permit2));
        registry = new CtrlReferralRegistry();
        vault = new CtrlFeeVault(address(this), address(manager), TREASURY, address(this));
        locker = new CtrlPositionLocker(address(positionManager), address(this));
        hook = _deployHook();
        router = new CtrlLaunchRouter(address(manager), address(hook));
        factory = new CtrlV4Factory(
            address(this),
            address(manager),
            address(positionManager),
            address(permit2),
            address(locker),
            address(hook),
            address(router),
            address(vault)
        );
        universalRouter = new MockUniversalV4Router(address(manager));

        hook.initializeFactory(address(factory));
        vault.initializeHook(address(hook));
        locker.initializeFactory(address(factory));
        factory.setLaunchesPaused(false);
    }

    function _launch(bytes32 salt, uint256 initialBuy)
        internal
        returns (address token, PoolId poolId, uint256 positionId, uint256 initialBuyTokens)
    {
        uint256 minimum = initialBuy == 0 ? 0 : 1;
        uint256 deadline = initialBuy == 0 ? 0 : block.timestamp + 1 hours;
        return factory.launchToken{value: 0.0005 ether + initialBuy}(_params(), salt, minimum, deadline);
    }

    function _params() internal pure returns (CtrlV4Factory.TokenParams memory) {
        return CtrlV4Factory.TokenParams({
            name: "Ctrl Token",
            symbol: "CTRL",
            metadataURI: "ipfs://ctrl-token",
            logoURI: "ipfs://ctrl-logo",
            description: "A token launched with Ctrl",
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

    function _deployHook() internal returns (CtrlLaunchHookV1 deployedHook) {
        HookCreate2Deployer deployer = new HookCreate2Deployer();
        bytes memory creationCode = abi.encodePacked(
            type(CtrlLaunchHookV1).creationCode,
            abi.encode(address(manager), address(positionManager), address(vault), address(registry), address(this))
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
