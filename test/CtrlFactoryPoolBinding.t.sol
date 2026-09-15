// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Test} from "forge-std/Test.sol";
import {CtrlFeeVault} from "../src/CtrlFeeVault.sol";
import {CtrlLaunchRouter} from "../src/CtrlLaunchRouter.sol";
import {CtrlPositionLocker} from "../src/CtrlPositionLocker.sol";
import {CtrlV4Factory} from "../src/CtrlV4Factory.sol";
import {MockPoolBindingHook} from "./mocks/MockPoolBindingHook.sol";
import {MockPermit2, MockPositionManager} from "./mocks/MockV4Periphery.sol";

contract CtrlFactoryPoolBindingTest is Test {
    address private constant TREASURY = address(0xBEEF);

    MockPoolBindingHook private hook;
    CtrlV4Factory private factory;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 10 ether);

        PoolManager manager = new PoolManager(address(this));
        MockPermit2 permit2 = new MockPermit2();
        MockPositionManager positionManager = new MockPositionManager(address(manager), address(permit2));
        CtrlFeeVault vault = new CtrlFeeVault(address(this), address(manager), TREASURY, address(this));
        CtrlPositionLocker locker = new CtrlPositionLocker(address(positionManager), address(this));
        hook = new MockPoolBindingHook();
        CtrlLaunchRouter router = new CtrlLaunchRouter(address(manager), address(hook));

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

        vault.initializeHook(address(hook));
        locker.initializeFactory(address(factory));
        factory.setLaunchesPaused(false);
    }

    function testRejectsReturnedPoolIdMismatch() public {
        _assertInvalidPool(MockPoolBindingHook.Fault.ReturnedPoolId, bytes32("returned-pool-id"));
    }

    function testRejectsPoolIdForTokenMismatch() public {
        _assertInvalidPool(MockPoolBindingHook.Fault.PoolIdForToken, bytes32("stored-pool-id"));
    }

    function testRejectsNonNativeCurrency0() public {
        _assertInvalidPool(MockPoolBindingHook.Fault.Currency0, bytes32("currency-zero"));
    }

    function testRejectsCurrency1ThatIsNotLaunchedToken() public {
        _assertInvalidPool(MockPoolBindingHook.Fault.Currency1, bytes32("currency-one"));
    }

    function testRejectsNonzeroPoolFee() public {
        _assertInvalidPool(MockPoolBindingHook.Fault.Fee, bytes32("pool-fee"));
    }

    function testRejectsWrongTickSpacing() public {
        _assertInvalidPool(MockPoolBindingHook.Fault.TickSpacing, bytes32("tick-spacing"));
    }

    function testRejectsWrongHookAddress() public {
        _assertInvalidPool(MockPoolBindingHook.Fault.Hooks, bytes32("hook-address"));
    }

    function _assertInvalidPool(MockPoolBindingHook.Fault fault, bytes32 salt) private {
        hook.setFault(fault);
        CtrlV4Factory.TokenParams memory params = _params();
        address predictedToken = factory.predictTokenAddress(params, salt, address(this));
        assertEq(predictedToken.code.length, 0, "predicted token must not exist before launch");
        uint256 launchFee = factory.LAUNCH_FEE();

        vm.expectRevert(CtrlV4Factory.InvalidPool.selector);
        factory.launchToken{value: launchFee}(params, salt, 0, 0);

        assertEq(factory.totalLaunches(), 0, "invalid launch must not increment total");
        assertEq(predictedToken.code.length, 0, "reverted launch must remove predicted token code");
    }

    function _params() private view returns (CtrlV4Factory.TokenParams memory) {
        return CtrlV4Factory.TokenParams({
            name: "Pool Binding Test",
            symbol: "BIND",
            metadataURI: "ipfs://pool-binding-test",
            logoURI: "ipfs://pool-binding-logo",
            description: "Factory canonical pool binding regression coverage",
            website: "https://ctrl.finance",
            x: "",
            telegram: "",
            discord: "",
            farcaster: "",
            creatorPayout: address(this),
            initialBuyRecipient: address(0),
            initialBuyReferrer: address(0)
        });
    }
}
