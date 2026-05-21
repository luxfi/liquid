// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IEigenStrategyManager {
    function depositIntoStrategy(address strategy, address token, uint256 amount) external returns (uint256 shares);
    function stakerStrategyShares(address staker, address strategy) external view returns (uint256);
}

interface IEigenStrategy {
    function sharesToUnderlying(uint256 shares) external view returns (uint256);
    function underlyingToShares(uint256 amount) external view returns (uint256);
    function underlyingToken() external view returns (address);
    function userUnderlyingView(address user) external view returns (uint256);
}

interface IEigenDelegationManager {
    function undelegate(address staker) external returns (bytes32[] memory);
}

interface IEigenDelegationManagerQueued {
    function completeQueuedWithdrawal(
        IDelegationManagerTypes.Withdrawal calldata withdrawal,
        address[] calldata tokens,
        uint256 middlewareTimesIndex,
        bool receiveAsTokens
    ) external;
}

interface IDelegationManagerTypes {
    struct Withdrawal {
        address staker;
        address delegatedTo;
        address withdrawer;
        uint256 nonce;
        uint32 startBlock;
        address[] strategies;
        uint256[] shares;
    }
}

/// @title EigenLayerStrategy
/// @notice Restakes LST tokens (e.g. stETH, rETH) into EigenLayer for additional yield.
/// EigenLayer is the largest restaking protocol (~$10B+ TVL).
/// Yield comes from AVS (Actively Validated Services) payments on top of base staking yield.
contract EigenLayerStrategy is LiquidStrategy {
    IEigenStrategyManager public immutable strategyManager;
    IEigenStrategy public immutable eigenStrategy;
    address public immutable underlyingToken;

    constructor(address _vault, StrategyParams memory _params, address _strategyManager, address _eigenStrategy) LiquidStrategy(_vault, _params) {
        require(_strategyManager != address(0), "Zero strategyManager");
        require(_eigenStrategy != address(0), "Zero eigenStrategy");
        strategyManager = IEigenStrategyManager(_strategyManager);
        eigenStrategy = IEigenStrategy(_eigenStrategy);
        underlyingToken = eigenStrategy.underlyingToken();
        require(underlyingToken != address(0), "Zero underlying");
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(underlyingToken, address(this)) >= amount, "Insufficient balance");
        TokenUtils.safeApprove(underlyingToken, address(strategyManager), amount);
        strategyManager.depositIntoStrategy(address(eigenStrategy), underlyingToken, amount);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        // EigenLayer withdrawals are queued and require a 7-day delay.
        // The actual completion is handled via claimWithdrawalQueue.
        // Here we return the amount requested for accounting.
        // The vault/allocator must call undelegate() separately via the delegation manager.
        uint256 shares = eigenStrategy.underlyingToShares(amount);
        uint256 held = strategyManager.stakerStrategyShares(address(this), address(eigenStrategy));
        if (shares > held) shares = held;
        uint256 underlying = eigenStrategy.sharesToUnderlying(shares);
        return underlying;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        uint256 shares = strategyManager.stakerStrategyShares(address(this), address(eigenStrategy));
        uint256 currentValue = shares > 0 ? eigenStrategy.sharesToUnderlying(shares) : 0;
        newIndex = shares > 0 ? eigenStrategy.sharesToUnderlying(1e18) : 1e18;
        if (lastIndex == 0 || dt == 0 || newIndex <= lastIndex) return (0, newIndex);
        uint256 growth = (newIndex - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
    }

    function realAssets() external view override returns (uint256) {
        return eigenStrategy.userUnderlyingView(address(this));
    }
}
