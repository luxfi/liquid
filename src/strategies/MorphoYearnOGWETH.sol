// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IMorphoYearnOGVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
}

/// @title  MorphoYearnOGWETHStrategy
/// @notice Deposits WETH into Morpho's Yearn OG WETH vault for optimized lending yield.
contract MorphoYearnOGWETHStrategy is LiquidStrategy {
    IMorphoYearnOGVault public immutable morphoVault;
    address public immutable weth;

    constructor(
        address _vault,
        StrategyParams memory _params,
        address _morphoVault,
        address _weth
    ) LiquidStrategy(_vault, _params) {
        require(_morphoVault != address(0), "Zero morphoVault");
        require(_weth != address(0), "Zero WETH");
        morphoVault = IMorphoYearnOGVault(_morphoVault);
        weth = _weth;
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(weth, address(this)) >= amount, "Insufficient balance");
        TokenUtils.safeApprove(weth, address(morphoVault), amount);
        morphoVault.deposit(amount, address(this));
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 balBefore = TokenUtils.safeBalanceOf(weth, address(this));
        morphoVault.withdraw(amount, address(this), address(this));
        uint256 withdrawn = TokenUtils.safeBalanceOf(weth, address(this)) - balBefore;
        TokenUtils.safeTransfer(weth, msg.sender, withdrawn);
        return withdrawn;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        uint256 currentPPS = morphoVault.convertToAssets(1e18);
        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
    }

    function realAssets() external view override returns (uint256) {
        return morphoVault.convertToAssets(morphoVault.balanceOf(address(this)));
    }
}
