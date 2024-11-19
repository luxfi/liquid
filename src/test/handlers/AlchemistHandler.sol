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

    // TODO: Bind amounts to each function and randomly select a yield token for deposits and withdraw

    function deposit(address yieldToken, uint256 amount) public {
        _alchemist.deposit(address(this), yieldToken, amount);
    }

    function withdraw(address yieldToken, uint256 amount) public {
        _alchemist.withdraw(yieldToken, amount);
    }

    function mint(uint256 amount) public {
        _alchemist.mint(amount);
    }

    function repay(uint256 amount) public {
        _alchemist.repay(address(this), amount);
    }

    function liquidate() public {
        _alchemist.liquidate(address(this));
    }
}