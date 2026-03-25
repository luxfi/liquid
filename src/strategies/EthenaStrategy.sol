// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface ISUSDe {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function cooldownAssets(uint256 assets) external returns (uint256 shares);
    function cooldownShares(uint256 shares) external returns (uint256 assets);
    function unstake(address receiver) external;
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function asset() external view returns (address);
    function cooldownDuration() external view returns (uint24);
}

/// @title EthenaStrategy
/// @notice Deposits USDe into sUSDe (Staked USDe) for high-yield stablecoin exposure.
/// Ethena is a synthetic dollar protocol (~$5B+ TVL) providing 15-30% APY.
/// Yield comes from delta-neutral ETH staking + funding rate capture.
/// Note: sUSDe has a cooldown period for withdrawals (typically 7 days).
contract EthenaStrategy is LiquidStrategy {
    ISUSDe public immutable sUSDe;
    address public immutable usde;

    constructor(
        address _vault,
        StrategyParams memory _params,
        address _sUSDe
    ) LiquidStrategy(_vault, _params) {
        require(_sUSDe != address(0), "Zero sUSDe");
        sUSDe = ISUSDe(_sUSDe);
        usde = sUSDe.asset();
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(usde, address(this)) >= amount, "Insufficient USDe");
        TokenUtils.safeApprove(usde, address(sUSDe), amount);
        sUSDe.deposit(amount, address(this));
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 shares = sUSDe.convertToShares(amount);
        uint256 held = sUSDe.balanceOf(address(this));
        if (shares > held) shares = held;
        // Initiate cooldown -- tokens are not immediately available
        sUSDe.cooldownShares(shares);
        return sUSDe.convertToAssets(shares);
    }

    /// @notice Complete withdrawal after cooldown period has elapsed
    function _claimWithdrawalQueue(uint256) internal override returns (uint256) {
        uint256 balBefore = TokenUtils.safeBalanceOf(usde, address(this));
        sUSDe.unstake(address(this));
        uint256 received = TokenUtils.safeBalanceOf(usde, address(this)) - balBefore;
        if (received > 0) {
            TokenUtils.safeTransfer(usde, address(VAULT), received);
        }
        return received;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        uint256 currentPPS = sUSDe.convertToAssets(1e18);
        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
    }

    function realAssets() external view override returns (uint256) {
        return sUSDe.convertToAssets(sUSDe.balanceOf(address(this)));
    }
}
