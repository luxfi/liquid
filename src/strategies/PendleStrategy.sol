// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LiquidStrategy} from "../LiquidStrategy.sol";
import {TokenUtils} from "../libraries/TokenUtils.sol";

interface IPendleRouter {
    function addLiquiditySingleToken(
        address receiver,
        address market,
        uint256 minLpOut,
        ApproxParams calldata guessPtReceivedFromSy,
        TokenInput calldata input
    ) external returns (uint256 netLpOut, uint256 netSyFee);

    function removeLiquiditySingleToken(
        address receiver,
        address market,
        uint256 netLpToRemove,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut, uint256 netSyFee);

    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        SwapData swapData;
    }

    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address pendleSwap;
        SwapData swapData;
    }

    struct SwapData {
        SwapType swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    enum SwapType {
        NONE,
        KYBERSWAP,
        ONE_INCH,
        ETH_WETH
    }
}

interface IPendleMarket {
    function readTokens() external view returns (address sy, address pt, address yt);
    function balanceOf(address account) external view returns (uint256);
    function redeemRewards(address user) external returns (uint256[] memory);
    function getRewardTokens() external view returns (address[] memory);
    function totalActiveSupply() external view returns (uint256);
    function activeBalance(address user) external view returns (uint256);
}

interface IPendleSY {
    function exchangeRate() external view returns (uint256);
    function yieldToken() external view returns (address);
}

/// @title PendleStrategy
/// @notice Provides liquidity to Pendle markets for fixed-rate yield + trading fees.
/// Pendle is the largest yield tokenization protocol (~$5B+ TVL).
/// LP positions earn: swap fees + PT discount + YT yield + PENDLE rewards.
/// Each Pendle market has a maturity date -- strategy should be paired with matching duration.
contract PendleStrategy is LiquidStrategy {
    IPendleRouter public immutable router;
    IPendleMarket public immutable market;
    address public immutable underlying;

    constructor(
        address _vault,
        StrategyParams memory _params,
        address _router,
        address _market,
        address _underlying
    ) LiquidStrategy(_vault, _params) {
        require(_router != address(0), "Zero router");
        require(_market != address(0), "Zero market");
        require(_underlying != address(0), "Zero underlying");
        router = IPendleRouter(_router);
        market = IPendleMarket(_market);
        underlying = _underlying;
    }

    function _allocate(uint256 amount) internal override returns (uint256) {
        require(TokenUtils.safeBalanceOf(underlying, address(this)) >= amount, "Insufficient balance");
        TokenUtils.safeApprove(underlying, address(router), amount);

        IPendleRouter.TokenInput memory input = IPendleRouter.TokenInput({
            tokenIn: underlying,
            netTokenIn: amount,
            tokenMintSy: underlying,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: IPendleRouter.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        IPendleRouter.ApproxParams memory approx = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e15
        });

        (uint256 lpOut,) = router.addLiquiditySingleToken(
            address(this),
            address(market),
            0,
            approx,
            input
        );

        return lpOut > 0 ? amount : 0;
    }

    function _deallocate(uint256 amount) internal override returns (uint256) {
        uint256 lpBal = market.balanceOf(address(this));
        // Proportional LP removal based on requested underlying amount
        uint256 lpToRemove = lpBal > 0 ? (amount * lpBal) / realAssetsInternal() : 0;
        if (lpToRemove > lpBal) lpToRemove = lpBal;
        if (lpToRemove == 0) return 0;

        TokenUtils.safeApprove(address(market), address(router), lpToRemove);

        IPendleRouter.TokenOutput memory output = IPendleRouter.TokenOutput({
            tokenOut: underlying,
            minTokenOut: 0,
            tokenRedeemSy: underlying,
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: IPendleRouter.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        (uint256 tokenOut,) = router.removeLiquiditySingleToken(
            address(this),
            address(market),
            lpToRemove,
            output
        );

        if (tokenOut > 0) {
            TokenUtils.safeApprove(underlying, msg.sender, tokenOut);
            TokenUtils.safeTransfer(underlying, msg.sender, tokenOut);
        }
        return tokenOut;
    }

    function _claimRewards() internal override returns (uint256) {
        uint256[] memory amounts = market.redeemRewards(address(this));
        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        return total;
    }

    function _computeBaseRatePerSecond() internal override returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;
        (address sy,,) = market.readTokens();
        uint256 currentRate = IPendleSY(sy).exchangeRate();
        newIndex = currentRate;
        if (lastIndex == 0 || dt == 0 || currentRate <= lastIndex) return (0, newIndex);
        uint256 growth = (currentRate - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
    }

    function realAssetsInternal() internal view returns (uint256) {
        uint256 lpBal = market.balanceOf(address(this));
        if (lpBal == 0) return 0;
        (address sy,,) = market.readTokens();
        uint256 rate = IPendleSY(sy).exchangeRate();
        return lpBal * rate / 1e18;
    }

    function realAssets() external view override returns (uint256) {
        return realAssetsInternal();
    }
}
