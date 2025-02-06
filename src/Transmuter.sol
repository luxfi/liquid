// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./interfaces/IAlchemistV3.sol";
import "./interfaces/IERC20Minimal.sol";
import "./interfaces/ITransmuter.sol";
import "./interfaces/TransmuterErrors.sol";

import "./libraries/TokenUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {StakingGraph} from "./libraries/StakingGraph.sol";

import {Unauthorized, IllegalArgument, IllegalState, InsufficientAllowance} from "./base/Errors.sol";

/// @title AlchemixV3 Transmuter
///
/// @notice A contract which facilitates the exchange of alAssets to yield bearing assets.
contract Transmuter is ITransmuter, ERC1155 {
    using StakingGraph for mapping(uint256 => int256);
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @inheritdoc ITransmuter
    string public constant version = "1.0.0";

    uint256 public constant BPS = 10_000;

    int256 public constant BLOCK_SCALING_FACTOR = 1e8;

    /// @inheritdoc ITransmuter
    uint256 public depositCap;

    /// @inheritdoc ITransmuter
    uint256 public exitFee;

    /// @inheritdoc ITransmuter
    uint256 public graphSize;

    /// @inheritdoc ITransmuter
    uint256 public transmutationFee;

    /// @inheritdoc ITransmuter
    uint256 public timeToTransmute;

    /// @inheritdoc ITransmuter
    uint256 public totalLocked;

    /// @inheritdoc ITransmuter
    address public admin;

    /// @inheritdoc ITransmuter
    address public protocolFeeReceiver;

    /// @inheritdoc ITransmuter
    address public syntheticToken;

    /// @dev Array of registered alchemists.
    address[] public alchemists;

    /// @dev Map of alchemist addresses to corresponding entry data.
    mapping(address => AlchemistEntry) internal _alchemistEntries;

    /// @dev Map of user positoins data.
    mapping(address => mapping(uint256 => StakingPosition)) internal _positions;

    /// @dev Mapping used for staking graph.
    mapping(uint256 => int256) internal _graph1;

    /// @dev Mapping used for staking graph.
    mapping(uint256 => int256) internal _graph2;

    /// @dev Nonce data used for minting of new nft positions.
    uint256 internal _nonce;

    modifier onlyAdmin() {
        _checkArgument(msg.sender == admin);
        _;
    }

    // TODO: Replace with upgradeable initializer
    constructor(InitializationParams memory params) ERC1155("https://alchemix.fi/transmuter/{id}.json") {
        syntheticToken = params.syntheticToken;
        timeToTransmute = params.timeToTransmute;
        transmutationFee = params.transmutationFee;
        exitFee = params.exitFee;
        protocolFeeReceiver = params.feeReceiver;
        admin = msg.sender;
        graphSize = params.graphSize;
    }

    /// @inheritdoc ITransmuter
    function addAlchemist(address alchemist) external onlyAdmin {
        if(_alchemistEntries[alchemist].isActive == true) 
            revert AlchemistDuplicateEntry();

        alchemists.push(alchemist);
        _alchemistEntries[alchemist] = AlchemistEntry(alchemists.length-1, true);
    }

    /// @inheritdoc ITransmuter
    function removeAlchemist(address alchemist) external onlyAdmin {
        if(_alchemistEntries[alchemist].isActive == false) 
            revert NotRegisteredAlchemist();

        alchemists[_alchemistEntries[alchemist].index] = alchemists[alchemists.length-1];
        alchemists.pop();
        delete _alchemistEntries[alchemist];
    }

    /// @inheritdoc ITransmuter
    function setDepositCap(uint256 cap) external onlyAdmin {
        _checkArgument(cap >= totalLocked);

        depositCap = cap;
        emit DepositCapUpdated(cap);
    } 

    /// @inheritdoc ITransmuter
    function setTransmutationFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        transmutationFee = fee;
        emit TransmutationFeeUpdated(fee);
    }

    /// @inheritdoc ITransmuter
    function setExitFee(uint256 fee) external onlyAdmin {
        _checkArgument(fee <= BPS);

        exitFee = fee;
        emit ExitFeeUpdated(fee);
    }

    /// @inheritdoc ITransmuter
    function setTransmutationTime(uint256 time) external onlyAdmin {
        timeToTransmute = time;
    }

    /// @inheritdoc ITransmuter
    function setProtocolFeeReceiver(address value) external onlyAdmin {
        _checkArgument(value != address(0));
        protocolFeeReceiver = value;
        emit ProtocolFeeReceiverUpdated(value);
    }

    /// @inheritdoc ITransmuter
    function alchemistEntries(address alchemist) external view returns (uint256, bool) {
        AlchemistEntry storage entry = _alchemistEntries[alchemist];

        return (entry.index, entry.isActive);
    }

    /// @inheritdoc ITransmuter
    function getPositions(address account, uint256[] calldata ids) external view returns(StakingPosition[] memory) {
        StakingPosition[] memory userPositions = new StakingPosition[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            userPositions[i] = _positions[account][ids[i]];
        }

        return userPositions;
    }

    /// @inheritdoc ITransmuter
    function createRedemption(address alchemist, address yieldToken, uint256 syntheticDepositAmount) external {
        if(syntheticDepositAmount == 0)
            revert DepositZeroAmount();

        // TODO cap deposit so that when it is converted to int it wont break

        if(totalLocked + syntheticDepositAmount > depositCap)
            revert DepositCapReached();

        if(_alchemistEntries[alchemist].isActive == false)
            revert NotRegisteredAlchemist();

        TokenUtils.safeTransferFrom(
            syntheticToken,
            msg.sender,
            address(this),
            syntheticDepositAmount
        );

        // TODO: Add `data` param if we decide we need this. ERC1155
        _mint(msg.sender, ++_nonce, syntheticDepositAmount, "");

        _positions[msg.sender][_nonce] = StakingPosition(alchemist, yieldToken, syntheticDepositAmount, block.number + timeToTransmute - 1);

        // Update Fenwick Tree
        _updateStakingGraph(syntheticDepositAmount.toInt256() * BLOCK_SCALING_FACTOR / timeToTransmute.toInt256(), timeToTransmute - 1);

        totalLocked += syntheticDepositAmount;
        
        emit PositionCreated(msg.sender, alchemist, syntheticDepositAmount, _nonce);
    }

    /// @inheritdoc ITransmuter
    function claimRedemption(uint256 id) external {
        StakingPosition storage position = _positions[msg.sender][id];

        if(position.positionMaturationBlock == 0)
            revert PositionNotFound();

        // TODO: Optimize this
        uint256 blocksLeft = position.positionMaturationBlock > block.number ? position.positionMaturationBlock - block.number: 0;
        uint256 amountEarly = blocksLeft > 0 ? position.amount * blocksLeft / timeToTransmute : 0;
        uint256 amountMatured = position.amount - amountEarly;

        // Burn position NFT
        _burn(msg.sender, id, position.amount);

        // If the contract has a balance of yield tokens from alchemist repayments then we only need to redeem partial or none from Alchemist earmarked
        uint256 yieldTokenBalance = TokenUtils.safeBalanceOf(position.yieldToken, address(this));
        // TODO: This will break if balance exceeds a certain amount due to overflow. Come up with limits to make sure that this will never fail.
        uint256 underlyingValue = IAlchemistV3(position.alchemist).convertYieldTokensToUnderlying(yieldTokenBalance);
        uint256 amountToRedeem = amountMatured > underlyingValue ? amountMatured - underlyingValue : 0;

        if (amountToRedeem > 0) IAlchemistV3(position.alchemist).redeem(amountToRedeem);

        uint256 feeAmount = amountMatured * transmutationFee / BPS;
        uint256 claimAmount = amountMatured - feeAmount;

        uint256 syntheticFee = amountEarly * exitFee / BPS;
        uint256 syntheticReturned = amountEarly - syntheticFee;

        if (amountEarly > 0) _updateStakingGraph(amountEarly.toInt256() / blocksLeft.toInt256(), blocksLeft);

        TokenUtils.safeTransfer(
            position.yieldToken,
            msg.sender,
            IAlchemistV3(position.alchemist).convertUnderlyingTokensToYield(claimAmount)
        );

        TokenUtils.safeTransfer(
            position.yieldToken,
            protocolFeeReceiver,
            IAlchemistV3(position.alchemist).convertUnderlyingTokensToYield(feeAmount)
        );

        TokenUtils.safeTransfer(syntheticToken, msg.sender, syntheticReturned);
        TokenUtils.safeTransfer(syntheticToken, protocolFeeReceiver, syntheticFee);

        // Burn remaining synths that were not returned
        TokenUtils.safeBurn(syntheticToken, position.amount - amountEarly);

        totalLocked -= position.amount;

        // TODO: update this with more values for matured vs non matured
        emit PositionClaimed(msg.sender, position.alchemist, position.amount);

        delete _positions[msg.sender][id];
    }

    /// @inheritdoc ITransmuter
    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256) {
        int256 queried = (endBlock.toInt256() * _graph1.query(endBlock) - _graph2.query(endBlock)) - ((startBlock - 1).toInt256() * _graph1.query(startBlock - 1) - _graph2.query(startBlock - 1));

        return (queried / BLOCK_SCALING_FACTOR).toUint256();
    }

    /// @dev Updates staking graphs 
    function _updateStakingGraph(int256 amount, uint256 blocks) private {
        //TODO: Optimize this to reduce amount of reads and writes. Currently gas heavy.
        uint256 currentBlock = block.number; 
        uint256 expirationBlock = currentBlock + blocks;

        _graph1.update(currentBlock, graphSize, amount);
        _graph1.update(expirationBlock + 1, graphSize, -amount);

        _graph2.update(currentBlock, graphSize, amount * (currentBlock - 1).toInt256());
        _graph2.update(expirationBlock + 1, graphSize, -amount * expirationBlock.toInt256());
    }

    /// @dev Checks an expression and reverts with an {IllegalArgument} error if the expression is {false}.
    ///
    /// @param expression The expression to check.
    function _checkArgument(bool expression) internal pure {
        if (!expression) {
            revert IllegalArgument();
        }
    }
}