// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./libraries/TokenUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {SafeCast} from "./libraries/SafeCast.sol";
import {StakingGraph} from "./libraries/StakingGraph.sol";

import "./interfaces/ITransmuter.sol";
import "./interfaces/ITransmuterErrors.sol";
import "./interfaces/IAlchemistV3.sol";
import "./interfaces/IERC20Minimal.sol";

/// @title AlchemixV3 Transmuter
///
/// @notice A contract which facilitates the exchange of alAssets to yield bearing assets.
contract Transmuter is ITransmuter, ITransmuterErrors, ERC1155 {
    using StakingGraph for mapping(uint256 => int256);
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @inheritdoc ITransmuter
    address public syntheticToken;

    /// @inheritdoc ITransmuter
    uint256 public timeToTransmute;

    /// @inheritdoc ITransmuter
    uint256 public totalLocked;

    /// @dev Array of registered alchemists.
    address[] public alchemists;

    /// @dev Map of alchemist addresses to corresponding entry data.
    mapping(address => AlchemistEntry) private _alchemistEntries;

    /// @dev Map of user positoins data.
    mapping(address => mapping(uint256 => StakingPosition)) private _positions;

    /// @dev Staking graph fenwick tree.
    mapping(uint256 => int256) private _graph;

    /// @dev Nonce data used for minting of new nft positions.
    uint256 private _nonce;

    // TODO: Replace with upgradeable initializer
    constructor(InitializationParams memory params) ERC1155("https://alchemix.fi/transmuter/{id}.json") {
        syntheticToken = params.syntheticToken;
        timeToTransmute = params.timeToTransmute;
    }

    //TODO: Add access control for admin things

    /* ----------------ADMIN FUNCTIONS---------------- */

    /// @inheritdoc ITransmuter
    function addAlchemist(address alchemist) external {
        if(_alchemistEntries[alchemist].isActive == true) 
            revert AlchemistDuplicateEntry();

        alchemists.push(alchemist);
        _alchemistEntries[alchemist] = AlchemistEntry(alchemists.length-1, true);
    }

    /// @inheritdoc ITransmuter
    function removeAlchemist(address alchemist) external {
        if(_alchemistEntries[alchemist].isActive == false) 
            revert NotRegisteredAlchemist();

        alchemists[_alchemistEntries[alchemist].index] = alchemists[alchemists.length-1];
        alchemists.pop();
        delete _alchemistEntries[alchemist];
    }

    /// @inheritdoc ITransmuter
    function setTransmutationTime(uint256 time) external {
        timeToTransmute = time;
    }

    /* ---------------EXTERNAL FUNCTIONS--------------- */

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
    function createRedemption(address alchemist, address underlying, uint256 depositAmount) external {
        if(depositAmount == 0)
            revert DepositZeroAmount();

        if(_alchemistEntries[alchemist].isActive == false)
            revert NotRegisteredAlchemist();

        TokenUtils.safeTransferFrom(
            syntheticToken,
            msg.sender,
            address(this),
            depositAmount
        );

        // TODO: Add `data` param if we decide we need this. ERC1155
        _mint(msg.sender, ++_nonce, depositAmount, "");

        _positions[msg.sender][_nonce] = StakingPosition(alchemist, underlying, depositAmount, block.number + timeToTransmute);

        // Update Fenwick Tree
        _graph.updateStakingGraph(depositAmount.toInt256()/ timeToTransmute.toInt256(), timeToTransmute);
        
        emit PositionCreated(msg.sender, alchemist, depositAmount, _nonce);
    }

    /// @inheritdoc ITransmuter
    function claimRedemption(uint256 id) external {
        // TODO: Potentially add allowances for other addresses
        StakingPosition storage position = _positions[msg.sender][id];

        if(position.positionMaturationBlock == 0)
            revert PositionNotFound();

        if(position.positionMaturationBlock > block.number)
            revert PrematureClaim();

        _burn(msg.sender, id, position.amount);

        // If the contract has a balance of underlying tokens from alchemist repayments then we only need to redeem partial or none from Alchemist earmarked
        uint256 underlyingBalance = TokenUtils.safeBalanceOf(position.underlyingAsset, address(this));
        uint256 amountToRedeem = position.amount > underlyingBalance ? position.amount - underlyingBalance : 0;

        if (amountToRedeem > 0) IAlchemistV3(position.alchemist).redeem(amountToRedeem);

        TokenUtils.safeTransfer(position.underlyingAsset, msg.sender, position.amount);

        emit PositionClaimed(msg.sender, position.alchemist, position.amount);

        delete _positions[msg.sender][id];
    }

    /// @inheritdoc ITransmuter
    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256) {
        return _graph.rangeQuery(startBlock, endBlock);
    }
}