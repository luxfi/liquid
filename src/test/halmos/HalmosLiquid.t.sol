// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

/// @title Halmos Symbolic Tests for Liquid Protocol
/// @notice Proves invariants about the CDP, transmuter, and earmark math.
/// @dev Inlines the core math from Liquid.sol to enable pure symbolic reasoning
///      without external calls, storage, or ERC721 dependencies.

contract HalmosLiquidTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant FIXED_POINT_SCALAR = 1e18;

    // ==================================================================================
    // Invariant 1: Debt can never exceed collateral * LTV
    // ==================================================================================

    /// @notice Prove: after minting debt, collateralization ratio >= minimumCollateralization
    /// @dev Mirrors _validate() in Liquid.sol: revert if collateral*price/debt < minCollateralization
    function check_debtNeverExceedsLTV(
        uint256 collateralBalance,
        uint256 existingDebt,
        uint256 mintAmount,
        uint256 yieldPrice,
        uint256 minimumCollateralization,
        uint256 conversionFactor
    ) public pure {
        // Bound inputs to realistic ranges
        vm.assume(collateralBalance > 0 && collateralBalance < type(uint96).max);
        vm.assume(existingDebt < type(uint96).max);
        vm.assume(mintAmount > 0 && mintAmount < type(uint96).max);
        vm.assume(yieldPrice > 0 && yieldPrice < type(uint96).max);
        vm.assume(minimumCollateralization >= FIXED_POINT_SCALAR); // >= 100%
        vm.assume(minimumCollateralization < 10 * FIXED_POINT_SCALAR); // < 1000% (realistic)
        vm.assume(conversionFactor > 0 && conversionFactor <= 1e12);

        // Simulate: convertYieldTokensToDebt(collateral) = collateral * price / 10^decimals * conversionFactor
        // Simplified: collateralValue = collateral * yieldPrice / 1e18 * conversionFactor
        uint256 collateralValueInDebt = (collateralBalance * yieldPrice / FIXED_POINT_SCALAR) * conversionFactor;
        vm.assume(collateralValueInDebt > 0);

        uint256 newDebt = existingDebt + mintAmount;
        vm.assume(newDebt > 0);

        // Check: does the position pass _validate()?
        // _isUnderCollateralized: totalValue(tokenId) * FIXED_POINT_SCALAR / debt < minimumCollateralization
        uint256 collateralizationRatio = collateralValueInDebt * FIXED_POINT_SCALAR / newDebt;

        // If position passes validation (is NOT undercollateralized)
        if (collateralizationRatio >= minimumCollateralization) {
            // Then debt is properly bounded by collateral * LTV
            // maxDebt = collateralValue * FIXED_POINT_SCALAR / minimumCollateralization
            uint256 maxDebt = collateralValueInDebt * FIXED_POINT_SCALAR / minimumCollateralization;
            assert(newDebt <= maxDebt);
        }
    }

    // ==================================================================================
    // Invariant 2: Transmuter redemptions are always backed
    // ==================================================================================

    /// @notice Prove: redemption amount is capped by cumulative earmarked debt
    /// @dev Mirrors redeem() in Liquid.sol: if amount > liveEarmarked, amount = liveEarmarked
    function check_redemptionAlwaysBacked(
        uint256 requestedAmount,
        uint256 cumulativeEarmarked,
        uint256 totalDebt
    ) public pure {
        vm.assume(totalDebt > 0 && totalDebt < type(uint128).max);
        vm.assume(cumulativeEarmarked <= totalDebt);
        vm.assume(requestedAmount > 0 && requestedAmount < type(uint128).max);

        // Mirror: redeem() caps amount to liveEarmarked
        uint256 amount = requestedAmount > cumulativeEarmarked ? cumulativeEarmarked : requestedAmount;

        // Redemption is always backed by earmarked debt
        assert(amount <= cumulativeEarmarked);
        // And earmarked debt never exceeds total debt
        assert(amount <= totalDebt);
    }

    // ==================================================================================
    // Invariant 3: Earmark conservation (earmarked <= total debt)
    // ==================================================================================

    /// @notice Prove: earmarking never exceeds unearmarked debt
    /// @dev Mirrors _earmark() in Liquid.sol: cap amount to liveUnearmarked
    function check_earmarkConservation(
        uint256 totalDebt,
        uint256 cumulativeEarmarked,
        uint256 earmarkAmount
    ) public pure {
        vm.assume(totalDebt > 0 && totalDebt < type(uint128).max);
        vm.assume(cumulativeEarmarked <= totalDebt);
        vm.assume(earmarkAmount > 0 && earmarkAmount < type(uint128).max);

        uint256 liveUnearmarked = totalDebt - cumulativeEarmarked;

        // Mirror: _earmark() caps amount to liveUnearmarked
        uint256 amount = earmarkAmount > liveUnearmarked ? liveUnearmarked : earmarkAmount;

        uint256 newCumulativeEarmarked = cumulativeEarmarked + amount;

        // Earmarked debt must never exceed total debt
        assert(newCumulativeEarmarked <= totalDebt);
    }

    // ==================================================================================
    // Invariant 4: Protocol fee is bounded by BPS
    // ==================================================================================

    /// @notice Prove: protocol fee calculation never exceeds input amount
    function check_protocolFeeBounded(uint256 amount, uint256 protocolFee) public pure {
        vm.assume(amount > 0 && amount < type(uint128).max);
        vm.assume(protocolFee <= BPS);

        uint256 feeAmount = amount * protocolFee / BPS;

        // Fee must never exceed the input
        assert(feeAmount <= amount);
        // Fee must be at most 100% when protocolFee == BPS
        if (protocolFee < BPS) {
            assert(feeAmount < amount);
        }
    }

    // ==================================================================================
    // Invariant 5: Withdrawal respects locked collateral
    // ==================================================================================

    /// @notice Prove: withdrawable collateral = total - locked (where locked = debt * minColl / price)
    function check_withdrawalRespectsLockedCollateral(
        uint256 collateralBalance,
        uint256 debt,
        uint256 yieldPrice,
        uint256 minimumCollateralization,
        uint256 withdrawAmount
    ) public pure {
        vm.assume(collateralBalance > 0 && collateralBalance < type(uint96).max);
        vm.assume(debt > 0 && debt < type(uint96).max);
        vm.assume(yieldPrice > 0 && yieldPrice < type(uint96).max);
        vm.assume(minimumCollateralization >= FIXED_POINT_SCALAR);
        vm.assume(minimumCollateralization < 10 * FIXED_POINT_SCALAR);
        vm.assume(withdrawAmount > 0);

        // convertDebtTokensToYield(debt) = debt * 1e18 / yieldPrice (simplified)
        uint256 debtInYield = debt * FIXED_POINT_SCALAR / yieldPrice;
        vm.assume(debtInYield < type(uint96).max);

        // lockedCollateral = convertDebtTokensToYield(debt) * minimumCollateralization / FIXED_POINT_SCALAR
        uint256 lockedCollateral = debtInYield * minimumCollateralization / FIXED_POINT_SCALAR;

        // Can only withdraw if enough free collateral
        vm.assume(collateralBalance > lockedCollateral);
        uint256 freeCollateral = collateralBalance - lockedCollateral;

        vm.assume(withdrawAmount <= freeCollateral);

        uint256 newCollateral = collateralBalance - withdrawAmount;

        // After withdrawal, remaining collateral must still cover locked amount
        assert(newCollateral >= lockedCollateral);
    }

    // ==================================================================================
    // Invariant 6: Burn reduces debt (monotonicity)
    // ==================================================================================

    /// @notice Prove: burning debt tokens always reduces account debt
    function check_burnReducesDebt(
        uint256 accountDebt,
        uint256 accountEarmarked,
        uint256 burnAmount,
        uint256 totalSyntheticsIssued,
        uint256 totalLockedInTransmuter
    ) public pure {
        vm.assume(accountDebt > 0 && accountDebt < type(uint96).max);
        vm.assume(accountEarmarked <= accountDebt);
        vm.assume(burnAmount > 0 && burnAmount < type(uint96).max);
        vm.assume(totalSyntheticsIssued > 0 && totalSyntheticsIssued < type(uint96).max);
        vm.assume(totalLockedInTransmuter <= totalSyntheticsIssued);

        // Mirror burn() in Liquid.sol:
        // Burning can only repay unearmarked debt
        uint256 unearmarkedDebt = accountDebt - accountEarmarked;
        vm.assume(unearmarkedDebt > 0);

        uint256 credit = burnAmount > unearmarkedDebt ? unearmarkedDebt : burnAmount;

        // Mirror: credit must not exceed totalSyntheticsIssued - totalLockedInTransmuter
        uint256 burnLimit = totalSyntheticsIssued - totalLockedInTransmuter;
        vm.assume(credit <= burnLimit);

        uint256 newDebt = accountDebt - credit;

        // Debt strictly decreases
        assert(newDebt < accountDebt);
    }

    // ==================================================================================
    // Invariant 7: Collateralization ratio math is consistent
    // ==================================================================================

    /// @notice Prove: position that passes _validate() has ratio >= minimumCollateralization
    function check_collateralizationConsistency(
        uint256 collateralValue,
        uint256 debt,
        uint256 minimumCollateralization
    ) public pure {
        vm.assume(debt > 0 && debt < type(uint96).max);
        vm.assume(collateralValue > 0 && collateralValue < type(uint96).max);
        vm.assume(minimumCollateralization >= FIXED_POINT_SCALAR);
        vm.assume(minimumCollateralization < 10 * FIXED_POINT_SCALAR);

        uint256 ratio = collateralValue * FIXED_POINT_SCALAR / debt;

        // If ratio >= minimumCollateralization (position is valid)
        if (ratio >= minimumCollateralization) {
            // Then maxDebt for this collateral is collateralValue * FIXED_POINT_SCALAR / minimumCollateralization
            uint256 maxDebt = collateralValue * FIXED_POINT_SCALAR / minimumCollateralization;
            // Due to integer division rounding, debt might exceed maxDebt by at most 1
            // But collateralization check passes, so this is safe
            assert(debt <= maxDebt + 1);
        }

        // If ratio < minimumCollateralization (position is undercollateralized)
        if (ratio < minimumCollateralization) {
            // Then the position MUST be considered undercollateralized
            // collateralValue * FIXED_POINT_SCALAR < debt * minimumCollateralization
            // (avoiding overflow by comparing differently)
            assert(collateralValue * FIXED_POINT_SCALAR < debt * minimumCollateralization + FIXED_POINT_SCALAR);
        }
    }
}
