// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function baseToken() external view returns (address);
    function getSupplyRate(uint256 utilization) external view returns (uint64);
    function getUtilization() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface ICometRewards {
    function claim(address comet, address src, bool shouldAccrue) external;
    function getRewardOwed(address comet, address account) external returns (address token, uint256 owed);
}

/// @title CompoundV3Strategy
/// @notice Deposits base token (e.g. USDC, WETH) into Compound V3 (Comet) to earn supply APY.
/// Compound V3 is a major lending protocol (~$3B+ TVL) with isolated markets per base token.
/// Yield comes from borrower interest + COMP token rewards.
contract CompoundV3Strategy is LiquidStrategy {
    IComet public immutable comet;
    ICometRewards public immutable rewards;
    address public immutable baseToken;

    constructor(
        address _vault,
        StrategyParams memory _params,
        address _comet,
        address _rewards
    ) LiquidStrategy(_vault, _params) {
        require(_comet != address(0), "Zero comet");
        require(_rewards != address(0), "Zero rewards");
        comet = IComet(_comet);
        rewards = ICometRewards(_rewards);
        baseToken = comet.baseToken();
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(baseToken, address(this)) >= amount, "Insufficient balance");
        TokenUtils.safeApprove(baseToken, address(comet), amount);
        comet.supply(baseToken, amount);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 balBefore = TokenUtils.safeBalanceOf(baseToken, address(this));
        comet.withdraw(baseToken, amount);
        uint256 withdrawn = TokenUtils.safeBalanceOf(baseToken, address(this)) - balBefore;
        TokenUtils.safeApprove(baseToken, msg.sender, withdrawn);
        TokenUtils.safeTransfer(baseToken, msg.sender, withdrawn);
        return withdrawn;
    }

    function _claimRewards() internal override returns (uint256) {
        (, uint256 owed) = rewards.getRewardOwed(address(comet), address(this));
        if (owed > 0) {
            rewards.claim(address(comet), address(this), true);
        }
        return owed;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 utilization = comet.getUtilization();
        uint256 supplyRate = comet.getSupplyRate(utilization);
        // Compound V3 supply rate is per-second in 1e18
        ratePerSec = supplyRate;
        newIndex = comet.balanceOf(address(this));
    }

    function realAssets() external view override returns (uint256) {
        return comet.balanceOf(address(this));
    }
}
