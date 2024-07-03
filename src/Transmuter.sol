// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

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
    mapping(address => AlchemistEntry) public alchemistEntries;

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
        require(alchemistEntries[alchemist].isActive == false, "Alchemist has already been added!");
        alchemists.push(alchemist);
        alchemistEntries[alchemist] = AlchemistEntry(alchemists.length-1, true);
    }

    // Removes an Alchemist from the transmuter
    function removeAlchemist(address alchemist) external {
        require(alchemistEntries[alchemist].isActive == true, "Alchemist is not registered!");
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

    // TODO: If we decide to let users take split of collateral from all alchemists then this needs to be updated
    // If not then we should be pull collateral address from alchemist once it is merged in
    function createRedemption(address alchemist, address collateral, uint256 depositAmount) external {
        require(depositAmount > 0, "Value must be greater than 0!");
        require(alchemistEntries[alchemist].isActive == true, "Alchemist is not registered!");

        // TODO: Create NFT

        positions[msg.sender][idCounter] = StakingPosition(alchemist, collateral, depositAmount, block.timestamp + timeToTransmute);
        
        _updateRedemptionRate();

        emit PositionCreated(msg.sender, alchemist, depositAmount, idCounter);
                
        idCounter++;
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