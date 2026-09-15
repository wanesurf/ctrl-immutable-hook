// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ICtrlPositionLocker, IERC721Receiver, IPositionManagerMinimal} from "./interfaces/ICtrlProtocol.sol";

/// @notice Permanently owns every Ctrl V4 position NFT.
/// @dev This contract intentionally has no transfer, approval, arbitrary-call, liquidity-removal,
///      upgrade, or token-recovery function.
contract CtrlPositionLocker is ICtrlPositionLocker, IERC721Receiver {
    struct LockedPosition {
        PoolId poolId;
        uint256 positionId;
        bool exists;
    }

    error AlreadyInitialized();
    error InvalidPosition();
    error NotFactory();
    error NotInitializer();
    error PositionAlreadyRegistered();
    error ZeroAddress();

    event FactoryInitialized(address indexed factory);
    event PositionRegistered(address indexed token, PoolId indexed poolId, uint256 indexed positionId);
    event TokenDustLocked(address indexed token, uint256 amount);

    IPositionManagerMinimal public immutable positionManager;
    address public immutable initializer;
    address public factory;

    mapping(address token => LockedPosition position) private _positions;
    mapping(uint256 positionId => address token) public tokenForPosition;

    constructor(address positionManager_, address initializer_) {
        if (positionManager_ == address(0) || initializer_ == address(0)) revert ZeroAddress();
        positionManager = IPositionManagerMinimal(positionManager_);
        initializer = initializer_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    function initializeFactory(address factory_) external {
        if (msg.sender != initializer) revert NotInitializer();
        if (factory != address(0)) revert AlreadyInitialized();
        if (factory_ == address(0)) revert ZeroAddress();

        factory = factory_;
        emit FactoryInitialized(factory_);
    }

    function registerPosition(address token, PoolId poolId, uint256 positionId) external onlyFactory {
        if (token == address(0) || PoolId.unwrap(poolId) == bytes32(0)) revert InvalidPosition();
        if (_positions[token].exists || tokenForPosition[positionId] != address(0)) {
            revert PositionAlreadyRegistered();
        }
        if (positionManager.ownerOf(positionId) != address(this)) revert InvalidPosition();
        if (positionManager.getPositionLiquidity(positionId) == 0) revert InvalidPosition();

        _positions[token] = LockedPosition({poolId: poolId, positionId: positionId, exists: true});
        tokenForPosition[positionId] = token;
        emit PositionRegistered(token, poolId, positionId);
    }

    function getPosition(address token) external view returns (LockedPosition memory) {
        return _positions[token];
    }

    function noteTokenDust(address token, uint256 amount) external onlyFactory {
        if (amount != 0) emit TokenDustLocked(token, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(positionManager)) revert InvalidPosition();
        return IERC721Receiver.onERC721Received.selector;
    }
}
