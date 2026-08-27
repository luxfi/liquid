// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../../lib/forge-std/src/Test.sol";
import {PositionDecay} from "../../libraries/PositionDecay.sol";

/// The one property the redemption split rests on.
///
/// A redemption records `WeightIncrement(out, pot)` and every account later
/// applies `ScaleByWeightDelta(share, thatWeight)` to itself. The shares add
/// back up to `out` only if the second undoes the first exactly. Everything the
/// engine does with locked collateral is downstream of that round trip, and
/// nothing in the suite ever stated it.
contract DecayTest is Test {
    function test_a_weight_scales_back_to_what_made_it() external pure {
        uint256 pot = 989_999_999_999_999_999_999_999;
        uint256 out = 891_000_000_000_000_000_089_100;

        uint256 weight = PositionDecay.WeightIncrement(out, pot);
        assertEq(PositionDecay.ScaleByWeightDelta(pot, weight), out, "the whole pot does not scale back to what left it");
    }

    /// Across the whole range, because the failure had a threshold.
    ///
    /// Up to three quarters the round trip was exact and every test anyone
    /// wrote happened to sit there. Past it the recorded weight collapsed onto
    /// one of two values -- half or three quarters -- and a redemption taking
    /// 99% of the pot charged the accounts for 50%. The other 49% stayed in the
    /// protocol, charged to nobody and owed to everybody.
    function test_a_weight_scales_back_at_every_size(uint256 pct) external pure {
        pct = bound(pct, 1, 9_999); // basis points of the pot, short of all of it
        uint256 pot = 1_000_000e18;
        uint256 out = pot * pct / 10_000;

        uint256 weight = PositionDecay.WeightIncrement(out, pot);
        assertApproxEqAbs(PositionDecay.ScaleByWeightDelta(pot, weight), out, 1, "the pot does not scale back to what left it");
    }

    /// And on the halves separately, since that is how it is actually used.
    function test_two_shares_scale_back_to_the_whole() external pure {
        uint256 pot = 1_000_000e18;
        uint256 out = 400_000e18;

        uint256 weight = PositionDecay.WeightIncrement(out, pot);
        uint256 a = PositionDecay.ScaleByWeightDelta(pot / 2, weight);
        uint256 b = PositionDecay.ScaleByWeightDelta(pot / 2, weight);

        assertApproxEqAbs(a + b, out, 2, "the shares do not add back up to what left");
    }
}
