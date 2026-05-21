// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface ISavingsDai {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function asset() external view returns (address);
}

interface IPot {
    function dsr() external view returns (uint256);
    function chi() external view returns (uint256);
    function rho() external view returns (uint256);
}

/// @title MakerDSRStrategy
/// @notice Deposits DAI into the Maker DSR (DAI Savings Rate) via sDAI (ERC-4626).
/// The DSR is set by MakerDAO governance and provides risk-free yield on DAI.
/// sDAI is the canonical savings wrapper (~$2B+ TVL).
/// Yield comes from Maker protocol stability fees.
contract MakerDSRStrategy is LiquidStrategy {
    ISavingsDai public immutable sDAI;
    address public immutable dai;
    IPot public immutable pot;

    constructor(address _vault, StrategyParams memory _params, address _sDAI, address _pot) LiquidStrategy(_vault, _params) {
        require(_sDAI != address(0), "Zero sDAI");
        require(_pot != address(0), "Zero pot");
        sDAI = ISavingsDai(_sDAI);
        pot = IPot(_pot);
        dai = sDAI.asset();
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(dai, address(this)) >= amount, "Insufficient DAI");
        TokenUtils.safeApprove(dai, address(sDAI), amount);
        sDAI.deposit(amount, address(this));
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 shares = sDAI.convertToShares(amount);
        uint256 held = sDAI.balanceOf(address(this));
        if (shares > held) shares = held;
        uint256 withdrawn = sDAI.redeem(shares, address(this), address(this));
        TokenUtils.safeApprove(dai, msg.sender, withdrawn);
        TokenUtils.safeTransfer(dai, msg.sender, withdrawn);
        return withdrawn;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        // DSR is expressed as a per-second compounding rate in RAY (1e27)
        // dsr = 1e27 means 0% APR; dsr = 1.00000001e27 means ~31.5% APR
        uint256 dsr = pot.dsr();
        newIndex = pot.chi();
        // Convert RAY per-second rate to WAD growth rate
        // (dsr - 1e27) converts from multiplier to additive rate
        if (dsr > 1e27) {
            ratePerSec = (dsr - 1e27) / 1e9;
        }
    }

    function realAssets() external view override returns (uint256) {
        return sDAI.convertToAssets(sDAI.balanceOf(address(this)));
    }
}
