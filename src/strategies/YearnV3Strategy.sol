// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IYearnV3Vault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner, uint256 maxLoss) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function asset() external view returns (address);
    function pricePerShare() external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

/// @title YearnV3Strategy
/// @notice Deposits into a Yearn V3 vault for automated yield aggregation.
/// Yearn V3 vaults (ERC-4626) automatically rotate capital across the best yield
/// sources in DeFi (~$1B+ TVL across all vaults).
/// Yield comes from automated strategy management across lending, LPing, farming.
contract YearnV3Strategy is LiquidStrategy {
    IYearnV3Vault public immutable yearnVault;
    address public immutable underlying;

    /// @notice Maximum loss tolerance in basis points for withdrawals (default 1bp)
    uint256 public maxLossBps;

    constructor(address _vault, StrategyParams memory _params, address _yearnVault, uint256 _maxLossBps) LiquidStrategy(_vault, _params) {
        require(_yearnVault != address(0), "Zero yearnVault");
        require(_maxLossBps <= 10_000, "Max loss > 100%");
        yearnVault = IYearnV3Vault(_yearnVault);
        underlying = yearnVault.asset();
        maxLossBps = _maxLossBps;
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(underlying, address(this)) >= amount, "Insufficient balance");
        TokenUtils.safeApprove(underlying, address(yearnVault), amount);
        yearnVault.deposit(amount, address(this));
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 shares = yearnVault.convertToShares(amount);
        uint256 held = yearnVault.balanceOf(address(this));
        if (shares > held) shares = held;
        uint256 balBefore = TokenUtils.safeBalanceOf(underlying, address(this));
        yearnVault.redeem(shares, address(this), address(this), maxLossBps);
        uint256 withdrawn = TokenUtils.safeBalanceOf(underlying, address(this)) - balBefore;
        TokenUtils.safeApprove(underlying, msg.sender, withdrawn);
        TokenUtils.safeTransfer(underlying, msg.sender, withdrawn);
        return withdrawn;
    }

    function setMaxLossBps(uint256 _maxLossBps) external onlyOwner {
        require(_maxLossBps <= 10_000, "Max loss > 100%");
        maxLossBps = _maxLossBps;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        uint256 currentPPS = yearnVault.convertToAssets(1e18);
        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
    }

    function realAssets() external view override returns (uint256) {
        return yearnVault.convertToAssets(yearnVault.balanceOf(address(this)));
    }
}
