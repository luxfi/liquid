// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTStrategy} from "../MYTStrategy.sol";
import {IMYTStrategy} from "../interfaces/IMYTStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface WETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assetsOut);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function balanceOf(address account) external view returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

contract MorphoYearnOGWETHStrategy is MYTStrategy {
    WETH public immutable weth;
    IERC4626 public immutable vault;

    constructor(address _myt, StrategyParams memory _params, address _vault, address _weth) MYTStrategy(_myt, _params) {
        weth = WETH(_weth);
        vault = IERC4626(_vault);
        require(vault.asset() == _weth, "Vault asset != WETH");
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Strategy balance is less than amount");
        TokenUtils.safeApprove(address(weth), address(vault), amount);
        depositReturn = vault.deposit(amount, address(this));
    }

    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        uint256 shares = vault.convertToShares(amount);
        withdrawReturn = vault.redeem(shares, address(this), address(this));
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

        uint256 currentPPS = vault.convertToAssets(1e18);
        newIndex = currentPPS;

        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) {
            return (0, newIndex);
        }

        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    function realAssets() external view override returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(address(this)));
    }

    receive() external payable {
        require(msg.sender == address(weth), "Only WETH unwrap");
    }
}
