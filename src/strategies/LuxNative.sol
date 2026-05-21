// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal interface for LiquidLUX (xLUX) -- an ERC4626-style yield vault.
interface ILiquidLUX {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
    function balanceOf(address account) external view returns (uint256);
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @title  LuxNativeStrategy
/// @author Lux Liquid
/// @notice Yield strategy that deposits WLUX into LiquidLUX (xLUX) on Lux C-Chain.
///         Yield comes from protocol fees (DEX, Bridge, Lending, Perps, NFT) routed
///         to the xLUX vault via FeeSplitter.
contract LuxNativeStrategy is LiquidStrategy {
    ILiquidLUX public immutable xLUX;

    /// @notice Tracks the WLUX-denominated value at last yield snapshot.
    uint256 public lastSnapshotValue;

    error ZeroXLUXAddress();
    error AssetMismatch();

    constructor(address _vault, StrategyParams memory _params, address _xLUX) LiquidStrategy(_vault, _params) {
        if (_xLUX == address(0)) revert ZeroXLUXAddress();
        xLUX = ILiquidLUX(_xLUX);

        // Sanity: xLUX underlying must be the vault's asset (WLUX).
        if (xLUX.asset() != address(VAULT.asset())) revert AssetMismatch();
    }

    /// @notice Deposit WLUX into the xLUX vault, receive shares.
    function _allocate(uint256 amount) internal override returns (uint256) {
        address wlux = address(VAULT.asset());
        TokenUtils.safeApprove(wlux, address(xLUX), amount);
        xLUX.deposit(amount, address(this));
        // Update snapshot baseline so deposits are not counted as yield.
        lastSnapshotValue = xLUX.convertToAssets(xLUX.balanceOf(address(this)));
        return amount;
    }

    /// @notice Withdraw WLUX from xLUX by redeeming the equivalent shares.
    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 shares = xLUX.convertToShares(amount);
        uint256 available = xLUX.balanceOf(address(this));
        if (shares > available) {
            shares = available;
        }
        uint256 assets = xLUX.redeem(shares, address(this), address(this));
        // Transfer redeemed WLUX back to the vault
        TokenUtils.safeTransfer(address(VAULT.asset()), address(VAULT), assets);
        return assets;
    }

    /// @notice Snapshot yield as xLUX share price appreciation since last snapshot.
    function snapshotYield() public override returns (uint256) {
        uint256 currentTime = block.timestamp;

        uint256 currentValue = xLUX.convertToAssets(xLUX.balanceOf(address(this)));
        uint256 yieldAmount = currentValue > lastSnapshotValue ? currentValue - lastSnapshotValue : 0;
        lastSnapshotValue = currentValue;

        // Compute rate for APR/APY tracking
        (uint256 baseRatePerSec, uint256 newIndex) = _computeBaseRatePerSecond();
        uint256 rewardsRatePerSec;
        if (params.additionalIncentives) rewardsRatePerSec = _computeRewardsRatePerSecond();

        uint256 totalRatePerSec = baseRatePerSec + rewardsRatePerSec;
        uint256 apr = totalRatePerSec * SECONDS_PER_YEAR;
        uint256 apy = _approxAPY(totalRatePerSec);

        uint256 alpha = 7e17; // 0.7
        estApr = _lerp(estApr, apr, alpha);
        estApy = _lerp(estApy, apy, alpha);

        lastSnapshotTime = uint64(currentTime);
        lastIndex = newIndex;

        emit YieldUpdated(estApy);
        return yieldAmount;
    }

    /// @notice Compute base rate from xLUX share price growth.
    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        // Price per share in WLUX terms
        uint256 currentPPS = xLUX.convertToAssets(1e18);
        newIndex = currentPPS;

        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);

        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
    }

    /// @notice Total real assets held by this strategy (WLUX equivalent).
    function realAssets() external view override returns (uint256) {
        return xLUX.convertToAssets(xLUX.balanceOf(address(this)));
    }
}
