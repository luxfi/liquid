# Lux Liquid

## Overview
Self-repaying lending protocol on Lux. Users deposit yield-bearing collateral,
borrow synthetic debt tokens (e.g. LETH), and debt is automatically repaid via
yield. Includes a Transmuter for converting synthetics back to yield tokens
over time.

## Tech Stack
- **Language**: Solidity 0.8.28
- **Framework**: Foundry (forge, cast)
- **EVM**: Cancun
- **Dependencies**: OpenZeppelin 5.x, forge-std, vault-v2, permit2, solmate

## Build & Run
```bash
forge build           # Compile all contracts
forge test -v         # Run tests
forge test --match-path "src/test/Liquid.t.sol" -v  # Run specific test
```

## Key Contracts
- `Liquid.sol` -- Core lending engine (Initializable proxy pattern, empty constructor + initialize)
- `LiquidPosition.sol` -- ERC721 NFT representing user positions (constructor takes liquid address)
- `LiquidTransmuter.sol` -- Converts synthetic tokens to yield tokens over time (Fenwick tree / StakingGraph)
- `LiquidETHVault.sol` -- ETH/WETH fee vault (constructor: weth, liquid, owner)
- `LiquidTokenVault.sol` -- ERC20 fee vault
- `LiquidCurator.sol` -- Strategy cap management (constructor: admin, operator)
- `LiquidAllocator.sol` -- Capital allocation to strategies (constructor: vault-v2, admin, operator)
- `LiquidStrategyClassifier.sol` -- Risk class management (constructor: admin)
- `LiquidStrategy.sol` -- Base strategy adapter for VaultV2 flows
- `LiquidGauge.sol` -- Governance gauge for strategy weight voting
- `LiquidGate.sol` / `LiquidCompliance.sol` -- Auth + KYC gating for redemptions

## Constructor Signatures (critical for deployment)
- `Liquid()` -- empty, then call `initialize(LiquidInitializationParams)`
- `LiquidPosition(address liquid_)`
- `LiquidTransmuter(ILiquidTransmuter.TransmuterInitializationParams memory params)`
- `LiquidETHVault(address _weth, address _liquid, address _owner)`
- `LiquidCurator(address _admin, address _operator)` via PermissionedProxy
- `LiquidAllocator(address _vault, address _admin, address _operator)` via PermissionedProxy
- `LiquidStrategyClassifier(address _admin)`

## Deployment Order
1. Deploy Liquid (empty constructor)
2. Deploy LiquidPosition (needs liquid address)
3. Deploy LiquidTransmuter (needs debt token address)
4. Deploy LiquidETHVault (needs WLUX + liquid address)
5. Call liquid.initialize(params) with transmuter address
6. Call liquid.setLiquidPositionNFT(position)
7. Call transmuter.setLiquid(liquid)
8. Whitelist liquid as minter on debt token (LETH)

## Canonical Lux Addresses
- LETH: `0x60E0a8167FC13dE89348978860466C9ceC24B9ba`
- WLUX: `0x4888E4a2Ee0F03051c72D2BD3ACf755eD3498B3E`
- LBTC: `0x1E48D32a4F5e9f08DB9aE4959163300FaF8A6C8e`

## Test Failures (pre-existing)
- Strategy fork tests (SfrxETH, MorphoYearnOGWETH, PeapodsETH, TokeAutoETH) -- need MAINNET_RPC_URL
- IntegrationTest -- needs Ethereum mainnet fork
- LiquidGauge (2 tests) -- logic bugs in cap application and vote aggregation
- MockERC20 IERC20 compliance -- mock doesn't implement full interface
- LiquidETHVault testDepositWETH -- mock WETH incomplete

## Scripts
- `script/DeployLux.s.sol` -- Multi-network deploy (mainnet/testnet/devnet, Liquidity chain IDs)
- `script/DeployMainnet.s.sol` -- Lux mainnet ETH deployment with canonical addresses
- `script/DeployLocal.s.sol` -- Full local stack (Anvil/luxd)
- `script/TestFlow.s.sol` -- E2E smoke flow against a deployed local stack

## Structure
```
src/
  Liquid.sol, LiquidPosition.sol, LiquidTransmuter.sol
  LiquidETHVault.sol, LiquidTokenVault.sol
  LiquidCurator.sol, LiquidAllocator.sol
  LiquidStrategyClassifier.sol, LiquidStrategy.sol, LiquidGauge.sol
  LiquidGate.sol, LiquidCompliance.sol
  adapters/       -- AbstractFeeVault, EulerUSDCAdapter, SecurityTokenAdapter
  base/           -- Errors, ErrorMessages, LiquidTransmuterErrors
  external/       -- LETH (synthetic), interfaces
  governance/     -- LiquidGovernor, LiquidToken
  interfaces/     -- All interfaces
  libraries/      -- FixedPointMath, SafeCast, SafeERC20, TokenUtils, StakingGraph, …
  mocks/          -- ERC20Mock, Pool, Stake, StakingPoolMock
  strategies/     -- EETH, SfrxETH, Lido, EigenLayer, Pendle, Morpho, Yearn, …
  test/           -- All test files
  utils/          -- PermissionedProxy, Whitelist, ZeroXSwapVerifier
script/
  DeployLux.s.sol, DeployMainnet.s.sol, DeployLocal.s.sol, TestFlow.s.sol
lib/
  forge-std, openzeppelin-contracts, openzeppelin-contracts-upgradeable
  vault-v2, permit2, solmate, chainlink-brownie-contracts, halmos-cheatcodes
```
