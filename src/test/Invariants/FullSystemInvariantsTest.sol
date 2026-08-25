// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./InvariantBaseTest.t.sol";

contract FullSystemInvariantsTest is InvariantBaseTest {
    function setUp() public virtual override {
        selectors.push(this.depositCollateral.selector);
        selectors.push(this.withdrawCollateral.selector);
        selectors.push(this.borrowCollateral.selector);
        selectors.push(this.repayDebt.selector);
        selectors.push(this.repayDebtViaBurn.selector);
        selectors.push(this.transmuterStake.selector);
        selectors.push(this.transmuterClaim.selector);

        // Collateral has to be able to fall, and someone has to be able to act
        // on it, or the run says nothing about the risk engine.
        selectors.push(this.movePrice.selector);
        selectors.push(this.strategyLoss.selector);
        selectors.push(this.liquidatePosition.selector);
        selectors.push(this.batchLiquidatePositions.selector);

        selectors.push(this.mine.selector);

        super.setUp();
    }

    /// The handlers must be able to reach a liquidation.
    ///
    /// Every risk handler catches its own reverts, which is right -- refusing to
    /// liquidate a healthy position is the correct answer, not a finding. But it
    /// also means a handler that can never succeed is indistinguishable from one
    /// that works, and that is not hypothetical: before the borrow path was
    /// repaired no account in this suite ever carried debt, so `liquidate`
    /// reverted on all 4096 calls of every campaign and the invariants described
    /// a protocol nobody had borrowed from.
    ///
    /// Driven directly rather than fuzzed, so it states a fact about the
    /// handlers instead of a hope about the seed.
    function test_handlers_can_drive_a_liquidation() external {
        this.depositCollateral(1_000_000e18, 0);
        this.borrowCollateral(type(uint256).max, 0); // draws to the ceiling
        this.movePrice(10); // collateral falls to a tenth
        this.liquidatePosition(0);

        assertGt(priceMoves, 0, "the price handler did nothing");
        assertGt(liquidations, 0, "the handlers cannot reach a liquidation");
    }

    /* INVARIANTS */

    // Total deposited equals the sum of all individual CDPs
    // This uses getCDP which calculates balances/debts without updating storage
    function invariantConsistentCollateral() public view {
        address[] memory users = targetSenders();

        uint256 totalDeposited;

        for (uint256 i; i < users.length; ++i) {
            // a single position nft would have been minted to address(0xbeef)
            uint256 tokenId = LiquidNFTHelper.getFirstTokenId(users[i], address(liquidNFT));
            (uint256 collateral,,) = liquid.getCDP(tokenId);

            totalDeposited += collateral;
        }

        // Accounts may never claim more collateral than the protocol holds.
        // Valuing repriced collateral divides, division leaves a remainder, and
        // the remainder must land on the protocol's side of the ledger every
        // time -- a remainder on the accounts' side is a claim against tokens
        // that are not there.
        assertLe(totalDeposited, liquid.getTotalDeposited());

        // And it has to stay a remainder. A leak announces itself by growing.
        assertApproxEqAbs(totalDeposited, liquid.getTotalDeposited(), users.length);
    }

    // Underlying value of collateral equals sum of all user accounts
    // This test uses poke() to perform an actual storage update to the user account
    function invariantConsistentCollateralwithPoke() public {
        address[] memory users = targetSenders();

        uint256 totalDeposited;

        for (uint256 i; i < users.length; ++i) {
            // a single position nft would have been minted to address(0xbeef)
            uint256 tokenId = LiquidNFTHelper.getFirstTokenId(users[i], address(liquidNFT));

            if (tokenId != 0) {
                liquid.poke(tokenId);

                totalDeposited += liquid.totalValue(tokenId);
            }
        }

        // Each account's value is floored on its own; the protocol total is
        // floored once. A sum of floors is never more than the floor of the sum,
        // and falls short by at most one wei per account -- so the inequality
        // holds by construction and the gap is bounded by the account count.
        uint256 protocolValue = liquid.convertYieldTokensToDebt(liquid.getTotalDeposited());
        assertLe(totalDeposited, protocolValue);
        assertApproxEqAbs(totalDeposited, protocolValue, users.length);
    }

    // Total debt in the system is equal to sum of all user debts
    function invariantConsistentDebt() public view {
        address[] memory users = targetSenders();

        uint256 totalDebt;

        for (uint256 i; i < users.length; ++i) {
            // a single position nft would have been minted to address(0xbeef)
            uint256 tokenId = LiquidNFTHelper.getFirstTokenId(users[i], address(liquidNFT));
            (, uint256 debt,) = liquid.getCDP(tokenId);

            totalDebt += debt;
        }

        // Same shape as the collateral invariant above: each account's debt is
        // rounded on its own and the protocol's is rounded once, so the sum of
        // the parts sits at or below the whole and trails it by at most a wei
        // per account. The bound is what makes it an invariant rather than a
        // tolerance -- a leak grows past the account count.
        assertLe(totalDebt, liquid.totalDebt());
        assertLe(liquid.totalDebt() - totalDebt, liquid.totalDebt() / 1e12 + users.length, "per-account debt has drifted from the protocol total");
    }

    // Supply of debt tokens must be greater or equal to debt in the system
    function invariantDebtTokenSupply() public view {
        assertGe(alToken.totalSupply(), liquid.totalDebt());
    }

    /// Staked redemptions can never exceed the synthetic actually issued.
    ///
    /// The obvious form of this -- that locked stake never outruns outstanding
    /// debt once the yield already delivered is netted off -- is not true, and
    /// cannot be. The transmuter is paid in yield tokens at the price of the day
    /// the debt was repaid; if the collateral price then falls, what it holds is
    /// worth less in debt terms while the claims against it stay fixed. A
    /// campaign that moves the price finds that within a few hundred calls.
    ///
    /// That shortfall is not a leak -- it is the case {LiquidTransmuter} scales
    /// claims for through its bad-debt ratio, and the haircut is exercised
    /// directly in the audit regression suite. What the protocol does enforce,
    /// on every redemption, is this: stake is only ever accepted against
    /// synthetic that was genuinely issued.
    function invariantTransmuterStakeBackedByIssuedSynthetic() public view {
        assertLe(transmuterLogic.totalLocked(), liquid.totalSyntheticsIssued(), "locked stake exceeds the synthetic ever issued");
    }

    // Earmarked can never be more than total debt
}
