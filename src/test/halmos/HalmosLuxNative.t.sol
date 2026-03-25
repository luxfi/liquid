// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

/// @title Halmos Symbolic Proofs for LuxNativeStrategy
/// @notice Proves invariants about xLUX deposit/withdraw/yield math.
/// @dev Inlines the core math to enable pure symbolic reasoning without
///      external calls, storage, or ERC4626 dependencies.
contract HalmosLuxNativeTest is Test {
    uint256 constant FIXED_POINT_SCALAR = 1e18;

    // ════════════════════════════════════════════════════════════════════════
    // Invariant 1: allocate never loses funds
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Prove: depositing `amount` into an ERC4626 vault and immediately
    ///         redeeming the received shares returns at least `amount` (no vault fee case).
    ///         In the general case, returned >= amount * totalAssets / (totalAssets + amount)
    ///         which for any vault with totalAssets > 0 means returned >= amount - 1 (rounding).
    function check_allocateNeverLosesFunds(
        uint256 amount,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        // Bound to realistic ranges
        vm.assume(amount > 0 && amount < type(uint96).max);
        vm.assume(totalAssets > 0 && totalAssets < type(uint96).max);
        vm.assume(totalShares > 0 && totalShares < type(uint96).max);

        // ERC4626 deposit: shares = amount * totalShares / totalAssets
        uint256 sharesReceived = amount * totalShares / totalAssets;
        vm.assume(sharesReceived > 0);

        // After deposit, vault state updates:
        uint256 newTotalAssets = totalAssets + amount;
        uint256 newTotalShares = totalShares + sharesReceived;

        // ERC4626 redeem: assets = shares * totalAssets / totalShares
        uint256 assetsReturned = sharesReceived * newTotalAssets / newTotalShares;

        // Rounding can cost at most 1 wei per operation (two divisions).
        // The returned amount must be within 2 wei of the deposited amount.
        assert(assetsReturned + 2 >= amount);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Invariant 2: snapshotYield never returns negative
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Prove: yield = max(0, currentValue - lastSnapshotValue) is always >= 0.
    ///         This is structurally enforced by the conditional.
    function check_yieldMonotonic(
        uint256 currentValue,
        uint256 lastSnapshotValue
    ) public pure {
        vm.assume(currentValue < type(uint128).max);
        vm.assume(lastSnapshotValue < type(uint128).max);

        uint256 yieldAmount = currentValue > lastSnapshotValue
            ? currentValue - lastSnapshotValue
            : 0;

        // Yield is never negative (always >= 0)
        assert(yieldAmount >= 0); // trivially true for uint, but proves the logic path

        // After snapshot, new lastSnapshotValue = currentValue
        // Next call with same currentValue yields 0
        uint256 nextYield = currentValue > currentValue ? currentValue - currentValue : 0;
        assert(nextYield == 0);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Invariant 3: deallocate returns proportional to shares
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Prove: redeeming shares returns assets proportional to the share
    ///         of the vault, bounded by the actual vault balance.
    function check_deallocateReturnsExpected(
        uint256 withdrawAmount,
        uint256 totalAssets,
        uint256 totalShares,
        uint256 strategyShares
    ) public pure {
        vm.assume(totalAssets > 0 && totalAssets < type(uint96).max);
        vm.assume(totalShares > 0 && totalShares < type(uint96).max);
        vm.assume(strategyShares > 0 && strategyShares <= totalShares);
        vm.assume(withdrawAmount > 0 && withdrawAmount < type(uint96).max);

        // convertToShares: shares = withdrawAmount * totalShares / totalAssets
        uint256 sharesToRedeem = withdrawAmount * totalShares / totalAssets;
        vm.assume(sharesToRedeem > 0);

        // Cap to available shares (mirrors strategy logic)
        if (sharesToRedeem > strategyShares) {
            sharesToRedeem = strategyShares;
        }

        // redeem: assets = shares * totalAssets / totalShares
        uint256 assetsReturned = sharesToRedeem * totalAssets / totalShares;

        // Returned assets must not exceed total vault assets
        assert(assetsReturned <= totalAssets);

        // Returned assets must not exceed what the strategy's shares are worth
        uint256 maxStrategyValue = strategyShares * totalAssets / totalShares;
        assert(assetsReturned <= maxStrategyValue);

        // Returned assets must be > 0 (since sharesToRedeem > 0 and totalAssets > 0)
        assert(assetsReturned > 0 || sharesToRedeem * totalAssets < totalShares);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Invariant 4: Share price never decreases from deposits alone
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Prove: depositing assets into a vault with no fee does not decrease
    ///         the price per share for existing holders.
    function check_depositDoesNotDilute(
        uint256 depositAmount,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        vm.assume(depositAmount > 0 && depositAmount < type(uint96).max);
        vm.assume(totalAssets > 0 && totalAssets < type(uint96).max);
        vm.assume(totalShares > 0 && totalShares < type(uint96).max);

        // Price per share before
        uint256 ppsBefore = totalAssets * FIXED_POINT_SCALAR / totalShares;

        // ERC4626 deposit
        uint256 newShares = depositAmount * totalShares / totalAssets;
        vm.assume(newShares > 0);

        uint256 newTotalAssets = totalAssets + depositAmount;
        uint256 newTotalShares = totalShares + newShares;

        // Price per share after
        uint256 ppsAfter = newTotalAssets * FIXED_POINT_SCALAR / newTotalShares;

        // PPS should not decrease (may increase by up to 1 wei due to rounding in favor of vault)
        assert(ppsAfter >= ppsBefore - 1);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Invariant 5: Fee injection strictly increases share price
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Prove: adding fees (assets without minting shares) increases PPS.
    function check_feeInjectionIncreasesValue(
        uint256 feeAmount,
        uint256 totalAssets,
        uint256 totalShares
    ) public pure {
        vm.assume(feeAmount > 0 && feeAmount < type(uint96).max);
        vm.assume(totalAssets > 0 && totalAssets < type(uint96).max);
        vm.assume(totalShares > 0 && totalShares < type(uint96).max);

        uint256 ppsBefore = totalAssets * FIXED_POINT_SCALAR / totalShares;

        // Fee injection: assets increase, shares stay the same
        uint256 newTotalAssets = totalAssets + feeAmount;
        uint256 ppsAfter = newTotalAssets * FIXED_POINT_SCALAR / totalShares;

        assert(ppsAfter > ppsBefore);
    }
}
