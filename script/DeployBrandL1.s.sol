// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidPosition} from "../src/LiquidPosition.sol";
import {LiquidTransmuter} from "../src/LiquidTransmuter.sol";
import {LiquidTokenVault} from "../src/LiquidTokenVault.sol";
import {LiquidCurator} from "../src/LiquidCurator.sol";
import {LiquidStrategyClassifier} from "../src/LiquidStrategyClassifier.sol";
import {ILiquid, LiquidInitializationParams} from "../src/interfaces/ILiquid.sol";
import {ILiquidTransmuter} from "../src/interfaces/ILiquidTransmuter.sol";

/**
 * @title DeployBrandL1
 * @notice Deploy core Liquid stack on any brand L1 EVM (devnet/testnet/mainnet).
 *
 * Parameterized over one market's addresses so the script is brand-agnostic.
 * Strategies are NOT deployed here — they require third-party protocol addresses
 * (Aave V3 pools, Lido stETH, Curve gauges, etc.) that do not exist on fresh
 * brand L1s. Strategy deployment is a follow-up task gated on bridge live-ness.
 *
 * One run deploys one market, and a market is like-kind: the debt token and the
 * underlying token denominate the same asset. The engine converts between them
 * with a decimals scalar and holds no cross-asset price source, so bridged ETH
 * backs LETH and bridged BTC backs LBTC. Pairing a synthetic against an
 * unrelated collateral would let a borrower mint against value the engine
 * cannot see. To bring up several markets, run this once per market.
 *
 * Inputs (env):
 *   LUX_PRIVATE_KEY   Deployer hex private key (preferred for devnet/CI).
 *   LUX_MNEMONIC      BIP39 mnemonic + LUX_DEPLOYER_IDX (fallback).
 *   BRAND             Brand name (for log/manifest), e.g. "hanzo".
 *   LIQUID_ENV        Env name ("devnet"/"testnet"/"mainnet").
 *   DEBT_ADDRESS      Synthetic debt token — LETH, LBTC, LLUX (required).
 *   UNDERLYING_ADDRESS  Asset the debt denominates: bridged ETH, BTC, WLUX (required).
 *   YIELD_ADDRESS     Yield-bearing wrapper deposited as collateral (required).
 *   TOKEN_ADAPTER_ADDRESS  Adapter pricing yield in underlying (required).
 *
 * Outputs: console-logged deployment addresses. The caller writes them into
 * deployments/brand-l1-<env>/<brand>.json under .contracts.Liquid.* fields.
 */
contract DeployBrandL1 is Script {
    uint256 constant BLOCKS_PER_YEAR = 15_768_000; // ~2s block time
    uint256 constant DEPOSIT_CAP = 10_000_000 ether;
    uint256 constant MIN_COLLATERALIZATION = 1.1111e18; // 90% LTV

    // Both floors sit below the mint bar. At full utilisation every borrower is
    // drawn to MIN_COLLATERALIZATION and the protocol-wide ratio equals it, so a
    // global floor at or above the bar marks a healthy protocol insolvent and
    // routes every liquidation through full seizure.
    uint256 constant GLOBAL_MIN_COLLATERALIZATION = 1.0526e18;
    uint256 constant COLLATERALIZATION_LOWER_BOUND = 1.05e18;
    uint256 constant PROTOCOL_FEE = 1000; // 10% in BPS
    uint256 constant LIQUIDATOR_FEE = 500; // 5% in BPS
    uint256 constant REPAYMENT_FEE = 100; // 1% in BPS

    // How far the adapter may move the engine's price, in BPS per block
    // elapsed. Bounds how fast a compromised adapter can shift borrowing
    // power, and freezes it entirely within a single block.
    uint256 constant MAX_PRICE_DEVIATION = 1;
    uint256 constant TIME_TO_TRANSMUTE = 45 days; // ~90 days at 2s
    uint256 constant TRANSMUTATION_FEE = 50; // 0.5% in BPS
    uint256 constant EXIT_FEE = 200; // 2% in BPS
    uint256 constant GRAPH_SIZE = 1000;

    struct Deployed {
        address liquid;
        address position;
        address transmuter;
        address vault;
        address curator;
        address classifier;
    }

    function run() external returns (Deployed memory deployed) {
        uint256 deployerKey;
        try vm.envUint("LUX_PRIVATE_KEY") returns (uint256 pk) {
            deployerKey = pk;
        } catch {
            string memory mnemonic = vm.envString("LUX_MNEMONIC");
            require(bytes(mnemonic).length > 0, "LUX_PRIVATE_KEY or LUX_MNEMONIC required");
            uint256 deployerIdx = vm.envOr("LUX_DEPLOYER_IDX", uint256(0));
            deployerKey = vm.deriveKey(mnemonic, uint32(deployerIdx));
        }
        address deployer = vm.addr(deployerKey);

        string memory brand = vm.envOr("BRAND", string("default"));
        string memory env_ = vm.envOr("LIQUID_ENV", string("devnet"));
        address debt = vm.envAddress("DEBT_ADDRESS");
        address underlying = vm.envAddress("UNDERLYING_ADDRESS");
        address yield_ = vm.envAddress("YIELD_ADDRESS");
        address adapter = vm.envAddress("TOKEN_ADAPTER_ADDRESS");

        require(debt != address(0), "DEBT_ADDRESS required");
        require(underlying != address(0), "UNDERLYING_ADDRESS required");
        require(yield_ != address(0), "YIELD_ADDRESS required");
        require(adapter != address(0), "TOKEN_ADAPTER_ADDRESS required");

        console.log("=== DeployBrandL1 (Liquid core) ===");
        console.log("brand:", brand);
        console.log("env:", env_);
        console.log("chainId:", block.chainid);
        console.log("deployer:", deployer);
        console.log("debt token:", debt);
        console.log("underlying:", underlying);
        console.log("yield token:", yield_);
        console.log("token adapter:", adapter);

        vm.startBroadcast(deployerKey);

        // 1. Strategy classifier
        LiquidStrategyClassifier classifier = new LiquidStrategyClassifier(deployer);
        deployed.classifier = address(classifier);
        console.log("LiquidStrategyClassifier:", deployed.classifier);

        // 2. Liquid (empty constructor; uses initialize pattern)
        Liquid liquid = new Liquid();
        deployed.liquid = address(liquid);
        console.log("Liquid:", deployed.liquid);

        // 3. Curator (admin, operator)
        LiquidCurator curator = new LiquidCurator(deployer, deployer);
        deployed.curator = address(curator);
        console.log("LiquidCurator:", deployed.curator);

        // 4. Fee vault. It must hold the market's underlying token: the
        //    liquidator bonus is denominated in underlying, and Liquid checks
        //    the vault's token matches before accepting it.
        LiquidTokenVault vault = new LiquidTokenVault(underlying, deployed.liquid, deployer);
        deployed.vault = address(vault);
        console.log("LiquidTokenVault:", deployed.vault);

        // 5. Position NFT (constructor: address liquid_)
        LiquidPosition position = new LiquidPosition(deployed.liquid);
        deployed.position = address(position);
        console.log("LiquidPosition:", deployed.position);

        // 6. Transmuter (the market's own synthetic, deployer as fee receiver)
        ILiquidTransmuter.TransmuterInitializationParams memory tParams = ILiquidTransmuter
            .TransmuterInitializationParams({
                syntheticToken: debt,
                feeReceiver: deployer,
                timeToTransmute: TIME_TO_TRANSMUTE,
                transmutationFee: TRANSMUTATION_FEE,
                exitFee: EXIT_FEE,
                graphSize: GRAPH_SIZE
            });
        LiquidTransmuter transmuter = new LiquidTransmuter(tParams);
        deployed.transmuter = address(transmuter);
        console.log("LiquidTransmuter:", deployed.transmuter);

        // 7. Initialize Liquid
        LiquidInitializationParams memory params = LiquidInitializationParams({
            admin: deployer,
            debtToken: debt,
            underlyingToken: underlying,
            yieldToken: yield_,
            depositCap: DEPOSIT_CAP,
            blocksPerYear: BLOCKS_PER_YEAR,
            minimumCollateralization: MIN_COLLATERALIZATION,
            globalMinimumCollateralization: GLOBAL_MIN_COLLATERALIZATION,
            collateralizationLowerBound: COLLATERALIZATION_LOWER_BOUND,
            tokenAdapter: adapter,
            maxPriceDeviation: MAX_PRICE_DEVIATION,
            transmuter: deployed.transmuter,
            protocolFee: PROTOCOL_FEE,
            protocolFeeReceiver: deployer,
            liquidatorFee: LIQUIDATOR_FEE,
            repaymentFee: REPAYMENT_FEE
        });
        liquid.initialize(params);
        console.log("Liquid initialized");

        // 8. Wire Position NFT into Liquid
        liquid.setLiquidPositionNFT(deployed.position);
        console.log("Position NFT set on Liquid");

        // 9. Wire Liquid into Transmuter
        transmuter.setLiquid(deployed.liquid);
        console.log("Liquid set on Transmuter");

        // 10. Point Liquid at the fee vault. Liquidation survives an unset
        //     vault; the incentive to perform one on a deeply underwater
        //     position does not. Seed it with underlying before going live.
        liquid.setLiquidFeeVault(deployed.vault);
        console.log("Fee vault set on Liquid");

        vm.stopBroadcast();

        console.log("=== Liquid core deployed ===");
        console.log("Liquid:        ", deployed.liquid);
        console.log("LiquidPosition:", deployed.position);
        console.log("Transmuter:    ", deployed.transmuter);
        console.log("FeeVault:      ", deployed.vault);
        console.log("Curator:       ", deployed.curator);
        console.log("Classifier:    ", deployed.classifier);
    }
}
