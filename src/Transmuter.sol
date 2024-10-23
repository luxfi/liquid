// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./libraries/TokenUtils.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {ERC1155} from "../lib/openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
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

    // The current redemption rate
    uint256 public redemptionRate;

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

    // Allows alchemist to update redemption rate when new debt is minted or repayed
    function updateRedemptionRate() external {
        if(alchemistEntries[msg.sender].isActive == false)
            revert NotRegisteredAlchemist();

        _updateRedemptionRate();
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

    // TODO: If we decide to let users take split of collateral from all alchemists then this needs to be updated
    // TODO: Specifying the alchemist isn't plausible so need to change this
    // If not then we should be pull collateral address from alchemist once it is merged in
    function createRedemption(address alchemist, address collateral, uint256 depositAmount) external {
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

        // TODO: Add `data` param if we decide we need this
        _mint(msg.sender, ++nonce, depositAmount, "");

        positions[msg.sender][nonce] = StakingPosition(alchemist, collateral, depositAmount, block.number + timeToTransmute);

        // Update Fenwick Tree
        graph.updateStakingGraph(depositAmount.toInt256(), timeToTransmute);
        
        _updateRedemptionRate();

        emit PositionCreated(msg.sender, alchemist, depositAmount, nonce);
    }

    function claimRedemption(uint256 id) external {
        // TODO: Potentially add allowances for other addresses
        StakingPosition storage position = positions[msg.sender][id];

        if(position.positionMaturationDate > block.number)
            revert PrematureClaim();

        if(position.positionMaturationDate == 0)
            revert PositionNotFound();

        TokenUtils.safeTransferFrom(
            position.collateralAsset, // TODO: Change to alchemist.collaterAsset() later
            position.alchemist,
            msg.sender,
            position.amount
        );

        delete positions[msg.sender][id];

        _burn(msg.sender, id, position.amount);

        _updateRedemptionRate();

        emit PositionClaimed(msg.sender, position.alchemist, position.amount);
    }

    /* ---------------INTERNAL FUNCTIONS--------------- */

    // Called when position is claimed or created
    function _updateRedemptionRate() internal {
        uint256 alchemistDebt = IERC20Minimal(syntheticToken).totalSupply();

        uint256 currentStaked = graph.currentStaked(block.number);

        // TODO: create variable or bitmap of how many blocks each 'bucket' lasts for
        // This will help us determine what the rate per block should be
        // For example, if the most recent 'bucket' is for 100 tokens and there are total of 1000
        // in the alchemist and the 'bucket' lasts 20 blocks, then we need to redeem 0.5% of each users
        // debt each block. 

        // After the 20 blocks the next 'bucket' would be less than the previous one
        // This would require another update to debt or new transmuter stake to reflect new 'bucket'
        // This would lead to some small periods of time where we are slightly over redeeming users debt
        // If we keep track of when 'buckets' end then we can adjust the rate to reflect any previous extra redemptions

        // For now I will just use this value not scaled for blocks like described above.
        redemptionRate = (currentStaked * 1e18 / alchemistDebt);

        emit RedemptionRateUpdated(block.number, redemptionRate);
    }
}