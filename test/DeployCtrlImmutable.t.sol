// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployCtrl} from "../script/DeployCtrl.s.sol";
import {CtrlLaunchHookV1} from "../src/CtrlLaunchHookV1.sol";
import {CtrlTestBase} from "./CtrlTestBase.sol";

contract DeployCtrlHarness is DeployCtrl {
    function deploy(Config memory config) external returns (Deployment memory) {
        return _deploy(config);
    }
}

contract DeployCtrlImmutableTest is CtrlTestBase {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    DeployCtrlHarness private deployScript;

    function setUp() public override {
        super.setUp();
        deployScript = new DeployCtrlHarness();
        vm.deal(vm.addr(1), 10 ether);
    }

    function testDeploysDirectImmutableHookAndKeepsExistingStackWorking() public {
        (address oldToken,,,) = _launch(bytes32("old-stack"), 0);
        DeployCtrl.Deployment memory deployed = deployScript.deploy(_config());

        assertTrue(deployed.factory.launchesArePaused());
        assertEq(uint160(address(deployed.hook)) & ALL_HOOK_MASK, CTRL_HOOK_FLAGS);
        assertEq(vm.load(address(deployed.hook), IMPLEMENTATION_SLOT), bytes32(0));
        assertEq(deployed.hook.factory(), address(deployed.factory));
        assertEq(address(deployed.factory.hook()), address(deployed.hook));
        assertEq(address(deployed.router.hook()), address(deployed.hook));
        assertEq(deployed.vault.hook(), address(deployed.hook));
        assertEq(deployed.locker.factory(), address(deployed.factory));
        assertEq(address(deployed.hook.poolManager()), address(manager));
        assertEq(deployed.hook.positionManager(), address(positionManager));
        assertEq(address(deployed.hook.feeVault()), address(deployed.vault));
        assertEq(address(deployed.hook.referralRegistry()), address(deployed.registry));
        assertEq(deployed.factory.owner(), address(this));
        assertEq(deployed.vault.owner(), address(this));
        assertEq(deployed.vault.treasury(), TREASURY);

        bytes32 originalCodehash = address(deployed.hook).codehash;
        (bool upgraded,) = address(deployed.hook)
            .call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(hook), bytes("")));
        assertFalse(upgraded, "immutable hook must have no upgrade entrypoint");
        assertEq(address(deployed.hook).codehash, originalCodehash);
        vm.prank(vm.addr(1));
        vm.expectRevert(CtrlLaunchHookV1.AlreadyInitialized.selector);
        deployed.hook.initializeFactory(address(factory));

        deployed.factory.setLaunchesPaused(false);
        (address newToken,,,) = deployed.factory.launchToken{value: 0.1005 ether}(
            _params(), bytes32("immutable-stack"), 1, block.timestamp + 1 hours
        );
        assertEq(deployed.hook.getLaunch(newToken).netEthPrincipal, 0.099 ether);
        assertEq(deployed.vault.totalLiabilityEth(), 0.001 ether);
        assertTrue(deployed.vault.isSolvent());

        vm.prank(USER);
        router.buyExactIn{value: 0.1 ether}(oldToken, USER, USER, address(0), 1, block.timestamp + 1 hours);
        assertEq(hook.getLaunch(oldToken).netEthPrincipal, 0.099 ether);
        assertTrue(vault.isSolvent());
        assertNotEq(address(deployed.hook), address(hook));
        assertNotEq(address(deployed.vault), address(vault));
    }

    function testRejectsWrongChainAndZeroRolesBeforeDeployment() public {
        DeployCtrl.Config memory config = _config();
        config.expectedChainId += 1;
        vm.expectRevert(bytes("unexpected chain id"));
        deployScript.deploy(config);
        config = _config();
        config.owner = address(0);
        vm.expectRevert(bytes("OWNER is zero"));
        deployScript.deploy(config);
        config = _config();
        config.treasury = address(0);
        vm.expectRevert(bytes("TREASURY is zero"));
        deployScript.deploy(config);
    }

    function testRejectsEveryMismatchedDependencyFingerprint() public {
        for (uint256 i; i < 3; ++i) {
            DeployCtrl.Config memory config = _config();
            if (i == 0) config.poolManagerCodehash = bytes32(uint256(1));
            if (i == 1) config.positionManagerCodehash = bytes32(uint256(1));
            if (i == 2) config.permit2Codehash = bytes32(uint256(1));
            vm.expectRevert(bytes("dependency codehash mismatch"));
            deployScript.deploy(config);
        }
    }

    function testRejectsMissingCodeAndZeroFingerprint() public {
        DeployCtrl.Config memory config = _config();
        config.poolManagerCodehash = bytes32(0);
        vm.expectRevert(bytes("expected codehash is zero"));
        deployScript.deploy(config);
        config = _config();
        config.poolManager = address(0xDEAD);
        vm.expectRevert(bytes("dependency has no code"));
        deployScript.deploy(config);
    }

    function _config() private view returns (DeployCtrl.Config memory) {
        return DeployCtrl.Config({
            privateKey: 1,
            owner: address(this),
            treasury: TREASURY,
            expectedChainId: block.chainid,
            poolManager: address(manager),
            positionManager: address(positionManager),
            permit2: address(permit2),
            poolManagerCodehash: address(manager).codehash,
            positionManagerCodehash: address(positionManager).codehash,
            permit2Codehash: address(permit2).codehash
        });
    }
}
