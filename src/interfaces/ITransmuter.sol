// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface ITransmuter {
    // TODO: Fill this in with functions events and full comments:) 

    /// @notice Emitted when the admin address is updated.
    ///
    /// @param admin The new admin address.
    event AdminUpdated(address admin);

    /// @dev Emitted when a position is created.
    ///
    /// @param creator          The address that created the position.
    /// @param alchemist        The address of the alchemist which tokens will be claimed from.
    /// @param amountStaked     The amount of tokens staked.
    event PositionCreated(
        address indexed creator,
        address indexed alchemist,
        uint256 amountStaked
    );

    /// @dev Emitted when a position is claimed.
    ///
    /// @param claimer          The address that claimed the position.
    /// @param alchemist        The address of the alchemist which tokens were claimed from.
    /// @param amountClaimed    The amount of tokens claimed.
    event PositionClaimed(
        address indexed claimer,
        address indexed alchemist,
        uint256 amountClaimed
    );

    /// @dev Emitted when redemption rate is updated through claim or stake.
    ///
    /// @param timestamp        The time at which redemption rate was changed.
    /// @param rate             The new rate (BPS per year).
    event RedemptionRateUpdated(
        uint256 timestamp,
        uint256 rate
    );
}   