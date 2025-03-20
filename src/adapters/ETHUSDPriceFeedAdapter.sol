// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ETHUSDConverter} from "./ETHUSDConverter.sol";
// Address of the mainnet ETH/USD price feed

interface IPriceFeedAdapter {
    /**
     * @notice Get the current ETH/USD price
     * @return The price of ETH in USD with 8 decimals
     */
    function getPrice() external view returns (uint256);
    /**
     * @notice Convert USD amount to ETH value
     * @param usdAmount Amount in USD (6 decimals)
     * @return ethAmount Equivalent amount in ETH/WETH (18 decimals)
     */
    function usdToETH(uint256 usdAmount) external view returns (uint256);
    /**
     * @notice Convert ETH amount to USD value
     * @param ethAmount Amount of ETH/WETH to convert
     * @return usdAmount Equivalent amount in USD (6 decimals)
     */
    function ethToUSD(uint256 ethAmount) external view returns (uint256);
    /**
     * @notice Convert underlying token amount to USD value
     * @param underlyingTokenAmount Amount of underlying token to convert
     * @return usdAmount Equivalent amount in USD (6 decimals)
     */
    function underlyingTokenToUSD(uint256 underlyingTokenAmount) external view returns (uint256);
}

// Price feed adapter for ETH/USD price feed per chain
contract ETHUSDPriceFeedAdapter is IPriceFeedAdapter {
    address immutable priceFeed;

    /**
     * @notice Constructor for the ETHUSDPriceFeedAdapter
     * @param _priceFeed The address of the ETH/USD price feed
     */
    constructor(address _priceFeed) {
        priceFeed = _priceFeed;
    }

    // @inheritdoc IPriceFeedAdapter
    function getPrice() external view override returns (uint256) {
        return ETHUSDConverter.getETHUSDPrice(priceFeed);
    }

    // @inheritdoc IPriceFeedAdapter
    function usdToETH(uint256 usdAmount) external view returns (uint256 ethAmount) {
        return ETHUSDConverter.usdToETH(usdAmount, priceFeed);
    }

    // @inheritdoc IPriceFeedAdapter
    function ethToUSD(uint256 ethAmount) external view returns (uint256 usdAmount) {
        return ETHUSDConverter.ethToUSD(ethAmount, priceFeed);
    }

    // @inheritdoc IPriceFeedAdapter
    function underlyingTokenToUSD(uint256 underlyingTokenAmount) external view returns (uint256 usdAmount) {
        return ETHUSDConverter.underlyingTokenToUSD(underlyingTokenAmount);
    }
}
