---
sidebar_position: 5
hide_title: true
sidebar_label: lAssets
---

import lAssets from '@site/static/img/lAssets-01.png';

<!-- TODO -->

<img src={lAssets} alt="lAssets" class="banner-spacing" />

lAssets (LUSD, LETH) are synthetic tokens that mirror the value of their underlying asset. They play two roles:

1. **Borrowing unit** - When you open a loan, new lAssets are minted to you.

2. **Redemption instrument** - Anyone can deposit lAssets into the Transmuter to redeem 1 lAsset for the equivalent value of the MYT after a fixed term.

Because the protocol always values 1 lAsset at 1 unit of its underlying, but the market price can drift below parity, borrowing and redemption create a predictable risk-to-reward profile.

:::note Not an Algorithmic Stablecoin
lAssets are **synthetic debt tokens**, not algorithmic stablecoins. Every 1 lAsset in circulation is backed by at least 1 unit of collateral in the Liquid system. The peg is maintained via the Transmuter's 1:1 exchange mechanism, not by minting/burning algorithms.<br/><br/> [Learn more about the Transmuter](./transmuter.md).
:::

## Borrowing, Selling, and the Market Discount

When you borrow, the protocol mints lAssets at face value. 1 lAsset offsets exactly 1 unit of debt inside Liquid. If you sell those tokens on an exchange, you may receive less than 1.00 because lAssets can trade at a market discount (the gap between their external price and their internal 1:1 accounting value). For borrowers this discount is an upfront cost; for traders its a source of fixed return.

| Action        | Inside Liquid            | On the open market                 |
| ------------- | -------------------------- | ---------------------------------- |
| Mint lAssets | 1 lAsset = 1 unit of debt | –                                  |
| Sell lAssets | –                          | Price < 1.00 → **market discount** |
| Deleveraging  | lAssets repay debt at 1:1 | Creates transmuter opportunities   |

### Example

Deposit 1,000 USDC, mint 900 LUSD (90% LTV). If LUSD trades at 0.97 USDC, selling yields 873 USDC (a 27 USDC market discount) while your recorded debt inside the vault remains 900 USD.

## Why lAssets trade below par

- Loan demand - Borrowers mint and sell lAssets for working capital.

- Liquidity - Low liquidity can result in more dramatic price swings.

- Market sentiment - Traders may discount synthetic assets during volatility.

A small predictable discount is healthy; large discrepancies invite arbitrage.

## Mechanisms that close the discount

| Mechanism              | How it helps                                                                                                  |
| ---------------------- | ------------------------------------------------------------------------------------------------------------- |
| Transmuter             | Fixed-duration redemptions let traders lock in the spread as a bond-like yield, burning lAssets at maturity. |
| Repayment arbitrage    | Borrowers can buy lAssets cheaply to repay debt below face value.                                            |
| Liquidity provisioning | Farming rewards encourage holding lAssets, soaking up sell pressure.                                         |

Together these forces pull market price toward 1.00 and keep borrowing capital-efficient.

## LTV Sensitivity

A higher LTV does not, by itself, change the percentage discount an lAsset trades at. That spread is driven mainly by market liquidity and demand. What changes with LTV is your exposure to that discount and how yield interacts with redemptions to affect your leverage over time.

All positions redeem collateral at the same rate, but at high LTVs, the yield from your remaining collateral is less able to offset those redemptions. This means your collateral balance will likely fall alongside your debt, and if you want to maintain the same leverage, you’ll need to re-borrow more often. This makes you more sensitive to short-term price moves and transaction costs.

At lower LTVs, yield from the larger collateral base can offset redemptions more effectively, sometimes even allowing your collateral to grow despite debt reduction. This slower pace of deleveraging gives you more flexibility in deciding when or whether to re-leverage, since the position is less reactive to each redemption window.

## Key Takeaways

- **Discount upfront, benefit over time** - You lock in a minimum benefit today with significant additional upside.

- **Transmuter arbitrage keeps the system tight** - Traders earn yield, borrowers deleverage, peg stabilises.
