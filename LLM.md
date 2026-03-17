# LLM.md - Hanzo Liquid (AlchemistV3)

## Overview
Self-repaying lending protocol (Alchemix V3 fork). Users deposit yield-bearing collateral, borrow synthetic debt tokens (e.g. LETH), and debt is automatically repaid via yield. Includes a Transmuter for converting synthetics back to yield tokens over time.

## Tech Stack
- **Language**: Solidity 0.8.28
- **Framework**: Foundry (forge, cast)
- **EVM**: Cancun
- **Dependencies**: OpenZeppelin 5.x, forge-std, vault-v2, permit2, solmate

## Build & Run
```bash
forge build           # Compile all contracts
forge test -v         # Run tests (247 pass, 9 fail without mainnet fork)
forge test --match-path "src/test/AlchemistV3.t.sol" -v  # Run specific test
```

## Key Contracts
- `AlchemistV3.sol` -- Core lending engine (Initializable proxy pattern, empty constructor + initialize)
- `AlchemistV3Position.sol` -- ERC721 NFT representing user positions (constructor takes alchemist address)
- `Transmuter.sol` -- Converts synthetic tokens to yield tokens over time (Fenwick tree / StakingGraph)
- `AlchemistETHVault.sol` -- ETH/WETH fee vault (constructor: weth, alchemist, owner)
- `AlchemistTokenVault.sol` -- ERC20 fee vault
- `AlchemistCurator.sol` -- Strategy cap management (constructor: admin, operator)
- `AlchemistAllocator.sol` -- Capital allocation to strategies (constructor: vault-v2, admin, operator)
- `AlchemistStrategyClassifier.sol` -- Risk class management (constructor: admin)
- `MYTStrategy.sol` -- Base strategy for MYT (multi-yield token) adapters
- `PerpetualGauge.sol` -- Governance gauge for strategy weight voting

## Constructor Signatures (critical for deployment)
- `AlchemistV3()` -- empty, then call `initialize(AlchemistInitializationParams)`
- `AlchemistV3Position(address alchemist_)`
- `Transmuter(ITransmuter.TransmuterInitializationParams memory params)`
- `AlchemistETHVault(address _weth, address _alchemist, address _owner)`
- `AlchemistCurator(address _admin, address _operator)` via PermissionedProxy
- `AlchemistAllocator(address _vault, address _admin, address _operator)` via PermissionedProxy
- `AlchemistStrategyClassifier(address _admin)`

## Deployment Order
1. Deploy AlchemistV3 (empty constructor)
2. Deploy AlchemistV3Position (needs alchemist address)
3. Deploy Transmuter (needs debt token address)
4. Deploy AlchemistETHVault (needs WLUX + alchemist address)
5. Call alchemist.initialize(params) with transmuter address
6. Call alchemist.setAlchemistPositionNFT(position)
7. Call transmuter.setAlchemist(alchemist)
8. Whitelist alchemist as minter on debt token (LETH)

## Canonical Lux Addresses
- LETH: `0x60E0a8167FC13dE89348978860466C9ceC24B9ba`
- WLUX: `0x4888E4a2Ee0F03051c72D2BD3ACf755eD3498B3E`
- LBTC: `0x1E48D32a4F5e9f08DB9aE4959163300FaF8A6C8e`

## Test Failures (pre-existing)
- Strategy fork tests (SfrxETH, MorphoYearnOGWETH, PeapodsETH, TokeAutoETH) -- need MAINNET_RPC_URL
- IntegrationTest -- needs Ethereum mainnet fork
- PerpetualGauge (2 tests) -- logic bugs in cap application and vote aggregation
- MockERC20 IERC20 compliance -- mock doesn't implement full interface
- AlchemistETHVault testDepositWETH -- mock WETH incomplete

## Scripts
- `script/DeployLux.s.sol` -- Multi-network deploy (LUX/Zoo/Hanzo)
- `script/DeployMainnet.s.sol` -- Lux mainnet ETH deployment with canonical addresses

## Structure
```
src/
  AlchemistV3.sol, AlchemistV3Position.sol, Transmuter.sol
  AlchemistETHVault.sol, AlchemistTokenVault.sol
  AlchemistCurator.sol, AlchemistAllocator.sol
  AlchemistStrategyClassifier.sol, MYTStrategy.sol, PerpetualGauge.sol
  adapters/       -- AbstractFeeVault, EulerUSDCAdapter
  base/           -- Errors, ErrorMessages, TransmuterErrors
  external/       -- AlEth token, IDetailedERC20, ISettlerActions
  governance/     -- LiquidGovernor, LiquidToken
  interfaces/     -- All interfaces
  libraries/      -- FixedPointMath, SafeCast, SafeERC20, TokenUtils, StakingGraph, etc.
  mocks/          -- ERC20Mock, Pool, Stake, StakingPoolMock
  strategies/     -- EETH, SfrxETH, WstethMainnet, PeapodsETH, etc.
  test/           -- All test files
  tokens/         -- (empty)
  utils/          -- PermissionedProxy, Whitelist, ZeroXSwapVerifier
script/
  DeployLux.s.sol, DeployMainnet.s.sol
lib/
  forge-std, openzeppelin-contracts, openzeppelin-contracts-upgradeable
  vault-v2, permit2, solmate, chainlink-brownie-contracts, halmos-cheatcodes
```
