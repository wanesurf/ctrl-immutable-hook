// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ICtrlFeeVault} from "./interfaces/ICtrlProtocol.sol";

/// @notice Pull-based accounting vault backed by PoolManager native-ETH ERC-6909 claims.
contract CtrlFeeVault is Ownable2Step, ReentrancyGuard, IUnlockCallback, ICtrlFeeVault {
    using CurrencyLibrary for Currency;

    struct ClaimCallback {
        address payable recipient;
        uint256 amount;
    }

    error AlreadyInitialized();
    error Insolvent();
    error InvalidAccrual();
    error NoFees();
    error NotHook();
    error NotInitializer();
    error NotPoolManager();
    error ReservedBountyExceeded();
    error ZeroAddress();

    event HookInitialized(address indexed hook);
    event FeeAllocationAccrued(
        address indexed token,
        address indexed creatorPayout,
        uint256 creatorAmount,
        address indexed referralPayout,
        uint256 referralAmount,
        address treasury,
        uint256 protocolAmount,
        uint256 bountyAmount
    );
    event BountyReleased(address indexed token, address indexed recipient, uint256 amount);
    event CreatorFeesClaimed(address indexed token, address indexed recipient, uint256 amount);
    event ReferralFeesClaimed(address indexed recipient, uint256 amount);
    event ProtocolFeesClaimed(address indexed recipient, uint256 amount);
    event GraduationBountyClaimed(address indexed recipient, uint256 amount);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);

    IPoolManager public immutable poolManager;
    address public immutable initializer;
    address public hook;
    address public override treasury;

    mapping(address token => mapping(address recipient => uint256 amount)) public creatorClaimableEth;
    mapping(address recipient => uint256 amount) public referralClaimableEth;
    mapping(address recipient => uint256 amount) public protocolClaimableEth;
    mapping(address recipient => uint256 amount) public bountyClaimableEth;
    mapping(address token => uint256 amount) public reservedBountyEthForToken;
    uint256 public totalClaimableEth;
    uint256 public reservedBountyEth;
    uint256 public totalLiabilityEth;

    constructor(address initialOwner, address poolManager_, address treasury_, address initializer_)
        Ownable(initialOwner)
    {
        if (
            initialOwner == address(0) || poolManager_ == address(0) || treasury_ == address(0)
                || initializer_ == address(0)
        ) {
            revert ZeroAddress();
        }
        poolManager = IPoolManager(poolManager_);
        treasury = treasury_;
        initializer = initializer_;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    function initializeHook(address hook_) external {
        if (msg.sender != initializer) revert NotInitializer();
        if (hook != address(0)) revert AlreadyInitialized();
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookInitialized(hook_);
    }

    function accrue(
        address token,
        address creatorPayout,
        uint256 creatorAmount,
        address referralPayout,
        uint256 referralAmount,
        uint256 protocolAmount,
        uint256 bountyAmount
    ) external onlyHook {
        if (token == address(0) || creatorPayout == address(0)) revert InvalidAccrual();
        if (referralAmount != 0 && referralPayout == address(0)) revert InvalidAccrual();

        uint256 claimableIncrease = creatorAmount + referralAmount + protocolAmount;
        uint256 liabilityIncrease = claimableIncrease + bountyAmount;

        creatorClaimableEth[token][creatorPayout] += creatorAmount;
        if (referralAmount != 0) referralClaimableEth[referralPayout] += referralAmount;
        protocolClaimableEth[treasury] += protocolAmount;
        totalClaimableEth += claimableIncrease;
        reservedBountyEthForToken[token] += bountyAmount;
        reservedBountyEth += bountyAmount;
        totalLiabilityEth += liabilityIncrease;

        if (poolManager.balanceOf(address(this), 0) < totalLiabilityEth) revert Insolvent();
        emit FeeAllocationAccrued(
            token, creatorPayout, creatorAmount, referralPayout, referralAmount, treasury, protocolAmount, bountyAmount
        );
    }

    function releaseBounty(address token, address recipient, uint256 amount) external onlyHook {
        if (token == address(0) || recipient == address(0)) revert ZeroAddress();
        if (amount > reservedBountyEthForToken[token]) revert ReservedBountyExceeded();

        reservedBountyEthForToken[token] -= amount;
        reservedBountyEth -= amount;
        bountyClaimableEth[recipient] += amount;
        totalClaimableEth += amount;
        emit BountyReleased(token, recipient, amount);
    }

    function claimCreator(address token) external nonReentrant returns (uint256 amount) {
        amount = creatorClaimableEth[token][msg.sender];
        if (amount == 0) revert NoFees();
        creatorClaimableEth[token][msg.sender] = 0;
        _pay(payable(msg.sender), amount);
        emit CreatorFeesClaimed(token, msg.sender, amount);
    }

    function claimReferral() external nonReentrant returns (uint256 amount) {
        amount = referralClaimableEth[msg.sender];
        if (amount == 0) revert NoFees();
        referralClaimableEth[msg.sender] = 0;
        _pay(payable(msg.sender), amount);
        emit ReferralFeesClaimed(msg.sender, amount);
    }

    function claimProtocol() external nonReentrant returns (uint256 amount) {
        amount = protocolClaimableEth[msg.sender];
        if (amount == 0) revert NoFees();
        protocolClaimableEth[msg.sender] = 0;
        _pay(payable(msg.sender), amount);
        emit ProtocolFeesClaimed(msg.sender, amount);
    }

    function claimGraduationBounty() external nonReentrant returns (uint256 amount) {
        amount = bountyClaimableEth[msg.sender];
        if (amount == 0) revert NoFees();
        bountyClaimableEth[msg.sender] = 0;
        _pay(payable(msg.sender), amount);
        emit GraduationBountyClaimed(msg.sender, amount);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        ClaimCallback memory callback = abi.decode(data, (ClaimCallback));

        poolManager.burn(address(this), 0, callback.amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, callback.recipient, callback.amount);
        return bytes("");
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previousTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previousTreasury, newTreasury);
    }

    function isSolvent() external view returns (bool) {
        return poolManager.balanceOf(address(this), 0) >= totalLiabilityEth;
    }

    function _pay(address payable recipient, uint256 amount) private {
        totalClaimableEth -= amount;
        totalLiabilityEth -= amount;
        poolManager.unlock(abi.encode(ClaimCallback({recipient: recipient, amount: amount})));
    }
}
