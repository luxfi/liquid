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

        selectors.push(this.mine.selector);

        super.setUp();
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

        assertEq(totalDeposited, liquid.getTotalDeposited());
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

        assertEq(totalDeposited, liquid.convertYieldTokensToDebt(liquid.getTotalDeposited()));
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

        assertEq(totalDebt, liquid.totalDebt());
    }

    // Supply of debt tokens must be greater or equal to debt in the system
    function invariantDebtTokenSupply() public view {
        assertGe(alToken.totalSupply(), liquid.totalDebt());
    }

    // Amount stakes in the transmuter cannot exceed the total debt in the liquid plus the debt value of yield tokens in the transmuter
    function invariantTransmuterStakeLessThanTotalDebt() public view {
        uint256 totalLocked = transmuterLogic.totalLocked() > liquid.convertYieldTokensToDebt(fakeYieldToken.balanceOf(address(transmuterLogic)))
            ? transmuterLogic.totalLocked() - liquid.convertYieldTokensToDebt(fakeYieldToken.balanceOf(address(transmuterLogic)))
            : 0;
        assertLe(totalLocked, liquid.totalDebt());
    }

    // Earmarked can never be more than total debt
}
