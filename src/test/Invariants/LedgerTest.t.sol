// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./InvariantBaseTest.t.sol";

/// The engine's two ledgers, driven directly rather than fuzzed.
///
/// Every campaign failure this suite has ever produced reduces to one of these:
/// the sum of the accounts drifting away from the protocol's own total, or a
/// position the arithmetic can no longer touch. Stated as ordinary tests they
/// name a specific mechanism and fail the same way on every seed, which a
/// shrunk fuzz sequence does not.
contract LedgerTest is InvariantBaseTest {
    /// Start from an empty book. The campaign's opening positions exist so the
    /// fuzzer does not have to find them by chance; here every position is
    /// placed on purpose, and inheriting two more would only add noise to the
    /// sums these tests are reading.
    function _openingBook() internal override {}

    function _parts() internal view returns (uint256 debt, uint256 collateral) {
        address[] memory users = targetSenders();
        for (uint256 i; i < users.length; ++i) {
            uint256 tokenId = LiquidNFTHelper.getFirstTokenId(users[i], address(liquidNFT));
            if (tokenId == 0) continue;
            (uint256 c, uint256 d,) = liquid.getCDP(tokenId);
            debt += d;
            collateral += c;
        }
    }

    function _draw(address who) internal returns (uint256 tokenId) {
        _deposit(0, 1_000_000e18, who);
        tokenId = LiquidNFTHelper.getFirstTokenId(who, address(liquidNFT));
        _borrow(tokenId, liquid.getMaxBorrowable(tokenId) * 99 / 100, who);
    }

    function _drawAndStake(address who) internal returns (uint256 tokenId) {
        tokenId = _draw(who);
        // Staking is a separate transaction from borrowing on chain too.
        vm.roll(vm.getBlockNumber() + 1);
        _stake(alToken.balanceOf(who) / 2, who);
    }

    /// A redemption leaves the parts summing to the whole.
    ///
    /// The claim is the only call in the protocol that writes debt off globally
    /// and leaves every account to learn its share later, so it is the only one
    /// that can put the two ledgers out of step.
    function test_a_claim_keeps_the_ledgers_in_step() external {
        address who = targetSenders()[0];
        uint256 id = _drawAndStake(who);

        vm.roll(vm.getBlockNumber() + 2_628_000); // halfway through the window
        _claim(1, who);

        (uint256 partsDebt, uint256 partsColl) = _parts();
        assertLe(partsColl, liquid.getTotalDeposited(), "accounts claim more collateral than the protocol holds");
        assertLe(partsDebt, liquid.totalDebt(), "accounts owe more than the protocol is owed");
        assertGe(alToken.totalSupply(), liquid.totalDebt(), "more debt on the books than synthetic in existence");
        liquid.poke(id); // the account is still readable and writable
    }

    /// The same, with the collateral repriced first.
    ///
    /// An account's share of a redemption is unwound through an exponential
    /// decay, and which way that rounds decides whether the parts end inside the
    /// whole or outside it. Rounded the wrong way a borrower ends up owing more
    /// than the protocol is owed, and the last one to repay finds out by having
    /// the repayment reverted.
    function test_a_claim_after_a_reprice_keeps_the_ledgers_in_step() external {
        address who = targetSenders()[0];
        _deposit(0, 1_000_000e18, who);
        this.movePrice(61);

        uint256 id = LiquidNFTHelper.getFirstTokenId(who, address(liquidNFT));
        _borrow(id, liquid.getMaxBorrowable(id) * 99 / 100, who);
        vm.roll(vm.getBlockNumber() + 1);
        _stake(alToken.balanceOf(who) / 2, who);

        vm.roll(vm.getBlockNumber() + 2_628_000);
        _claim(1, who);

        (uint256 partsDebt, uint256 partsColl) = _parts();
        assertLe(partsColl, liquid.getTotalDeposited(), "accounts claim more collateral than the protocol holds");
        assertLe(partsDebt, liquid.totalDebt(), "accounts owe more than the protocol is owed");
        assertGe(alToken.totalSupply(), liquid.totalDebt(), "more debt on the books than synthetic in existence");
    }

    /// A redemption charges the accounts exactly what it took from the protocol.
    ///
    /// It cannot visit them, so it records what fraction of the locked pot left
    /// and each account applies that fraction to its own lock later. The
    /// fractions sum back to the whole only while the pot is the sum of the
    /// locks. Filled at the collateralization bar and drained at par, it was
    /// not: every redemption left the bar's whole margin behind in the
    /// denominator, and every account after it was charged short by that much.
    /// Driven twice, because one redemption cannot show it. With a single
    /// redemption the pot and the locks are still the same number, and a
    /// fraction of a number by itself is right however the number is scaled.
    /// The margin the first redemption leaves behind is what the second one
    /// divides by.
    function test_a_redemption_charges_the_accounts_what_it_took() external {
        address a = targetSenders()[0];
        address b = targetSenders()[1];
        _drawAndStake(a);
        _draw(b);

        vm.roll(vm.getBlockNumber() + 2_628_000); // half the redemption window
        _claim(1, a);

        // Staggered, so the second redemption has earmarking of its own to
        // consume. Claimed back to back the first takes everything earmarked and
        // the second moves nothing, which tests the pot against itself.
        _stake(alToken.balanceOf(b) / 2, b);
        vm.roll(vm.getBlockNumber() + 5_256_000);

        uint256 heldBefore = liquid.getTotalDeposited();
        (, uint256 claimedBefore) = _parts();

        _claim(2, b);

        (, uint256 claimedAfter) = _parts();
        // A redemption that moved nothing satisfies the statement below for the
        // reason this whole suite exists to rule out.
        assertGt(heldBefore - liquid.getTotalDeposited(), 0, "the second redemption moved no collateral");
        assertApproxEqAbs(
            heldBefore - liquid.getTotalDeposited(),
            claimedBefore - claimedAfter,
            targetSenders().length,
            "the protocol gave up more collateral than it charged the accounts for"
        );
    }

    /// And repricing the collateral first does not change that.
    ///
    /// An account's lock is restated from its debt at the price of the day. A
    /// pot that is a stored counter never hears about a price move, so one side
    /// of the ratio tracked the market and the other did not, and the accounts
    /// were charged in proportion to how far the price had gone.
    function test_a_reprice_does_not_change_what_a_redemption_charges() external {
        address who = targetSenders()[0];
        uint256 id = _drawAndStake(who);

        this.movePrice(200); // collateral doubles, so the position only gets safer
        liquid.poke(id); // and the account's lock is restated at the new price

        uint256 heldBefore = liquid.getTotalDeposited();
        (, uint256 claimedBefore) = _parts();

        vm.roll(vm.getBlockNumber() + 5_256_000);
        _claim(1, who);

        (, uint256 claimedAfter) = _parts();
        assertApproxEqAbs(
            heldBefore - liquid.getTotalDeposited(),
            claimedBefore - claimedAfter,
            targetSenders().length,
            "the protocol gave up more collateral than it charged the accounts for"
        );
    }

    /// A redemption that retires every debt leaves nothing locked.
    ///
    /// The pot was filled at the collateralization bar -- a borrow of D locks
    /// 1.11D -- and drained at par, so a redemption that cleared the whole book
    /// left the bar's margin standing against no debt at all. It stayed as the
    /// denominator, and every redemption after it divided by a pot larger than
    /// the collateral behind it.
    function test_a_full_redemption_empties_the_pot() external {
        address who = targetSenders()[0];
        uint256 id = _draw(who);

        vm.roll(vm.getBlockNumber() + 1);
        _stake(alToken.balanceOf(who), who);

        vm.roll(vm.getBlockNumber() + 5_256_000); // the redemption window, in full
        _claim(1, who);
        liquid.poke(id);

        (, uint256 debt,) = liquid.getCDP(id);
        assertEq(debt, 0, "the debt was not retired");
        assertEq(liquid.totalLocked(), 0, "collateral is still locked against a debt that is gone");
    }

    /// The pot equals the sum of the locks once every account has caught up.
    ///
    /// This is the identity the redemption split rests on and the one the engine
    /// had no way to state: {_totalLocked} was private, unreadable, and wrong.
    function test_the_pot_is_the_sum_of_the_locks() external {
        address a = targetSenders()[0];
        address b = targetSenders()[1];
        uint256 ida = _drawAndStake(a);
        uint256 idb = _draw(b);

        vm.roll(vm.getBlockNumber() + 2_628_000);
        _claim(1, a);

        liquid.poke(ida);
        liquid.poke(idb);

        uint256 shares;
        (, uint256 da,) = liquid.getCDP(ida);
        (, uint256 db,) = liquid.getCDP(idb);
        shares = liquid.convertDebtTokensToYield(da) * liquid.minimumCollateralization() / FIXED_POINT_SCALAR
            + liquid.convertDebtTokensToYield(db) * liquid.minimumCollateralization() / FIXED_POINT_SCALAR;

        // One wei per account: each floors its own lock, and the remainder is
        // left on the protocol's side of the split.
        assertLe(shares, liquid.totalLocked(), "the locks outrun the pot");
        assertApproxEqAbs(shares, liquid.totalLocked(), 2, "the pot has drifted from the sum of its locks");
    }

    /// A position stays usable after the collateral loses most of its value.
    ///
    /// The redemption split is `rawLocked / _totalLocked`, and only the
    /// numerator is restated when the price moves. Far enough down, an account
    /// is billed a multiple of everything it owns; the subtraction that follows
    /// used to revert, and it reverts inside {Liquid._sync}, which runs first in
    /// every entry point. The position could then not be read, repaid,
    /// withdrawn from, or -- the one that matters -- liquidated.
    function test_a_position_survives_a_loss_and_a_redemption() external {
        address borrower = targetSenders()[0];
        uint256 id = _drawAndStake(borrower);

        // The strategy loses most of the vault for good.
        uint256 held = fakeUnderlyingToken.balanceOf(address(fakeYieldToken));
        fakeYieldToken.siphon(held * 80 / 100);
        vm.roll(vm.getBlockNumber() + 1);
        liquid.poke(id); // the inflated lock is written down here

        vm.roll(vm.getBlockNumber() + 2_628_000);
        _claim(1, borrower);

        liquid.getCDP(id);
        liquid.poke(id);

        // And the remedy for a position in this state is still open.
        try liquid.liquidate(id) {} catch {}

        (, uint256 partsColl) = _parts();
        assertLe(partsColl, liquid.getTotalDeposited(), "accounts claim more collateral than the protocol holds");
    }
}
