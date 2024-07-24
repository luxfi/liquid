// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import "../../AlchemistV3.sol";

contract AlchemistHandler is CommonBase, StdCheats, StdUtils{
    AlchemistV3 private _alchemist;

    constructor(AlchemistV3 alchemist) {
        _alchemist = alchemist;
    }

    // TODO: fill these in once alchemist is fully stripped to the final function params we will use
    function deposit() public {}

    function withdraw() public {}

    function mint() public {}

    function burn() public {}

    function repay() public {}

    function liquidate() public {}
}