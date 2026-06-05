// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidPosition} from "../src/LiquidPosition.sol";
import {LiquidTransmuter} from "../src/LiquidTransmuter.sol";
import {LiquidETHVault} from "../src/LiquidETHVault.sol";
import {LiquidCurator} from "../src/LiquidCurator.sol";
import {LiquidStrategyClassifier} from "../src/LiquidStrategyClassifier.sol";
import {ILiquid, LiquidInitializationParams} from "../src/interfaces/ILiquid.sol";
import {ILiquidTransmuter} from "../src/interfaces/ILiquidTransmuter.sol";

/**
 * @title DeployBrandL1
 * @notice Deploy core Liquid stack on any brand L1 EVM (devnet/testnet/mainnet).
 *
 * Parameterized over WLUX/LETH/LBTC addresses so the script is brand-agnostic.
 * Strategies are NOT deployed here — they require third-party protocol addresses
 * (Aave V3 pools, Lido stETH, Curve gauges, etc.) that do not exist on fresh
 * brand L1s. Strategy deployment is a follow-up task gated on bridge live-ness.
 *
 * Inputs (env):
 *   LUX_PRIVATE_KEY   Deployer hex private key (preferred for devnet/CI).
 *   LUX_MNEMONIC      BIP39 mnemonic + LUX_DEPLOYER_IDX (fallback).
 *   BRAND             Brand name (for log/manifest), e.g. "hanzo".
 *   LIQUID_ENV        Env name ("devnet"/"testnet"/"mainnet").
 *   WLUX_ADDRESS      Underlying wrapped-native token (required).
 *   LETH_ADDRESS      Synthetic debt token (LETH for ETH basket) (required).
 *   LBTC_ADDRESS      Reserved for BTC basket — currently logged-only.
 *
 * Outputs: console-logged deployment addresses. The caller writes them into
 * deployments/brand-l1-<env>/<brand>.json under .contracts.Liquid.* fields.
 */
contract DeployBrandL1 is Script {
    uint256 constant BLOCKS_PER_YEAR = 15_768_000; // ~2s block time
    uint256 constant DEPOSIT_CAP = 10_000_000 ether;
    uint256 constant MIN_COLLATERALIZATION = 1.1111e18; // 90% LTV
    uint256 constant GLOBAL_MIN_COLLATERALIZATION = 1.15e18;
    uint256 constant COLLATERALIZATION_LOWER_BOUND = 1.05e18;
    uint256 constant PROTOCOL_FEE = 1000; // 10% in BPS
    uint256 constant LIQUIDATOR_FEE = 500; // 5% in BPS
    uint256 constant REPAYMENT_FEE = 100; // 1% in BPS
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
        address wlux = vm.envAddress("WLUX_ADDRESS");
        address leth = vm.envAddress("LETH_ADDRESS");
        address lbtc = vm.envOr("LBTC_ADDRESS", address(0));

        require(wlux != address(0), "WLUX_ADDRESS required");
        require(leth != address(0), "LETH_ADDRESS required");

        console.log("=== DeployBrandL1 (Liquid core) ===");
        console.log("brand:", brand);
        console.log("env:", env_);
        console.log("chainId:", block.chainid);
        console.log("deployer:", deployer);
        console.log("WLUX:", wlux);
        console.log("LETH:", leth);
        console.log("LBTC:", lbtc);

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

        // 4. ETH vault (weth, liquid, owner)
        LiquidETHVault vault = new LiquidETHVault(wlux, deployed.liquid, deployer);
        deployed.vault = address(vault);
        console.log("LiquidETHVault:", deployed.vault);

        // 5. Position NFT (constructor: address liquid_)
        LiquidPosition position = new LiquidPosition(deployed.liquid);
        deployed.position = address(position);
        console.log("LiquidPosition:", deployed.position);

        // 6. Transmuter (LETH as synthetic, deployer as fee receiver)
        ILiquidTransmuter.TransmuterInitializationParams memory tParams = ILiquidTransmuter
            .TransmuterInitializationParams({
                syntheticToken: leth,
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
            debtToken: leth,
            underlyingToken: wlux,
            yieldToken: wlux, // initially WLUX; rotate to vault yield token post-deploy
            depositCap: DEPOSIT_CAP,
            blocksPerYear: BLOCKS_PER_YEAR,
            minimumCollateralization: MIN_COLLATERALIZATION,
            globalMinimumCollateralization: GLOBAL_MIN_COLLATERALIZATION,
            collateralizationLowerBound: COLLATERALIZATION_LOWER_BOUND,
            tokenAdapter: address(0), // set after adapter deployment (post-launch)
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

        vm.stopBroadcast();

        console.log("=== Liquid core deployed ===");
        console.log("Liquid:        ", deployed.liquid);
        console.log("LiquidPosition:", deployed.position);
        console.log("Transmuter:    ", deployed.transmuter);
        console.log("ETHVault:      ", deployed.vault);
        console.log("Curator:       ", deployed.curator);
        console.log("Classifier:    ", deployed.classifier);
    }
}
