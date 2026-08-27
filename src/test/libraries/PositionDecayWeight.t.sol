// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PositionDecay} from "../../libraries/PositionDecay.sol";

/// The one property the two halves of this library have to satisfy together.
///
/// {WeightIncrement} records "a fraction f of the pool was taken" as a weight,
/// and {ScaleByWeightDelta} applies that weight to one account's share. Compose
/// them and the account must give up its own f: that is the whole mechanism by
/// which a redemption is charged to the accounts it was taken from, and any gap
/// is collateral that left the protocol charged to nobody.
///
/// Checked against plain integer arithmetic rather than against a second copy
/// of the logarithm, because the defect this covers was inside the logarithm.
contract PositionDecayWeightTest is Test {
    uint256 constant POOL = 1_000_000e18;
    uint256 constant SHARE = 250_000e18;

    function _removed(uint256 increment) internal pure returns (uint256) {
        return PositionDecay.ScaleByWeightDelta(SHARE, PositionDecay.WeightIncrement(increment, POOL));
    }

    /// Taking a given fraction of the pool takes that fraction of every share.
    ///
    /// The percentages either side of 75 are the point: the top set bit of the
    /// ratio moves below 126 there, and the bit scan that was supposed to find
    /// it counted its steps whether or not it took them, so it answered 126 or
    /// 127 for every input. Above three quarters the answer was simply wrong,
    /// and wrong in the direction that under-charges.
    function test_a_share_gives_up_the_fraction_the_pool_lost() external pure {
        uint8[12] memory pct = [1, 5, 10, 25, 50, 60, 70, 75, 80, 90, 95, 99];

        for (uint256 i; i < pct.length; ++i) {
            uint256 increment = POOL * pct[i] / 100;
            uint256 expected = SHARE * pct[i] / 100;
            assertApproxEqRel(_removed(increment), expected, 0.0001e18, "the share did not give up the pool's fraction");
        }
    }

    /// The same statement over the whole range, at the resolution a fuzzer picks.
    function testFuzz_a_share_gives_up_the_fraction_the_pool_lost(uint256 increment) external pure {
        increment = bound(increment, POOL / 1000, POOL - 1);
        assertApproxEqRel(_removed(increment), SHARE * increment / POOL, 0.0001e18, "the share did not give up the pool's fraction");
    }

    /// Nothing taken, nothing charged. Everything taken, everything charged.
    function test_the_ends_of_the_range() external pure {
        assertEq(_removed(0), 0, "a share was charged for a redemption that took nothing");
        assertEq(PositionDecay.ScaleByWeightDelta(SHARE, PositionDecay.WeightIncrement(POOL, POOL)), SHARE, "a total redemption left a share standing");
    }
}
