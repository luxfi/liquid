// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

/// @title  ITransmuterErrors
/// @author Alchemix Finance
///
/// @notice Specifies errors.
interface ITransmuterErrors {
    error NotRegisteredAlchemist();

    error AlchemistDuplicateEntry();

    error DepositZeroAmount();

    error PositionNotFound();

    error PrematureClaim();
}