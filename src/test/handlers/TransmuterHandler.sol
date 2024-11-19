// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import "../../Transmuter.sol";

contract TransmuterHandler is CommonBase, StdCheats, StdUtils{
    Transmuter private _transmuter;

    constructor(Transmuter transmuter) {
        _transmuter = transmuter;
    }

    // TODO: Bind amounts to createRedemption and pick random alchemists and collaterals

    function createRedemption(address alchemist, address collateral, uint256 depositAmount) public {
        _transmuter.createRedemption(alchemist, collateral, depositAmount);
    }

    // TODO: Pick random user. Find way to log IDs
    function claimRedemption(uint256 id) public {
        _transmuter.claimRedemption(id);
    }
}