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

    // TODO create and claim redemptions using tokens from main test and make sure to send returns to there as well
    // Bound these values to random number between 0 and balance of msg.sender

    function createRedemption(address alchemist , address collateral, uint256 depositAmount) public {}

    function claimRedemption(uint256 id) public {}
}