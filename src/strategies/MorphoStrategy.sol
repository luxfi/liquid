// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IMorphoVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
}

/// @title MorphoStrategy
/// @notice Deposits into any Morpho vault (MetaMorpho) for optimized lending yield.
/// Morpho aggregates lending across multiple markets (Aave, Compound, isolated pairs)
/// to achieve higher supply APY than any single protocol (~$5B+ TVL).
/// Each MetaMorpho vault is ERC-4626 compliant.
contract MorphoStrategy is LiquidStrategy {
    IMorphoVault public immutable morphoVault;
    address public immutable underlying;

    constructor(
        address _vault,
        StrategyParams memory _params,
        address _morphoVault
    ) LiquidStrategy(_vault, _params) {
        require(_morphoVault != address(0), "Zero morphoVault");
        morphoVault = IMorphoVault(_morphoVault);
        underlying = morphoVault.asset();
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(underlying, address(this)) >= amount, "Insufficient balance");
        TokenUtils.safeApprove(underlying, address(morphoVault), amount);
        morphoVault.deposit(amount, address(this));
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 balBefore = TokenUtils.safeBalanceOf(underlying, address(this));
        morphoVault.withdraw(amount, address(this), address(this));
        uint256 withdrawn = TokenUtils.safeBalanceOf(underlying, address(this)) - balBefore;
        TokenUtils.safeApprove(underlying, msg.sender, withdrawn);
        TokenUtils.safeTransfer(underlying, msg.sender, withdrawn);
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
