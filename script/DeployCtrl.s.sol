// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CtrlFeeVault} from "../src/CtrlFeeVault.sol";
import {CtrlLaunchHookV1} from "../src/CtrlLaunchHookV1.sol";
import {CtrlLaunchRouter} from "../src/CtrlLaunchRouter.sol";
import {CtrlPositionLocker} from "../src/CtrlPositionLocker.sol";
import {CtrlReferralRegistry} from "../src/CtrlReferralRegistry.sol";
import {CtrlV4Factory} from "../src/CtrlV4Factory.sol";

contract CtrlHookCreate2Deployer {
    error DeploymentFailed();

    function deploy(bytes32 salt, bytes memory creationCode) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (deployed == address(0)) revert DeploymentFailed();
    }
}

/// @notice Deploys a new immutable Ctrl launch stack; existing V2 pools are unaffected.
/// @dev CtrlLaunchHookV1 is deployed directly with CREATE2, without a proxy or upgrade authority.
contract DeployCtrl is Script {
    uint160 private constant ALL_HOOK_MASK = (1 << 14) - 1;
    uint160 private constant CTRL_HOOK_FLAGS = 0x28cc;

    address private constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant RH_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    struct Deployment {
        CtrlFeeVault vault;
        CtrlReferralRegistry registry;
        CtrlPositionLocker locker;
        CtrlLaunchHookV1 hook;
        CtrlLaunchRouter router;
        CtrlV4Factory factory;
        CtrlHookCreate2Deployer hookDeployer;
    }

    struct Config {
        uint256 privateKey;
        address owner;
        address treasury;
        uint256 expectedChainId;
        address poolManager;
        address positionManager;
        address permit2;
        bytes32 poolManagerCodehash;
        bytes32 positionManagerCodehash;
        bytes32 permit2Codehash;
    }

    function run() external returns (Deployment memory) {
        return _deploy(
            Config({
                privateKey: vm.envUint("PRIVATE_KEY"),
                owner: vm.envAddress("OWNER"),
                treasury: vm.envAddress("TREASURY"),
                expectedChainId: vm.envUint("EXPECTED_CHAIN_ID"),
                poolManager: vm.envOr("POOL_MANAGER", RH_POOL_MANAGER),
                positionManager: vm.envOr("POSITION_MANAGER", RH_POSITION_MANAGER),
                permit2: vm.envOr("PERMIT2", PERMIT2),
                poolManagerCodehash: vm.envBytes32("POOL_MANAGER_CODEHASH"),
                positionManagerCodehash: vm.envBytes32("POSITION_MANAGER_CODEHASH"),
                permit2Codehash: vm.envBytes32("PERMIT2_CODEHASH")
            })
        );
    }

    function _deploy(Config memory config) internal returns (Deployment memory deployment) {
        require(block.chainid == config.expectedChainId, "unexpected chain id");
        require(config.owner != address(0), "OWNER is zero");
        require(config.treasury != address(0), "TREASURY is zero");
        _requireCodeHash(config.poolManager, config.poolManagerCodehash);
        _requireCodeHash(config.positionManager, config.positionManagerCodehash);
        _requireCodeHash(config.permit2, config.permit2Codehash);

        address broadcaster = vm.addr(config.privateKey);
        vm.startBroadcast(config.privateKey);
        deployment.vault = new CtrlFeeVault(config.owner, config.poolManager, config.treasury, broadcaster);
        deployment.registry = new CtrlReferralRegistry();
        deployment.locker = new CtrlPositionLocker(config.positionManager, broadcaster);
        deployment.hookDeployer = new CtrlHookCreate2Deployer();

        bytes memory hookCreationCode = abi.encodePacked(
            type(CtrlLaunchHookV1).creationCode,
            abi.encode(
                config.poolManager,
                config.positionManager,
                address(deployment.vault),
                address(deployment.registry),
                broadcaster
            )
        );
        bytes32 hookSalt = _mineHookSalt(address(deployment.hookDeployer), keccak256(hookCreationCode));
        deployment.hook = CtrlLaunchHookV1(deployment.hookDeployer.deploy(hookSalt, hookCreationCode));
        deployment.router = new CtrlLaunchRouter(config.poolManager, address(deployment.hook));
        deployment.factory = new CtrlV4Factory(
            config.owner,
            config.poolManager,
            config.positionManager,
            config.permit2,
            address(deployment.locker),
            address(deployment.hook),
            address(deployment.router),
            address(deployment.vault)
        );

        deployment.hook.initializeFactory(address(deployment.factory));
        deployment.vault.initializeHook(address(deployment.hook));
        deployment.locker.initializeFactory(address(deployment.factory));
        vm.stopBroadcast();

        require(deployment.factory.launchesArePaused(), "factory unexpectedly open");
        require(uint160(address(deployment.hook)) & ALL_HOOK_MASK == CTRL_HOOK_FLAGS, "invalid hook permissions");
        require(deployment.hook.factory() == address(deployment.factory), "hook factory mismatch");
        require(deployment.vault.hook() == address(deployment.hook), "vault hook mismatch");
        require(deployment.locker.factory() == address(deployment.factory), "locker factory mismatch");

        console2.log("CtrlV4Factory", address(deployment.factory));
        console2.log("CtrlLaunchHookV1", address(deployment.hook));
        console2.log("CtrlLaunchRouter", address(deployment.router));
        console2.log("CtrlFeeVault", address(deployment.vault));
        console2.log("CtrlReferralRegistry", address(deployment.registry));
        console2.log("CtrlPositionLocker", address(deployment.locker));
        console2.log("CtrlHookCreate2Deployer", address(deployment.hookDeployer));
        console2.log("Hook runtime code hash");
        console2.logBytes32(address(deployment.hook).codehash);
        console2.log("Hook CREATE2 salt");
        console2.logBytes32(hookSalt);
    }

    function _mineHookSalt(address deployer, bytes32 initCodeHash) private pure returns (bytes32 salt) {
        for (uint256 i; i < 1_000_000; ++i) {
            salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
            if (uint160(predicted) & ALL_HOOK_MASK == CTRL_HOOK_FLAGS) return salt;
        }
        revert("hook salt not found");
    }

    function _requireCodeHash(address target, bytes32 expectedCodehash) private view {
        require(expectedCodehash != bytes32(0), "expected codehash is zero");
        require(target.code.length != 0, "dependency has no code");
        require(target.codehash == expectedCodehash, "dependency codehash mismatch");
    }
}
