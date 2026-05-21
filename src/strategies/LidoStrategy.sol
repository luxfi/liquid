// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWstETH {
    function wrap(uint256 stETHAmount) external returns (uint256);
    function unwrap(uint256 wstETHAmount) external returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function getWstETHByStETH(uint256 stETHAmount) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @title LidoStrategy
/// @notice Deposits WETH into Lido stETH, wraps to wstETH for non-rebasing accounting.
/// Largest TVL yield source in DeFi (~$15B+).
/// Yield comes from Ethereum PoS staking rewards (~3-4% APR).
contract LidoStrategy is LiquidStrategy {
    IStETH public immutable stETH;
    IWstETH public immutable wstETH;
    IWETH9 public immutable weth;

    constructor(address _vault, StrategyParams memory _params, address _stETH, address _wstETH, address _weth) LiquidStrategy(_vault, _params) {
        require(_stETH != address(0), "Zero stETH");
        require(_wstETH != address(0), "Zero wstETH");
        require(_weth != address(0), "Zero WETH");
        stETH = IStETH(_stETH);
        wstETH = IWstETH(_wstETH);
        weth = IWETH9(_weth);
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(address(weth), address(this)) >= amount, "Insufficient WETH");
        // Unwrap WETH -> ETH
        weth.withdraw(amount);
        // Stake ETH -> stETH
        uint256 stETHBefore = stETH.balanceOf(address(this));
        stETH.submit{value: amount}(address(0));
        uint256 stETHReceived = stETH.balanceOf(address(this)) - stETHBefore;
        // Wrap stETH -> wstETH for non-rebasing accounting
        stETH.approve(address(wstETH), stETHReceived);
        wstETH.wrap(stETHReceived);
        return amount;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        // Convert desired underlying amount to wstETH shares
        uint256 wstETHShares = wstETH.getWstETHByStETH(amount);
        uint256 held = wstETH.balanceOf(address(this));
        if (wstETHShares > held) wstETHShares = held;
        // Unwrap wstETH -> stETH
        uint256 stETHOut = wstETH.unwrap(wstETHShares);
        // Transfer stETH to vault (vault can handle stETH or swap)
        TokenUtils.safeApprove(address(stETH), msg.sender, stETHOut);
        TokenUtils.safeTransfer(address(stETH), msg.sender, stETHOut);
        return stETHOut;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        // wstETH price per share grows as staking rewards accrue
        uint256 currentPPS = wstETH.getStETHByWstETH(1e18);
        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
    }

    function realAssets() external view override returns (uint256) {
        return wstETH.getStETHByWstETH(wstETH.balanceOf(address(this)));
    }

    receive() external payable {}
}
