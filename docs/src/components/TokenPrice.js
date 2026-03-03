import React, { useState, useEffect } from "react";

function TokenPrice() {
  const [price, setPrice] = useState("N/A");

  useEffect(() => {
    // Fetch alETH price in ETH from CoinGecko API
    fetch(
      "https://api.coingecko.com/api/v3/simple/price?ids=alchemix-eth&vs_currencies=eth"
    )
      .then((response) => response.json())
      .then((data) => {
        const priceInEth = data["alchemix-eth"]?.eth;
        if (priceInEth !== undefined) {
          // Format
          const formattedPrice = parseFloat(priceInEth).toFixed(4);
          setPrice(formattedPrice);
        } else {
          // If data is missing, set N/A
          setPrice("N/A");
        }
      })
      .catch((error) => {
        console.error("Failed to fetch alETH price:", error);
        setPrice("N/A");
      });
  }, []);

  return (
    <div>**ALETH/ETH Price:** {price === "N/A" ? "N/A" : `${price} ETH`}</div>
  );
}

export default TokenPrice;
