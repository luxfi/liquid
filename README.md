# Liquid Protocol

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.28-363636.svg)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

Self-repaying lending on Lux. Deposit yield-bearing collateral, borrow synthetic
debt against it, and let yield retire the debt over time. No liquidation
spirals, no manual repayments — the position pays itself off.

- **Core**: [`src/Liquid.sol`](src/Liquid.sol) — lending engine (UUPS-style proxy, `initialize` pattern)
- **Synthetic debt**: LETH (`alETH`-style 1:1-pegged synthetic), redeemable for the
  underlying via the Transmuter on a time-decay schedule
- **Yield routing**: VaultV2 + curated strategy adapters (Aave, Compound, Lido,
  EtherFi, Pendle, Morpho, Yearn, Ethena, EigenLayer, Maker DSR, plus native
  Lux-side strategies)
- **Compliance**: optional `LiquidComplianceGate` for whitelisted/KYC'd
  redemption flows on regulated collateral

---

## How it works

```
                              ┌──────────────────────────┐
   user deposits yield asset  │        Liquid.sol        │  mints LETH
   ─────────────────────────▶ │   (lending + position)   │ ─────────────▶ user
                              └─────────┬────────────────┘
                                        │ accounts position as ERC-721
                                        ▼
                              ┌──────────────────────────┐
                              │     LiquidPosition       │   NFT id ↔ owner
                              └──────────────────────────┘
                                        │
                                  yield │ (continuous)
                                        ▼
                              ┌──────────────────────────┐
                              │     LiquidTransmuter     │  burns LETH,
   LETH holders stake here ──▶│  (Fenwick / StakingGraph)│  releases yield-token
                              └──────────────────────────┘
```

1. **Deposit** a yield-bearing asset (wstETH, sfrxETH, weETH, sDAI, …) into
   `Liquid`. You receive an ERC-721 *position* via `LiquidPosition`.
2. **Mint** LETH against the position up to the protocol's collateralization
   floor. LETH is a transferable, fungible synthetic.
3. **Yield** earned by the deposited collateral is harvested into the
   `LiquidTransmuter`, which burns LETH 1:1 against the yield asset over time.
4. **Self-repayment**: as yield accrues, the position's debt is automatically
   reduced — no liquidation needed as long as the collateral keeps yielding.
5. **Transmute**: LETH holders can stake LETH in the Transmuter to redeem the
   underlying yield asset on a linear, block-weighted schedule (Fenwick tree
   accounting in [`StakingGraph`](src/libraries/StakingGraph.sol)).

Risk is bounded because debt is always backed by the same asset that produces
the yield repaying it. Liquidations exist as a backstop for tail-risk
de-pegging only.

---

## Contracts

### Core lending

| Contract | Purpose |
|----------|---------|
| [`Liquid.sol`](src/Liquid.sol) | Lending engine. Holds positions, mints/burns synthetic debt, harvests yield, enforces collateralization. UUPS-initializable; constructor empty. |
| [`LiquidPosition.sol`](src/LiquidPosition.sol) | ERC-721 representing a user's collateral+debt position. Only `Liquid` can mint/burn. |
| [`LiquidTransmuter.sol`](src/LiquidTransmuter.sol) | Converts synthetic LETH → underlying yield-token over time. Uses a Fenwick tree (`StakingGraph`) for O(log n) per-block accrual. ERC-721 tickets per stake. |

### Vaults & fees

| Contract | Purpose |
|----------|---------|
| [`LiquidETHVault.sol`](src/LiquidETHVault.sol) | Native ETH/WETH fee vault. Owner-gated withdrawals, anyone-deposits. |
| [`LiquidTokenVault.sol`](src/LiquidTokenVault.sol) | ERC-20 fee vault counterpart. |
| [`adapters/AbstractFeeVault.sol`](src/adapters/AbstractFeeVault.sol) | Shared base — auth, accounting, events. |

### Yield routing

| Contract | Purpose |
|----------|---------|
| [`LiquidStrategy.sol`](src/LiquidStrategy.sol) | Base strategy that wraps a `vault-v2` adapter. APR/APY snapshotting, kill-switch, allocator whitelist, 0x-swap verification via [`ZeroXSwapVerifier`](src/utils/ZeroXSwapVerifier.sol). |
| [`LiquidCurator.sol`](src/LiquidCurator.sol) | DAO-only contract that sets absolute and relative caps on each adapter. Permissioned proxy pattern. |
| [`LiquidAllocator.sol`](src/LiquidAllocator.sol) | Routes capital from the underlying VaultV2 into approved strategy adapters. Per-strategy allocation cap. |
| [`LiquidStrategyClassifier.sol`](src/LiquidStrategyClassifier.sol) | Risk-class registry (per-class `globalCap`/`localCap`). |
| [`LiquidGauge.sol`](src/LiquidGauge.sol) | Token-weighted gauge for voting strategy weights; keeper executes the weighted allocation each epoch. |

### Strategy adapters ([`src/strategies/`](src/strategies/))

DeFi blue-chips: `AaveV3Strategy`, `CompoundV3Strategy`, `LidoStrategy` (stETH/wstETH),
`EETH` (EtherFi weETH), `SfrxETH` (Frax), `MakerDSRStrategy` (sDAI),
`MorphoStrategy`, `MorphoYearnOGWETH`, `YearnV3Strategy`, `PendleStrategy`,
`EthenaStrategy` (sUSDe), `EigenLayerStrategy`, `PeapodsETH`, `TokeAutoEth`,
plus `LuxNative` for Lux-chain native staking.

Each adapter is a thin wrapper that conforms to `ITokenAdapter` and is risk-classified by the
classifier before the curator approves it for allocation.

### Governance

| Contract | Purpose |
|----------|---------|
| [`governance/LiquidToken.sol`](src/governance/LiquidToken.sol) | Governance token (LIQUID). |
| [`governance/LiquidGovernor.sol`](src/governance/LiquidGovernor.sol) | OZ Governor over `LiquidToken`. Sets caps, classes, transmuter parameters, and curator/allocator admins. |

### Compliance & access

| Contract | Purpose |
|----------|---------|
| [`LiquidGate.sol`](src/LiquidGate.sol) | Per-vault, per-account allowlist for redemptions. |
| [`LiquidComplianceGate.sol`](src/LiquidComplianceGate.sol) | KYC-tier gate (0=none, 1=basic, 2=accredited Reg D, 3=qualified purchaser Reg S). Set per-vault required level. Used for regulated-collateral deployments. |
| [`adapters/SecurityTokenAdapter.sol`](src/adapters/SecurityTokenAdapter.sol) | Adapter for tokenized securities collateral, paired with the compliance gate. |
| [`utils/Whitelist.sol`](src/utils/Whitelist.sol) | Generic whitelist primitive. |
| [`utils/PermissionedProxy.sol`](src/utils/PermissionedProxy.sol) | Selector-gated proxy used by curator/allocator. |

### Libraries

[`PositionDecay`](src/libraries/PositionDecay.sol),
[`StakingGraph`](src/libraries/StakingGraph.sol) (Fenwick tree),
[`FixedPointMath`](src/libraries/FixedPointMath.sol),
[`SafeCast`](src/libraries/SafeCast.sol),
[`SafeERC20`](src/libraries/SafeERC20.sol),
[`TokenUtils`](src/libraries/TokenUtils.sol),
[`Sets`](src/libraries/Sets.sol),
[`NFTMetadataGenerator`](src/libraries/NFTMetadataGenerator.sol).

---

## Canonical deployments (Lux mainnet)

| Token | Address |
|-------|---------|
| LETH (synthetic) | `0x60E0a8167FC13dE89348978860466C9ceC24B9ba` |
| WLUX            | `0x4888E4a2Ee0F03051c72D2BD3ACf755eD3498B3E` |
| LBTC            | `0x1E48D32a4F5e9f08DB9aE4959163300FaF8A6C8e` |

Network IDs supported by [`script/DeployLux.s.sol`](script/DeployLux.s.sol):
Lux mainnet/testnet/devnet, plus Liquidity chain IDs `8675309/10/11`,
local dev `1337`/`31337`.

---

## Quickstart

```bash
git clone https://github.com/luxfi/liquid.git
cd liquid
forge install
forge build
forge test -vv
```

### Run a full local stack

End-to-end deploy + smoke flow on Anvil or a local `luxd`:

```bash
anvil --chain-id 1337 &
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
forge script script/TestFlow.s.sol    --rpc-url http://127.0.0.1:8545 --broadcast
```

`DeployLocal` brings up: Liquid + Position + Transmuter + ETHVault + Curator +
StrategyClassifier + ComplianceGate, plus dev tokens (WLUX, LUSD, mock
securities) and a `SecurityTokenAdapter` so the regulated-collateral path is
exercisable locally.

### Deploy to a network

```bash
make deploy-devnet    # api.lux-dev.network
make deploy-testnet   # api.lux-test.network
make deploy-mainnet   # api.lux.network (uses canonical LETH/WLUX/LBTC)
```

Set `LUX_MNEMONIC` in `.env`. Add `--verify` (and the appropriate verifier
key) for explorer verification.

---

## Deployment order (canonical)

```solidity
// 1. core
Liquid liquid                = new Liquid();                              // empty ctor
LiquidPosition position      = new LiquidPosition(address(liquid));
LiquidTransmuter transmuter  = new LiquidTransmuter(transmuterParams);    // needs debtToken
LiquidETHVault feeVault      = new LiquidETHVault(WETH, address(liquid), owner);

// 2. wire
liquid.initialize(LiquidInitializationParams({ ... transmuter: address(transmuter) ... }));
liquid.setLiquidPositionNFT(address(position));
transmuter.setLiquid(address(liquid));

// 3. authorize the engine to mint synthetic debt
ILiquidMintable(LETH).setMinter(address(liquid), true);

// 4. yield routing (optional but typical)
LiquidStrategyClassifier classifier = new LiquidStrategyClassifier(admin);
LiquidCurator curator               = new LiquidCurator(admin, operator);
LiquidAllocator allocator           = new LiquidAllocator(vaultV2, admin, operator);
```

See [`script/DeployMainnet.s.sol`](script/DeployMainnet.s.sol) for the full,
parameterized version with collateralization floors, fee BPS, and block-rate
constants.

---

## Building on Liquid

### Open a position (yield-bearing collateral → LETH)

```solidity
IERC20(yieldToken).approve(address(liquid), amount);
uint256 tokenId = 0;                              // 0 = mint a new position NFT
uint256 shares  = liquid.deposit(amount, msg.sender, tokenId);
liquid.mint(tokenId, debtAmount, msg.sender);     // borrow LETH against position
```

### Repay or withdraw

```solidity
liquid.burn(tokenId, repayAmount);                // burn LETH, reduce debt
liquid.repay(tokenId, repayAmount);               // alt: repay in underlying yield-asset
liquid.withdraw(tokenId, shares, msg.sender);
```

### Transmute LETH → underlying

```solidity
IERC20(LETH).approve(address(transmuter), amount);
uint256 ticketId = transmuter.createRedemption(amount);
// ... time passes ...
transmuter.claimRedemption(ticketId);             // proportionally vested
```

### Add a strategy adapter

1. Implement `ITokenAdapter` (or extend [`LiquidStrategy`](src/LiquidStrategy.sol) for VaultV2-backed flows).
2. Register risk class with `LiquidStrategyClassifier.setStrategyRiskLevel(strategyId, riskLevel)`.
3. Curator sets caps: `LiquidCurator.setCaps(adapter, abs, rel)`.
4. Allocator routes flow: `LiquidAllocator.allocate(adapter, data, assets)`.
5. (Optional) wire into `LiquidGauge` for token-vote-weighted allocation.

### Deploy a regulated variant

Pair `SecurityTokenAdapter` with `LiquidComplianceGate`:

```solidity
gate.setRequiredLevel(vault, 2);                  // accredited (Reg D)
gate.approve(investor, /*level*/ 2);
gate.setAuthorization(vault, investor, true);
```

The standard ERC-20 LETH path stays open for deposits; redemption and
collateral-backed mints route through the gate.

---

## Build, test, audit

```bash
make build         # forge build
make test          # forge test --summary
make test-fuzz     # fuzz suite (1000 runs)
make coverage      # IR-min coverage summary
make halmos        # symbolic execution on `check_*` properties

# static analysis (slither + semgrep + aderyn, set up via uv venv)
make security
make audit         # lint + test + security
```

`Liquid.t.sol`, `LiquidTransmuter.t.sol`, fuzz/, and integration tests live in
[`src/test/`](src/test/). Fork-mode strategy tests (SfrxETH, MorphoYearnOGWETH,
PeapodsETH, TokeAutoEth, IntegrationTest) require `MAINNET_RPC_URL`.

---

## Layout

```
src/
  Liquid.sol                     LiquidPosition.sol     LiquidTransmuter.sol
  LiquidETHVault.sol             LiquidTokenVault.sol
  LiquidStrategy.sol             LiquidCurator.sol      LiquidAllocator.sol
  LiquidStrategyClassifier.sol   LiquidGauge.sol
  LiquidGate.sol                 LiquidComplianceGate.sol
  adapters/      AbstractFeeVault, EulerUSDCAdapter, SecurityTokenAdapter
  governance/    LiquidToken, LiquidGovernor
  strategies/    Aave/Compound/Lido/EETH/SfrxETH/Pendle/Morpho/Yearn/Ethena/…
  libraries/     StakingGraph, PositionDecay, FixedPointMath, SafeCast, …
  interfaces/    ILiquid*, ITokenAdapter, IWETH, IYieldToken, …
  utils/         PermissionedProxy, Whitelist, ZeroXSwapVerifier
  external/      AlEth (canonical synthetic), interfaces
  test/          unit + fuzz + integration
script/
  DeployLux.s.sol     multi-network (mainnet/testnet/devnet + Liquidity IDs)
  DeployMainnet.s.sol Lux mainnet, canonical LETH/WLUX/LBTC
  DeployLocal.s.sol   end-to-end local stack on Anvil/luxd
  TestFlow.s.sol      smoke test against a deployed local stack
lib/
  forge-std, openzeppelin-{contracts,upgradeable}, vault-v2,
  permit2, solmate, chainlink-brownie-contracts, halmos-cheatcodes
```

---

## Versioning

`IVersioned` is implemented across core contracts. Liquid + Transmuter are at
`3.0.0`. Update only the version of the contract that changed.

## Audits

Drop received reports under `audits/` at the repo root. Static analyzers
(Slither, Semgrep, Aderyn) and Halmos symbolic execution run via `make
security` / `make halmos`.

## Security

Disclosure: see [`SECURITY.md`](SECURITY.md).

## License

MIT — see [`LICENSE`](LICENSE).
