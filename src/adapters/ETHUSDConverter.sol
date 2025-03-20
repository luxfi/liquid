// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library ETHUSDConverter {
    // Address of the mainnet ETH/USD price feed
    uint256 private constant USDC_DECIMALS = 6;

    /**
     * @notice Convert ETH amount to USD value
     * @param ethAmount Amount of ETH/WETH to convert
     * @return usdAmount Equivalent amount in USD (6 decimals)
     */
    function ethToUSD(uint256 ethAmount, address usdPriceFeed) internal view returns (uint256 usdAmount) {
        // Get the latest ETH/USD price
        AggregatorV3Interface priceFeed = AggregatorV3Interface(usdPriceFeed);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // Ensure price is positive
        if (price <= 0) revert("Invalid price");

        // ETH has 18 decimals, USD representation has 6 decimals, Chainlink has 8 decimals
        // ethAmount * price / 10^20 = usdAmount (convert to 6 decimals)
        return (ethAmount * uint256(price)) / 1e20;
    }

    /**
     * @notice Convert USD value to ETH amount
     * @param usdAmount Amount in USD (6 decimals)
     * @return ethAmount Equivalent amount in ETH/WETH (18 decimals)
     */
    function usdToETH(uint256 usdAmount, address usdPriceFeed) internal view returns (uint256 ethAmount) {
        // Get the latest ETH/USD price
        AggregatorV3Interface priceFeed = AggregatorV3Interface(usdPriceFeed);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // Ensure price is positive
        if (price <= 0) revert("Invalid price");

        // USD representation has 6 decimals, ETH has 18 decimals, Chainlink has 8 decimals
        // usdAmount * 10^20 / price = ethAmount (convert to 18 decimals)
        return (usdAmount * 1e20) / uint256(price);
    }

    /**
     * @notice Get the current ETH/USD price
     * @return The price of ETH in USD with 8 decimals
     */
    function getETHUSDPrice(address usdPriceFeed) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(usdPriceFeed);
        (, int256 price,,,) = priceFeed.latestRoundData();
        if (price <= 0) revert("Invalid price");
        return uint256(price);
    }

    /**
     * @notice Convert underlying token amount to USD value
     * @param underlyingTokenAmount Amount of underlying token to convert
     * @return usdAmount Equivalent amount in USD (6 decimals)
     */
    function underlyingTokenToUSD(uint256 underlyingTokenAmount) internal view returns (uint256 usdAmount) {
        uint256 usdConversionFactor = 10 ** (18 - USDC_DECIMALS);
        return underlyingTokenAmount / usdConversionFactor;
    }
}
