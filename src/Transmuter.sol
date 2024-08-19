// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./libraries/TokenUtils.sol";
import "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import "./interfaces/ITransmuter.sol";
import "./interfaces/ITransmuterErrors.sol";
import "./interfaces/IAlchemistV3.sol";

import {ERC1155} from "../lib/openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";

struct InitializationParams {
    address syntheticToken;
    uint256 timeToTransmute;
}

/// @title AlchemixV3 Transmuter
///
/// @notice A contract which facilitates the exchange of alAssets to yield bearing assets.
contract Transmuter is ITransmuter, ITransmuterErrors, ERC1155 {
    // Alchemix synthetic asset to be transmuted.
    // TODO make this ERC20 rather than addess
    address public syntheticToken;

    // Nft contract for transmuter positions.
    address public transmuterNFT;

    // Time to transmute a position, denominated in days.
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

        positions[msg.sender][nonce] = StakingPosition(alchemist, collateral, depositAmount, block.timestamp + timeToTransmute);
        
        _updateRedemptionRate();

        emit PositionCreated(msg.sender, alchemist, depositAmount, nonce);
    }

    function claimRedemption(uint256 id) external {
        // TODO: Potentially add allowances for other addresses
        StakingPosition storage position = positions[msg.sender][id];

        if(position.positionMaturationDate > block.timestamp)
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
        /* Steps to calculate and other considerations/thoughts
        
            1) Sum debts from each Alchemist
        
            2) Total debt locked in transmuter / sum of user debt (need to scale this so we dont lose precision)
            
            3) Scale this by  1 year / time to transmute (Spec says % per year)

            Ex. Sum of Alchemist debts = 100
                Sum of transmuter positions = 60
                Transmutation time = 6 Months

                60 / 100 = 0.6 of debt needs to be redeemed
                1 year / 6 months = 2
                0.6 * 2 = 1.2 or 120% per year

                We can't redeem more than 100% of debt so we will have to scale this differently than one year
                I guess I'm not entirely sure what redemption times we are going to allow
                The smaller the timeframe of a transmuter position the smaller the scaling time needs to be

                1 month would work for the above example

                60 / 100 = 0.6 of debt needs to be redeemed
                1 month / 6 months = 0.1666....
                0.6 * 0.1666... = 0.1 or 10% per month redeemed 
                10% * 6 months = 60% of debt redeemed

                But... If we are transmuting over 15 days

                60 / 100 = 0.6 of debt needs to be redeemed
                1 month / 15 days = 2
                0.6 * 2... = 1.20 which we can't have

                After we decide on these factors then then final percentage is applied to each alchemists individual debt
            
            Obviously all transmutation positions won't start at the same time so we need to think of a way to handle this

            Ex. Tranmutation time = 6 months
                Redemption rate is scaled per month

                User Positions
                P1 = (100 debt tokens, started at day 0)
                P2 = (150 debt tokens, started at 2 months)
                P3 = (60 debt tokens, started at 4 months and 15 days)

                Every time a user makes a stake or claim in this contract the rate is updated
                Also, every time the Alchemist has debt updated through a mint or a repay

                Let's say that the Alchemist started with 300 debt total 
                    Rate is 0 now since no transmuter positions

                At time 0 a 100 debt token position is staked into the transmuter (P1)
                    30% of debt to redeem over 6 months so need 5% per month redeemed
                
                Now 100 more debt taken in one of the alchemists at 1 month
                    5% was redeemed so now total user debt is 300 - (0.05 * 300) + 100 = 385 total debt
                        Do we send the 15 collateral assets to the transmuter or leave them in alchemist?
                    Transmuter still has same debt staked so we take difference of set aside collateral
                        Transmuter has 100 - 15 = 85 debt to redeem for next 5 months
                        Need to figure out how to track time passed for positions 

                        Perhaps we need to keep a running average of position times
                        Could also just over estimate to some degree

                        Will have more thoughts later.....

            On the alchemist side we need to decide how to handle checkpoints

            Here is a quick write up of what I was thinking

            Store the rates as checkpoints any time debt is changed
            This happens during redemptions, repays, and mints
            So with each redemption or repay we store rates as well as the total debt in the specific alchemist
            This way we know exactly how long each rate was active and for what total debt values

            Ex. 
                Alchemist has 100 debt and rate is 50% per year

                Someone mints 10 more debt and rate becomes 48% per year since there is more debt to redeem

                Another mint happens and rate goes to 45%

                [[100, 0.5, time 1], [85,0.48, time 2], [74.6,0.45, time 3]]

                So between time 1 and 2 the rate is 50% at 100. 
                Lets say time is 6 months
                So 25% of 100 = 25 debt redeemed
                User mints and triggers debt change and someone redeems
                so 25 redeemed + 10 debt = 85 total debt now with new rate of 0.48 (this number is made up for now)
                At time 3 someone mints and triggers debt change and someone redeems
                Lets say time 2 to time 3 is also 6 months
                Now debt is 85 - (85 * 0.24) + 10 = 74.6 total debt in the system
                Someone redeems at some time later but no other action have happened
                Now you just need to take (current time - last checkpoint) scaled to rate and apply that to current debt value)
                We would have checkpoints every time debt gets updated, but we will also track which checkpoints have had redemptions
                This way if two mints happen between redemptions we can calculate the values for both checkpoints in between
        */

        // ~~~~Mock up for MVP~~~~

        // TODO precision and rounding

        uint256 alchemistDebt;

        for (uint256 i = 0; i < alchemists.length; i++) {
            alchemistDebt += IAlchemistV3(alchemists[i]).cumulativeDebt();
        }

        // TODO we need to keep track of which tokens in here are pending a sweep and are not actually part of an active position
        redemptionRate = (alchemistDebt * 1e18 / IERC20(syntheticToken).balanceOf(address(this))) * 365 days / timeToTransmute;
        // We will need to take this scaling into account down the pipeline

        emit RedemptionRateUpdated(block.timestamp, redemptionRate);
    }
}