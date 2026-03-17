// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface EETH {
    function deposit() external payable returns (uint256);
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256);
}

interface WETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract EETHLiquidStrategy is LiquidStrategy {
    EETH public immutable eeth;
    WETH public immutable weth;

    constructor(address _vault, StrategyParams memory _params, address _eeth, address _weth) LiquidStrategy(_vault, _params) {
        eeth = EETH(_eeth);
        weth = WETH(_weth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        // need to unwrap ether since this strategy only recieves weth (morpho v2 vault cannot hold native eth by default)
        weth.withdraw(amount);
        require(address(this).balance >= amount, "ETH balance is less than amount");
        depositReturn = eeth.deposit{value: amount}();
        require(depositReturn == amount);
    }

    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        // TODO: implement dex swap
    }

    function snapshotYield() public override returns (uint256) {
        // TODO calculate & snapshot yield
    }
}
