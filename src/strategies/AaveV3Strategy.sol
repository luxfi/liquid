// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken {
    function balanceOf(address account) external view returns (uint256);
    function scaledBalanceOf(address user) external view returns (uint256);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

interface IAaveV3DataProvider {
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 unbacked,
            uint256 accruedToTreasuryScaled,
            uint256 totalAToken,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        );
}

/// @title AaveV3Strategy
/// @notice Deposits any supported token into Aave V3 lending pool to earn supply APY.
/// Aave V3 is the largest multi-chain lending protocol (~$20B+ TVL).
/// Yield comes from borrower interest payments.
/// Works with any aToken (WETH, USDC, USDT, DAI, etc).
contract AaveV3Strategy is LiquidStrategy {
    IAaveV3Pool public immutable pool;
    IAToken public immutable aToken;
    IAaveV3DataProvider public immutable dataProvider;
    address public immutable underlying;

    constructor(
        address _vault,
        StrategyParams memory _params,
        address _pool,
        address _aToken,
        address _dataProvider
    ) LiquidStrategy(_vault, _params) {
        require(_pool != address(0), "Zero pool");
        require(_aToken != address(0), "Zero aToken");
        require(_dataProvider != address(0), "Zero dataProvider");
        pool = IAaveV3Pool(_pool);
        aToken = IAToken(_aToken);
        dataProvider = IAaveV3DataProvider(_dataProvider);
        underlying = aToken.UNDERLYING_ASSET_ADDRESS();
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(underlying, address(this)) >= amount, "Insufficient balance");
        TokenUtils.safeApprove(underlying, address(pool), amount);
        pool.supply(underlying, amount, address(this), 0);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 balBefore = TokenUtils.safeBalanceOf(underlying, address(this));
        pool.withdraw(underlying, amount, address(this));
        uint256 withdrawn = TokenUtils.safeBalanceOf(underlying, address(this)) - balBefore;
        TokenUtils.safeApprove(underlying, msg.sender, withdrawn);
        TokenUtils.safeTransfer(underlying, msg.sender, withdrawn);
        return withdrawn;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        // Aave V3 liquidityRate is in RAY (1e27) per second
        (,,,,, uint256 liquidityRate,,,,uint256 liquidityIndex,,) = dataProvider.getReserveData(underlying);
        newIndex = liquidityIndex;
        // Convert RAY rate to WAD rate
        ratePerSec = liquidityRate / 1e9;
    }

    function realAssets() external view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }
}
