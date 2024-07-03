// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "../../../lib/forge-std/src/Test.sol";

import {AlEth} from "../external/AlETH.sol";
import {Transmuter, InitializationParams} from "../Transmuter.sol";
import {TransmuterHandler} from "./handlers/Transmuterhandler.sol";

contract InvariantTests is Test {
    AlEth public alETH;
    Transmuter public transmuter;
    TransmuterHandler public transmuterHandler;

	function setUp() public {
        // TODO: Add alchemist handler and alchemist once merged
        // This will require setting up multiple alchemists to be paired with the single transmuter
        alETH = new AlEth();
        transmuter = new Transmuter(InitializationParams(address(alETH), 365 days));
        transmuterHandler = new TransmuterHandler(transmuter);

        // TODO: Deal tokens to this contract which will be used by the handlers to create positions
        // Give max_int allowance for AlEth and other colateral assets to the handlers so they can create and manage positions

        targetContract(address(transmuterHandler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = TransmuterHandler.claimRedemption.selector;
        selectors[1] = TransmuterHandler.createRedemption.selector;

        targetSelector(
            FuzzSelector({addr: address(transmuterHandler), selectors: selectors})
        );
    }

    // The system cannot take more from the user than they earn
    // Therefore the redemption fee cannot exceed yield rate for all Alchemists
    function invariant_redemption_fee() public {
    }

    // The balance of synthetics staked into the transmuter cannot exceed sum of all Alchemists TVL * LTV
    function invariant_transmuter_synthetic_balance() public {

        // assertLe(alETH.balanceOf(transmuter), alchemist.tvl * alchemix * ltv);
    }
}
