// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./libraries/TokenUtils.sol";

import "./interfaces/ITransmuter.sol";

struct InitializationParams {
    address syntheticToken;
    uint256 timeToTransmute;
}

/// @title AlchemixV3 Transmuter
///
/// @notice A contract which facilitates the exchange of alAssets to yield bearing assets.
contract Transmuter is ITransmuter {
    // TODO: Potentially replace this with NFT respresented position
    struct StakingPosition {
        // Alchemist from which collateral will be drawn from. 
        // TODO: figure out how to handle this for multi collateral positions
        // Scoopy suggested allowing users to claim an even mix of assets from all registered alchemists n times faster than usual
        // For now will handle as single collateral asset.
        address alchemist;

        // Address of the collateral address that the user requested. 
        // TODO: Once this code is combined with the AlchemistV3 code we can just pull this data from there instead of storing it here.
        address collateralAsset;

        // Amount staked.
        uint256 amount;

        // Time when the transmutation will be complete/claimable.
        uint256 positionMaturationDate;
    }

    // Alchemix synthetic asset to be transmuted.
    address public syntheticToken;

    // Time to transmute a position, denominated in days.
    uint256 public timeToTransmute;

    // Total alAssets locked in the system.
    uint256 public totalLocked;

    // TODO: Remove this once NFTs are implemented. 
    // Value to mock incrementing NFT token ids.
    uint256 public idCounter;

    // The current redemption rate
    uint256 public redemptionRate;

    /// @dev Array of all registered alchemists. 
    address[] public alchemists;

    /// @dev Map of addresses to index in `alchemists` array
    mapping(address => uint256) public alchemistIndex;

    /// @dev Map of addresses to a map of NFT tokenId to associated position.
    mapping(address => mapping(uint256 => StakingPosition)) private positions;

    // TODO: Replace with upgradeable initializer
    constructor(InitializationParams memory params) {
        syntheticToken = params.syntheticToken;
        timeToTransmute = params.timeToTransmute;
    }

    //TODO: Add access control for admin things

    /* ----------------ADMIN FUNCTIONS---------------- */

    // Adds an Alchemist to the transmuter
    function addAlchemist(address alchemist) external {
        require(alchemistIndex[alchemist] == 0, "Alchemist has already been added!");
        alchemists.push(alchemist);
        alchemistIndex[alchemist] = alchemists.length - 1;
    }

    // Removes an Alchemist from the transmuter
    function removeAlchemist(address alchemist) external {
        alchemists[alchemistIndex[alchemist]] = alchemists[alchemists.length-1];
        alchemists.pop();
        alchemistIndex[alchemist] = 0;
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

    // TODO: Remove this once NFTs are implemented. Should be handled in UI
    function getPositions(address account, uint256[] calldata ids) external view returns(StakingPosition[] memory) {
        StakingPosition[] memory userPositions = new StakingPosition[](ids.length);

        for (uint256 i = 0; i < ids.length - 1; i++) {
            userPositions[i] = positions[account][ids[i]];
        }

        return userPositions;
    }

    function createRedemption(address alchemist, address collateral, uint256 depositAmount) external {
        require(depositAmount > 0, "Value must be greater than 0!");

        // TODO: Create NFT

        positions[msg.sender][idCounter] = StakingPosition(alchemist, collateral, depositAmount, block.timestamp + timeToTransmute);
        
        idCounter++;

        _updateRedemptionRate();

        emit PositionCreated(msg.sender, alchemist, depositAmount);
    }

    function claimRedemption(uint256 id) external {
        // TODO: Potentially add allowances for other addresses
        StakingPosition storage position = positions[msg.sender][id];

        require(position.positionMaturationDate <= block.timestamp, "Position has not reached maturity!");
        require(position.positionMaturationDate != 0, "No position found!");

        TokenUtils.safeTransferFrom(
            position.collateralAsset, // TODO: Change to alchemist.collaterAsset() later
            position.alchemist,
            msg.sender,
            position.amount
        );

        delete positions[msg.sender][id];

        // TODO: burn NFT

        _updateRedemptionRate();

        emit PositionClaimed(msg.sender, position.alchemist, position.amount);
    }

    /* ---------------INTERNAL FUNCTIONS--------------- */

    // Called when position is claimed or created
    function _updateRedemptionRate() internal {

        // Some thoughts
        // There will be times when users can claim their position, but won't yet have done so.
        // This means that the alchemists are still setting aside collateral and the rate is 'outdated' for that time.
        // What ends up happening is that the alchemists are taking too much from users when they don't have to.
        // I can't see it hurting the protocol directly from having surpluss set aside.
        // However, users ability to take out more debt or withdraw collateral may be skewed because of this.

        emit RedemptionRateUpdated(block.timestamp, redemptionRate);
    }
}