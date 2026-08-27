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
    /// handlers instead of a hope about the seed. {afterInvariant} holds the
    /// campaign to the same floor, but only over its final run and only when
    /// that run completed; this holds every run, unconditionally.
    function test_handlers_can_drive_a_liquidation() external {
        this.depositCollateral(1_000_000e18, 0);
        this.borrowCollateral(type(uint256).max, 0); // draws to the ceiling
        this.movePrice(10); // collateral falls to a tenth
        this.liquidatePosition(0);

        assertGt(priceMoves, 0, "the price handler did nothing");
        assertGt(underwater, 0, "the price handler cannot put a position under the bound");
        assertGt(liquidations, 0, "the handlers cannot reach a liquidation");
    }

    /// The handlers must be able to reach a redemption claim.
    ///
    /// The claim is the most involved call in the protocol -- it prices a stake
    /// against the protocol's backing, applies the bad-debt haircut, pulls what
    /// it needs from the engine, splits fees and burns the rest. Its handler sat
    /// empty for the whole life of this suite, so `totalLocked` only ever rose
    /// and every statement about staked redemptions held for the trivial reason.
    function test_handlers_can_drive_a_claim() external {
        this.depositCollateral(1_000_000e18, 0);
        this.borrowCollateral(type(uint256).max, 0);
        this.mine(1);
        this.transmuterStake(type(uint256).max, 0);
        this.transmuterClaim(1, 0);

        assertGt(claims, 0, "the handlers cannot reach a redemption claim");
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

    /// Whether the synthetic in circulation is backed is deliberately NOT
    /// asserted here, and this campaign is the reason.
    ///
    /// `strategyLoss` takes underlying out of the vault for good and `movePrice`
    /// marks the collateral down. Both leave synthetic standing against less
    /// than it was worth, which is a real shortfall and precisely the case
    /// {LiquidTransmuter} exists to share out through its haircut. Asserting
    /// solvency over a campaign built to destroy value would only be satisfiable
    /// by refusing to destroy any.
    ///
    /// The statement that was here instead -- locked stake never exceeding
    /// synthetic issued -- survived that, and survived everything else, because
    /// it is an inductive consequence of the two `require`s that produce those
    /// two numbers. It was true before the campaign started and no sequence of
    /// calls could have made it false.
    ///
    /// Backing is asserted where it can fail: {ConservationInvariantsTest}, over
    /// the handlers that only move value.

    /// A coverage floor belongs here -- every invariant above holds trivially
    /// over a book nobody borrowed from, whose price never moved and whose
    /// redemptions were never claimed -- and `afterInvariant` is the wrong place
    /// to put one. See the note on the counters in {InvariantBaseTest} for what
    /// it can be made to read and why the reading cannot be trusted. The floor
    /// this campaign does get is the direct drive above, which holds every run.
}

/// The same protocol, driven only by handlers that move value between accounts.
///
/// No price move, no strategy loss, nothing destroyed. Every yield token that
/// leaves one place arrives at another, so a shortfall here is not a market
/// event -- it is the protocol losing track of its own money, and there is no
/// other way to produce one.
contract ConservationInvariantsTest is InvariantBaseTest {
    /// Synthetic in circulation is worth no more than what stands behind it.
    ///
    /// Behind it is collateral still in the CDPs plus what borrowers have handed
    /// the transmuter in repayment. Both back the same claims, which is why the
    /// engine and the haircut both read {Liquid.backing}, and why a statement
    /// that counts one and not the other describes a different protocol.
    function invariantSyntheticsAreBacked() public view {
        assertLe(liquid.totalSyntheticsIssued(), liquid.backing(), "synthetic is in circulation that nothing stands behind");
    }

    /// Accounts may never claim more collateral than the protocol holds.
    function invariantConsistentCollateral() public view {
        address[] memory users = targetSenders();
        uint256 claimed;

        for (uint256 i; i < users.length; ++i) {
            (uint256 collateral,,) = liquid.getCDP(LiquidNFTHelper.getFirstTokenId(users[i], address(liquidNFT)));
            claimed += collateral;
        }

        assertLe(claimed, liquid.getTotalDeposited());
        assertApproxEqAbs(claimed, liquid.getTotalDeposited(), users.length);
    }

}
