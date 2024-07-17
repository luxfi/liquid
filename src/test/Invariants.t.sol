// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "../../../lib/forge-std/src/Test.sol";

import {AlEth} from "../external/AlETH.sol";
import {AlchemistV3} from "../AlchemistV3.sol";
import {AlchemistHandler} from "./handlers/AlchemistHandler.sol";
import {Transmuter, InitializationParams} from "../Transmuter.sol";
import {TransmuterHandler} from "./handlers/Transmuterhandler.sol";

contract InvariantTests is Test {
    AlEth public alETH;
    AlchemistV3 public alchemist;
    AlchemistHandler public alchemistHandler;
    Transmuter public transmuter;
    TransmuterHandler public transmuterHandler;

	function setUp() public {
        // TODO: Multi alchemist set up
        alETH = new AlEth();
        alchemist = new AlchemistV3();
        alchemistHandler = new AlchemistHandler(alchemist);
        transmuter = new Transmuter(InitializationParams(address(alETH), 365 days));
        transmuterHandler = new TransmuterHandler(transmuter);

        // TODO: Deal tokens to this contract which will be used by the handlers to create positions
        // Give max_int allowance for AlEth and other colateral assets to the handlers so they can create and manage positions

        targetContract(address(transmuterHandler));
        targetContract(address(alchemist));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = TransmuterHandler.claimRedemption.selector;
        selectors[1] = TransmuterHandler.createRedemption.selector;

        targetSelector(
            FuzzSelector({addr: address(transmuterHandler), selectors: selectors})
        );

        selectors = new bytes4[](5);
        selectors[0] = TransmuterHandler.claimRedemption.selector;
        selectors[1] = TransmuterHandler.claimRedemption.selector;
        selectors[2] = TransmuterHandler.claimRedemption.selector;
        selectors[3] = TransmuterHandler.claimRedemption.selector;
        selectors[4] = TransmuterHandler.claimRedemption.selector;
        
        targetSelector(
            FuzzSelector({addr: address(alchemist), selectors: selectors})
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

    // The total number of shares must be equal to the sum of all shares in user CDPs
    function invariant_consistent_shares() public {

    }

    // Every alchemist CDP must be updated properly when poke is called
    // Poke will cause the users debts to update based on redemption rate
    function invariant_poke_user_cdp () public {

    }

}
