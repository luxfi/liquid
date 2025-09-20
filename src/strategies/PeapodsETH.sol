// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MYTStrategy} from "../MYTStrategy.sol";

import {IERC4626} from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface WETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract PeapodsETHStrategy is MYTStrategy {
    IERC4626 public immutable peapodsEth;
    WETH public immutable weth;

    constructor(address _myt, StrategyParams memory _params, address _peapodsEth, address _weth) MYTStrategy(_myt, _params) {
        peapodsEth = IERC4626(_peapodsEth);
        weth = WETH(_weth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        depositReturn = peapodsEth.deposit(amount, address(this));
    }

    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        uint256 shares = peapodsEth.convertToShares(amount);
        withdrawReturn = peapodsEth.redeem(shares, address(this), address(this));
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= withdrawReturn, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(weth), msg.sender, withdrawReturn);
        TokenUtils.safeTransfer(address(weth), msg.sender, withdrawReturn);
    }

    function _unwrapWETH(uint256 amount, address to) internal {
        weth.withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH send failed");
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = peapodsEth.convertToAssets(1e18);
        newIndex = currentPPS;

        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    receive() external payable {
        require(msg.sender == address(weth), "Only WETH unwrap");
    }
}
