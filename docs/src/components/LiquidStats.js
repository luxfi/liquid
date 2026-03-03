import React, { useState, useEffect } from "react";

function LiquidStats() {
  // State variables for each piece of data and their loading/error status
  const [tvl, setTvl] = useState(null);
  const [tvlError, setTvlError] = useState(false);

  const [alcxPrice, setAlcxPrice] = useState(null);
  const [alEthRatio, setAlEthRatio] = useState(null);
  const [priceError, setPriceError] = useState(false);

  const [monthlyRevenue, setMonthlyRevenue] = useState(null);
  const [revenueError, setRevenueError] = useState(false);

  const [treasury, setTreasury] = useState(null);
  const [treasuryError, setTreasuryError] = useState(false);

  useEffect(() => {
    // Fetch TVL
    const fetchTvl = async () => {
      try {
        const res = await fetch("https://api.llama.fi/tvl/alchemix");
        if (!res.ok) throw new Error("TVL fetch failed");
        const tvlValue = await res.json(); // API returns a number for TVL
        setTvl(tvlValue);
      } catch (err) {
        console.error("Error fetching TVL:", err);
        setTvlError(true);
      }
    };

    // Fetch token prices in one call
    const fetchPrices = async () => {
      try {
        const coins = [
          "coingecko:alchemix", // ALCX
          "coingecko:alchemix-eth", // alETH
          "coingecko:ethereum", // ETH
        ];
        const url = `https://coins.llama.fi/prices/current/${coins.join(",")}`;
        const res = await fetch(url);
        if (!res.ok) throw new Error("Price fetch failed");
        const data = await res.json();
        // Extract prices from the response
        const prices = data.coins;
        const alcxUsd = prices["coingecko:alchemix"]?.price;
        const alEthUsd = prices["coingecko:alchemix-eth"]?.price;
        const ethUsd = prices["coingecko:ethereum"]?.price;
        setAlcxPrice(alcxUsd);
        // Calculate alETH/ETH ratio if both prices are available
        if (alEthUsd != null && ethUsd != null) {
          setAlEthRatio(alEthUsd / ethUsd);
        } else {
          setAlEthRatio(null);
        }
      } catch (err) {
        console.error("Error fetching prices:", err);
        setPriceError(true);
      }
    };

    // Trigger all fetches
    fetchTvl();
    fetchPrices();
  }, []);

  // Formatting numbers as USD
  const formatUSD = (value) => {
    return `$${Number(value).toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    })}`;
  };

  return (
    <div>
      <ul>
        <li>
          <strong>TVL:</strong>{" "}
          {tvlError ? (
            <span style={{ color: "red" }}>Error loading</span>
          ) : tvl !== null ? (
            <span>{formatUSD(tvl)}</span>
          ) : (
            <span>Loading...</span>
          )}
        </li>
        <li>
          <strong>LQD Price:</strong>{" "}
          {priceError ? (
            <span style={{ color: "red" }}>Error loading</span>
          ) : alcxPrice !== null ? (
            <span>{formatUSD(alcxPrice)}</span>
          ) : (
            <span>Loading...</span>
          )}
        </li>

        <li>
          <strong>alETH/ETH:</strong>{" "}
          {priceError ? (
            <span style={{ color: "red" }}>Error loading</span>
          ) : alEthRatio !== null ? (
            <span>{alEthRatio.toFixed(3)}</span>
          ) : (
            <span>Loading...</span>
          )}
        </li>
      </ul>
    </div>
  );
}

export default LiquidStats;
