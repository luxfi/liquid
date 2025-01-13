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

struct InitializationParams {
    address syntheticToken;
    uint256 timeToTransmute;
}

/// @title AlchemixV3 Transmuter
///
/// @notice A contract which facilitates the exchange of alAssets to yield bearing assets.
contract Transmuter is ITransmuter, ITransmuterErrors, ERC1155 {
    using StakingGraph for mapping(uint256 => int256);
    using SafeCast for int256;
    using SafeCast for uint256;

    // Alchemix synthetic asset to be transmuted.
    // TODO make this ERC20 rather than addess
    address public syntheticToken;

    // Nft contract for transmuter positions.
    address public transmuterNFT;

    // Time to transmute a position, denominated in blocks.
    uint256 public timeToTransmute;

    // Total alAssets locked in the system.
    uint256 public totalLocked;

    // Nonce to increment nft IDs.
    uint256 public nonce;

    /// @dev Array of all registered alchemists.
    address[] public alchemists;

    /// @dev Map of addresses to index in `alchemists` array
    mapping(address => AlchemistEntry) public alchemistEntries;

    /// @dev Map of addresses to a map of NFT tokenId to associated position.
    mapping(address => mapping(uint256 => StakingPosition)) private positions;

    /// @dev Fenwick Tree of user staking positions.
    mapping(uint256 => int256) internal graph;

    // TODO: Replace with upgradeable initializer
    constructor(InitializationParams memory params) ERC1155("https://alchemix.fi/transmuter/{id}.json") {
        syntheticToken = params.syntheticToken;
        timeToTransmute = params.timeToTransmute;
    }

    //TODO: Add access control for admin things

    /* ----------------ADMIN FUNCTIONS---------------- */

    // Adds an Alchemist to the transmuter
    function addAlchemist(address alchemist) external {
        if(alchemistEntries[alchemist].isActive == true) 
            revert AlchemistDuplicateEntry();

        alchemists.push(alchemist);
        alchemistEntries[alchemist] = AlchemistEntry(alchemists.length-1, true);
    }

    // Removes an Alchemist from the transmuter
    function removeAlchemist(address alchemist) external {
        if(alchemistEntries[alchemist].isActive == false) 
            revert NotRegisteredAlchemist();

        alchemists[alchemistEntries[alchemist].index] = alchemists[alchemists.length-1];
        alchemists.pop();
        delete alchemistEntries[alchemist];
    }

    // Sets the transmutation time, denoted in days.
    function setTransmutationTime(uint256 time) external {
        timeToTransmute = time;
    }

    // Sweeps locked alAssets
    function sweepTokens() external {
        TokenUtils.safeTransfer(syntheticToken, msg.sender, TokenUtils.safeBalanceOf(syntheticToken, address(this)));
    }

    /* ---------------EXTERNAL FUNCTIONS--------------- */

    // IDs can be seen from UI, which will input them into this function to get data
    // Potentially move this to the NFT entirely, but likely need some on chain data
    function getPositions(address account, uint256[] calldata ids) external view returns(StakingPosition[] memory) {
        StakingPosition[] memory userPositions = new StakingPosition[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            userPositions[i] = positions[account][ids[i]];
        }

        return userPositions;
    }

    function createRedemption(address alchemist, address underlying, uint256 depositAmount) external {
        if(depositAmount == 0)
            revert DepositZeroAmount();

        if(alchemistEntries[alchemist].isActive == false)
            revert NotRegisteredAlchemist();

        TokenUtils.safeTransferFrom(
            syntheticToken,
            msg.sender,
            address(this),
            depositAmount
        );

        // TODO: Add `data` param if we decide we need this. ERC1155
        _mint(msg.sender, ++nonce, depositAmount, "");

        positions[msg.sender][nonce] = StakingPosition(alchemist, underlying, depositAmount, block.number + timeToTransmute);

        // Update Fenwick Tree
        graph.updateStakingGraph(depositAmount.toInt256()/ timeToTransmute.toInt256(), timeToTransmute);
        
        emit PositionCreated(msg.sender, alchemist, depositAmount, nonce);
    }

    function claimRedemption(uint256 id) external {
        // TODO: Potentially add allowances for other addresses
        StakingPosition storage position = positions[msg.sender][id];

        if(position.positionMaturationBlock > block.number)
            revert PrematureClaim();

        if(position.positionMaturationBlock == 0)
            revert PositionNotFound();

        delete positions[msg.sender][id];

        _burn(msg.sender, id, position.amount);

        // If the contract has a balance of underlying tokens from alchemist repayments then we only need to redeem partial or none from Alchemist earmarked
        uint256 underlyingBalance = TokenUtils.safeBalanceOf(position.underlyingAsset, address(this));
        uint256 amountToRedeem = position.amount > underlyingBalance ? position.amount - underlyingBalance : 0;

        if (amountToRedeem > 0) IAlchemistV3(position.alchemist).redeem(amountToRedeem);

        TokenUtils.safeTransfer(position.underlyingAsset, msg.sender, position.amount);

        emit PositionClaimed(msg.sender, position.alchemist, position.amount);
    }

    function queryGraph(uint256 startBlock, uint256 endBlock) external view returns (uint256) {
        return graph.rangeQuery(startBlock, endBlock);
    }
}