// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../InvariantsTest.t.sol";

contract InvariantBaseTest is InvariantsTest {
    address internal immutable USER;

    uint256 internal immutable MAX_TEST_VALUE = 1e28;

    constructor() {
        USER = makeAddr("User");
    }

    function setUp() public virtual override {
        selectors.push(this.depositCollateral.selector);
        selectors.push(this.withdrawCollateral.selector);
        selectors.push(this.borrowCollateral.selector);
        selectors.push(this.repayDebt.selector);
        selectors.push(this.repayDebtViaBurn.selector);
        selectors.push(this.transmuterStake.selector);
        selectors.push(this.transmuterClaim.selector);
        selectors.push(this.mine.selector);

        super.setUp();
    }

    function _targetSenders() internal virtual override {
        _targetSender(makeAddr("Sender1"));
        _targetSender(makeAddr("Sender2"));
        _targetSender(makeAddr("Sender3"));
        _targetSender(makeAddr("Sender4"));
        _targetSender(makeAddr("Sender5"));
        _targetSender(makeAddr("Sender6"));
        _targetSender(makeAddr("Sender7"));
        _targetSender(makeAddr("Sender8"));
    }

    function _deposit(uint256 tokenId, uint256 amount, address onBehalf) internal logCall("deposit") {
        fakeUnderlyingToken.mint(onBehalf, amount);
        vm.startPrank(onBehalf);
        fakeUnderlyingToken.approve(address(fakeYieldToken), amount);
        // Deposit the shares the vault actually issued. They equal the underlying
        // amount only at par, and the point of these runs is that the price moves.
        uint256 shares = fakeYieldToken.mint(amount, onBehalf);
        uint256 cap = liquid.depositCap();
        uint256 held = liquid.getTotalDeposited();
        uint256 room = cap > held ? cap - held : 0;
        if (shares > room) shares = room;
        if (shares > 0) liquid.deposit(shares, onBehalf, tokenId);
        vm.stopPrank();
    }

    function _borrow(uint256 tokenId, uint256 amount, address onBehalf) internal logCall("borrow") {
        vm.prank(onBehalf);
        liquid.mint(tokenId, amount, onBehalf);
    }

    function _withdraw(uint256 tokenId, uint256 amount, address onBehalf) internal logCall("withdraw") {
        vm.prank(onBehalf);
        liquid.withdraw(amount, onBehalf, tokenId);
    }

    function _repay(uint256 tokenId, uint256 amount, address onBehalf) internal logCall("repay") {
        fakeUnderlyingToken.mint(onBehalf, amount);
        vm.startPrank(onBehalf);
        fakeUnderlyingToken.approve(address(fakeYieldToken), amount);
        uint256 shares = fakeYieldToken.mint(amount, onBehalf);
        if (shares > 0) liquid.repay(shares, tokenId);
        vm.stopPrank();
    }

    function _burn(uint256 tokenId, uint256 amount, address onBehalf) internal logCall("burn") {
        vm.prank(onBehalf);
        liquid.burn(amount, tokenId);
    }

    function _stake(uint256 amount, address onBehalf) internal logCall("stake") {
        // Stake synthetic the account actually borrowed. Minting it here instead
        // would let locked stake grow without any debt behind it, and the
        // transmuter's whole claim on the protocol is that debt.
        vm.startPrank(onBehalf);
        alToken.approve(address(transmuterLogic), amount);
        transmuterLogic.createRedemption(amount);
        vm.stopPrank();
    }

    function _claim(uint256 id, address onBehalf) internal logCall("claim") {
        vm.prank(onBehalf);
        transmuterLogic.claimRedemption(id);
    }

    /* HANDLERS */

    function depositCollateral(uint256 amount, uint256 onBehalfSeed) external {
        if (liquid.inBadDebt()) return;
        address onBehalf = _randomDepositor(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        amount = bound(amount, 0, MAX_TEST_VALUE);
        if (amount == 0) return;

        uint256 tokenId;

        try LiquidNFTHelper.getFirstTokenId(onBehalf, address(liquidNFT)) {
            tokenId = LiquidNFTHelper.getFirstTokenId(onBehalf, address(liquidNFT));
        } catch {
            tokenId = 0;
        }

        _deposit(tokenId, amount, onBehalf);
    }

    function withdrawCollateral(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomWithdrawer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(onBehalf, address(liquidNFT));
        if (tokenId == 0) return;

        liquid.poke(tokenId);
        (uint256 collat, uint256 debt,) = liquid.getCDP(tokenId);
        // Mirror the engine's own ceiling exactly: it converts the debt to yield
        // first and scales by the bar second. Scaling first and converting after
        // is a different number under integer division, and the difference is
        // what the engine rejects.
        uint256 keep = liquid.convertDebtTokensToYield(debt) * liquid.minimumCollateralization() / FIXED_POINT_SCALAR;
        uint256 maxWithdraw = collat > keep ? collat - keep : 0;
        // Stay just inside the bar rather than exactly on it. Reconstructing the
        // engine's rounding to the last wei only tests the reconstruction; the
        // withdrawals themselves are what the invariants care about.
        maxWithdraw = maxWithdraw * 99 / 100;

        amount = bound(amount, 0, maxWithdraw);
        if (amount == 0) return;

        // The engine admits a withdrawal on one formula and then validates the
        // result on another, converting in opposite directions; at dust amounts
        // the two disagree by a wei. Check the post-condition the engine
        // actually enforces, on the state the withdrawal would leave behind.
        if (debt > 0) {
            uint256 remaining = liquid.convertYieldTokensToDebt(collat - amount) * FIXED_POINT_SCALAR / debt;
            if (remaining < liquid.minimumCollateralization()) return;
        }

        _withdraw(tokenId, amount, onBehalf);
    }

    function borrowCollateral(uint256 amount, uint256 onBehalfSeed) external {
        if (liquid.inBadDebt()) return;
        address onBehalf = _randomMinter(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(onBehalf, address(liquidNFT));
        if (tokenId == 0) return;

        liquid.poke(tokenId);
        // The borrow ceiling and the collateralization check round in different
        // places, so drawing to the last wei of the ceiling can land a wei the
        // wrong side of the bar. Stay just inside it -- a position at 89% of the
        // limit is still fully levered for anything these runs are testing.
        uint256 ceiling = liquid.getMaxBorrowable(tokenId) * 99 / 100;
        // Keep the book in the same range the deposits are drawn from. Left
        // unbounded, borrowing against a book compounded over a campaign runs
        // the debt into magnitudes no market reaches and the arithmetic stops
        // describing anything real.
        if (ceiling > MAX_TEST_VALUE) ceiling = MAX_TEST_VALUE;
        amount = bound(amount, 0, ceiling);
        if (amount == 0) return;

        _borrow(tokenId, amount, onBehalf);
    }

    function repayDebt(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomRepayer(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(onBehalf, address(liquidNFT));
        if (tokenId == 0) return;

        // Debt cannot be retired in the block it was drawn -- the flash-loan
        // guard. A borrower waits a block; so does the handler. Waiting accrues
        // earmarking, so sync before reading what is left to repay.
        vm.roll(vm.getBlockNumber() + 1);
        liquid.poke(tokenId);

        (, uint256 debt,) = liquid.getCDP(tokenId);
        if (debt == 0) return;

        amount = bound(amount, 0, MAX_TEST_VALUE);
        if (amount == 0) return;

        _repay(tokenId, amount, onBehalf);
    }

    function repayDebtViaBurn(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomBurner(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 tokenId = LiquidNFTHelper.getFirstTokenId(onBehalf, address(liquidNFT));
        if (tokenId == 0) return;

        vm.roll(vm.getBlockNumber() + 1);
        liquid.poke(tokenId);

        (, uint256 debt, uint256 earmarked) = liquid.getCDP(tokenId);
        if (debt <= earmarked) return; // only unearmarked debt can be burned

        uint256 ceiling = debt - earmarked;

        // Enough synthetic must remain outstanding to settle the transmuter.
        uint256 locked = transmuterLogic.totalLocked();
        uint256 issued = liquid.totalSyntheticsIssued();
        uint256 burnable = issued > locked ? issued - locked : 0;
        if (burnable < ceiling) ceiling = burnable;

        // And the caller can only burn what it holds.
        uint256 held = alToken.balanceOf(onBehalf);
        if (held < ceiling) ceiling = held;

        amount = bound(amount, 0, ceiling);
        if (amount == 0) return;

        _burn(tokenId, amount, onBehalf);
    }

    function transmuterStake(uint256 amount, uint256 onBehalfSeed) external {
        address onBehalf = _randomDepositor(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        // A redemption can only be staked against synthetic that is issued and
        // not already locked in another position. Bounding by total debt is a
        // different quantity and overshoots it.
        uint256 locked = transmuterLogic.totalLocked();
        uint256 issued = liquid.totalSyntheticsIssued();
        uint256 room = issued > locked ? issued - locked : 0;

        uint256 debtRoom = liquid.totalDebt() > locked ? liquid.totalDebt() - locked : 0;
        if (debtRoom < room) room = debtRoom;
        if (room > MAX_TEST_VALUE) room = MAX_TEST_VALUE; // graph delta packing

        uint256 balance = alToken.balanceOf(onBehalf);
        if (balance < room) room = balance;

        amount = bound(amount, 0, room);
        if (amount == 0) return;

        _stake(amount, onBehalf);
    }

    /// Take a staked redemption back out.
    ///
    /// This is the transmuter's exit and the most involved function in the
    /// protocol: it prices the claim against the protocol's backing, applies the
    /// bad-debt haircut, pulls what it needs from the engine, splits fees and
    /// burns the rest. With the handler empty none of it ran, `totalLocked` only
    /// ever rose, and every statement about locked stake was trivially true for
    /// the whole of every campaign.
    function transmuterClaim(uint256 seed, uint256 onBehalfSeed) external {
        address onBehalf = _randomDepositor(targetSenders(), onBehalfSeed);
        if (onBehalf == address(0)) return;

        uint256 id = _heldRedemption(onBehalf);
        if (id == 0) return;

        // A position cannot be claimed in the block it was opened. Beyond that,
        // let the claim land anywhere in its window: an unmatured claim returns
        // most of the stake and a matured one returns none of it, and those are
        // different arithmetic.
        vm.roll(vm.getBlockNumber() + 1 + seed % 5_256_000);

        claims++;
        _claim(id, onBehalf);
    }

    /// The first redemption position `owner` still holds, or zero.
    ///
    /// The transmuter's positions are a plain ERC721 with no enumeration and
    /// claiming burns the token, so the ids in play are sparse and are found by
    /// looking. A campaign opens few enough of them that looking costs less than
    /// making the contract enumerable for the benefit of a test.
    function _heldRedemption(address owner) internal view returns (uint256) {
        for (uint256 id = 1; id <= 64; ++id) {
            try transmuterLogic.ownerOf(id) returns (address who) {
                if (who == owner) return id;
            } catch {}
        }
        return 0;
    }

    /* RISK HANDLERS */

    // What the risk handlers actually achieved. A handler that always reverts
    // and a handler that works look identical from the outside once the revert
    // is caught, so the run counts its own effect and
    // {test_handlers_can_drive_a_liquidation} holds it to it. Without that the
    // suite can pass while proving nothing -- which is how it passed over three
    // criticals.
    uint256 public liquidations;
    uint256 public priceMoves;
    uint256 public claims;

    // Everything above moves value between accounts at a fixed price. Nothing
    // above can make a position unhealthy, so nothing above ever reaches the
    // liquidation path -- which is why a suite of eight handlers held over a
    // protocol whose risk engine did not work. These four let collateral fall
    // and let someone act on it.

    /// Reprice the collateral. The adapter reports a new share value; the engine
    /// admits as much of it as the deviation cap allows. Both directions, because
    /// a rising price must not break the accounting either.
    function movePrice(uint256 pct) external logCall("movePrice") {
        // Down to a tenth, up to double. A halving alone cannot put a position
        // drawn to the 90% bar under the liquidation bound, so a range that
        // stops at 0.5x is a range in which nothing is ever liquidatable.
        pct = bound(pct, 10, 200);
        uint256 supply = fakeYieldToken.mockTokenSupply();
        if (supply == 0) return;

        // Price is underlying-per-share, so supply moves inversely to price.
        uint256 newSupply = supply * 100 / pct;
        if (newSupply == 0) return;

        fakeYieldToken.updateMockTokenSupply(newSupply);
        priceMoves++;
        // A price move is an inter-block event, here as on chain.
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// A real loss in the strategy behind the yield token: underlying leaves the
    /// vault and never comes back. Unlike movePrice this destroys value rather
    /// than restating it, so it can push the whole protocol into bad debt.
    function strategyLoss(uint256 pct) external logCall("strategyLoss") {
        pct = bound(pct, 1, 30); // lose 1% to 30% of the vault's underlying
        uint256 held = fakeUnderlyingToken.balanceOf(address(fakeYieldToken));
        uint256 loss = held * pct / 100;
        if (loss == 0) return;

        fakeYieldToken.siphon(loss);
        priceMoves++;
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// Liquidate one position. A healthy position reverts, which is the correct
    /// answer and not a finding, so the revert is caught rather than bounded
    /// away -- bounding it away is how a handler ends up never exercising the
    /// path it exists for.
    function liquidatePosition(uint256) external logCall("liquidate") {
        uint256 tokenId = _weakestPosition();
        if (tokenId == 0) return;

        try liquid.liquidate(tokenId) returns (uint256 seized, uint256, uint256) {
            if (seized > 0) liquidations++;
        } catch {}
    }

    /// The position closest to insolvency, or 0 if none is under the bound.
    ///
    /// Picking a victim at random is what made this handler ornamental: with
    /// eight senders and most positions healthy, every call landed on a solvent
    /// position and {LiquidationError} was the honest answer each time. A
    /// liquidator does not pick at random -- it watches for the position that
    /// has fallen through the bound and takes that one.
    function _weakestPosition() internal view returns (uint256 worst) {
        address[] memory users = targetSenders();
        uint256 lowest = type(uint256).max;

        for (uint256 i; i < users.length; ++i) {
            uint256 tokenId = LiquidNFTHelper.getFirstTokenId(users[i], address(liquidNFT));
            if (tokenId == 0) continue;

            (, uint256 debt,) = liquid.getCDP(tokenId);
            if (debt == 0) continue;

            uint256 ratio = liquid.totalValue(tokenId) * FIXED_POINT_SCALAR / debt;
            if (ratio < liquid.collateralizationLowerBound() && ratio < lowest) {
                lowest = ratio;
                worst = tokenId;
            }
        }
    }

    /// Liquidate every position at once. Exercises the batch path's own
    /// accounting, which does not share a code path with the single one.
    function batchLiquidatePositions(uint256 seed) external logCall("batchLiquidate") {
        address[] memory users = targetSenders();
        if (users.length == 0) return;

        uint256 offset = seed % users.length;
        uint256[] memory ids = new uint256[](users.length);
        uint256 n;
        for (uint256 i; i < users.length; ++i) {
            uint256 tokenId = LiquidNFTHelper.getFirstTokenId(users[(i + offset) % users.length], address(liquidNFT));
            if (tokenId != 0) ids[n++] = tokenId;
        }
        if (n == 0) return;

        assembly {
            mstore(ids, n)
        }

        try liquid.batchLiquidate(ids) returns (uint256 seized, uint256, uint256) {
            if (seized > 0) liquidations++;
        } catch {}
    }
}
