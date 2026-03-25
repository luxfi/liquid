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
        withdrawReturn = eeth.requestWithdraw(address(this), amount);
        if (withdrawReturn > 0) {
            weth.deposit{value: withdrawReturn}();
            TokenUtils.safeTransfer(address(weth), msg.sender, withdrawReturn);
        }
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        // eETH is 1:1 rebasing; use balance growth as index
        uint256 currentBalance = TokenUtils.safeBalanceOf(address(eeth), address(this));
        newIndex = currentBalance;
        if (lastIndex == 0 || dt == 0 || currentBalance <= lastIndex) return (0, newIndex);
        uint256 growth = (currentBalance - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
    }

    function realAssets() external view override returns (uint256) {
        return TokenUtils.safeBalanceOf(address(eeth), address(this));
    }

    receive() external payable {}
}
