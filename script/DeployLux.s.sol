// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidPosition} from "../src/LiquidPosition.sol";
import {LiquidTransmuter} from "../src/LiquidTransmuter.sol";
import {LiquidETHVault} from "../src/LiquidETHVault.sol";
import {LiquidTokenVault} from "../src/LiquidTokenVault.sol";
import {LiquidCurator} from "../src/LiquidCurator.sol";
// LiquidAllocator requires a vault-v2 (IVaultV2) address; deploy separately
// import {LiquidAllocator} from "../src/LiquidAllocator.sol";
import {LiquidStrategyClassifier} from "../src/LiquidStrategyClassifier.sol";
import {LiquidStrategy} from "../src/LiquidStrategy.sol";
import {ILiquid, LiquidInitializationParams} from "../src/interfaces/ILiquid.sol";
import {ILiquidTransmuter} from "../src/interfaces/ILiquidTransmuter.sol";

/// @title DeployLux
/// @notice Deployment script for Liquid V3 on Lux Network chains
/// @dev Supports LUX, Zoo, and Hanzo networks
contract DeployLux is Script {
    // Lux Network chain IDs
    uint256 constant LUX_MAINNET = 96369;
    uint256 constant LUX_TESTNET = 96368;
    uint256 constant ZOO_MAINNET = 200200;
    uint256 constant ZOO_TESTNET = 200201;
    uint256 constant HANZO_MAINNET = 36963;
    uint256 constant HANZO_TESTNET = 36962;

    // Blocks per year (approx 2s block time on Lux)
    uint256 constant BLOCKS_PER_YEAR = 15_768_000;

    // Default protocol parameters
    uint256 constant DEFAULT_DEPOSIT_CAP = 10_000_000 ether;
    uint256 constant DEFAULT_MIN_COLLATERALIZATION = 1.1111e18; // 90% LTV (100/90)
    uint256 constant DEFAULT_GLOBAL_MIN_COLLATERALIZATION = 1.15e18;
    uint256 constant DEFAULT_COLLATERALIZATION_LOWER_BOUND = 1.05e18;
    uint256 constant DEFAULT_PROTOCOL_FEE = 0.1e18; // 10%
    uint256 constant DEFAULT_LIQUIDATOR_FEE = 0.05e18; // 5%
    uint256 constant DEFAULT_REPAYMENT_FEE = 0.01e18; // 1%

    // Transmuter parameters
    uint256 constant DEFAULT_TIME_TO_TRANSMUTE = 90 days / 2; // ~90 days in blocks at 2s
    uint256 constant DEFAULT_TRANSMUTATION_FEE = 0.005e18; // 0.5%
    uint256 constant DEFAULT_EXIT_FEE = 0.02e18; // 2%
    uint256 constant DEFAULT_GRAPH_SIZE = 1000;

    struct DeploymentConfig {
        address admin;
        address debtToken;
        address underlyingToken;
        address yieldToken;
        address tokenAdapter;
        address protocolFeeReceiver;
        string debtTokenName;
        string debtTokenSymbol;
    }

    struct DeployedContracts {
        address liquid;
        address position;
        address transmuter;
        address vault;
        address curator;
        address allocator;
        address classifier;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Liquid V3 to Lux Network");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy based on network
        if (block.chainid == LUX_MAINNET || block.chainid == LUX_TESTNET) {
            deployLuxMainnet(deployer);
        } else if (block.chainid == ZOO_MAINNET || block.chainid == ZOO_TESTNET) {
            deployZooNetwork(deployer);
        } else if (block.chainid == HANZO_MAINNET || block.chainid == HANZO_TESTNET) {
            deployHanzoNetwork(deployer);
        } else {
            revert("Unsupported network");
        }

        vm.stopBroadcast();
    }

    function deployLuxMainnet(address deployer) internal {
        console.log("\n=== Deploying to Lux Network ===");

        // Note: These addresses need to be set for the actual deployment
        // For now, using placeholder addresses that would be replaced
        address wlux = address(0); // WLUX address
        address yieldToken = address(0); // VAULT yield token address

        DeploymentConfig memory config = DeploymentConfig({
            admin: deployer,
            debtToken: address(0), // Will be deployed
            underlyingToken: wlux,
            yieldToken: yieldToken,
            tokenAdapter: address(0), // Will be deployed
            protocolFeeReceiver: deployer,
            debtTokenName: "Lux Liquid LUX",
            debtTokenSymbol: "alLUX"
        });

        _deployFullStack(config);
    }

    function deployZooNetwork(address deployer) internal {
        console.log("\n=== Deploying to Zoo Network ===");

        address wzoo = address(0); // WZOO address
        address yieldToken = address(0); // VAULT yield token address

        DeploymentConfig memory config = DeploymentConfig({
            admin: deployer,
            debtToken: address(0),
            underlyingToken: wzoo,
            yieldToken: yieldToken,
            tokenAdapter: address(0),
            protocolFeeReceiver: deployer,
            debtTokenName: "Lux Liquid ZOO",
            debtTokenSymbol: "alZOO"
        });

        _deployFullStack(config);
    }

    function deployHanzoNetwork(address deployer) internal {
        console.log("\n=== Deploying to Hanzo Network ===");

        address whanzo = address(0); // WHANZO address
        address yieldToken = address(0); // VAULT yield token address

        DeploymentConfig memory config = DeploymentConfig({
            admin: deployer,
            debtToken: address(0),
            underlyingToken: whanzo,
            yieldToken: yieldToken,
            tokenAdapter: address(0),
            protocolFeeReceiver: deployer,
            debtTokenName: "Lux Liquid HANZO",
            debtTokenSymbol: "alHANZO"
        });

        _deployFullStack(config);
    }

    function _deployFullStack(DeploymentConfig memory config) internal returns (DeployedContracts memory deployed) {
        // 1. Deploy Strategy Classifier (constructor: address _admin)
        console.log("Deploying LiquidStrategyClassifier...");
        LiquidStrategyClassifier classifier = new LiquidStrategyClassifier(config.admin);
        deployed.classifier = address(classifier);
        console.log("  LiquidStrategyClassifier:", deployed.classifier);

        // 2. Deploy Liquid (empty constructor, uses initialize pattern)
        console.log("Deploying Liquid...");
        Liquid liquid = new Liquid();
        deployed.liquid = address(liquid);
        console.log("  Liquid:", deployed.liquid);

        // 3. Deploy Curator (constructor: address _admin, address _operator)
        console.log("Deploying LiquidCurator...");
        LiquidCurator curator = new LiquidCurator(config.admin, config.admin);
        deployed.curator = address(curator);
        console.log("  LiquidCurator:", deployed.curator);

        // 4. Deploy Vault (constructor: address _weth, address _liquid, address _owner)
        console.log("Deploying LiquidETHVault...");
        LiquidETHVault vault = new LiquidETHVault(
            config.underlyingToken,
            deployed.liquid,
            config.admin
        );
        deployed.vault = address(vault);
        console.log("  LiquidETHVault:", deployed.vault);

        // 5. Deploy Position NFT (constructor: address liquid_)
        console.log("Deploying LiquidPosition...");
        LiquidPosition position = new LiquidPosition(deployed.liquid);
        deployed.position = address(position);
        console.log("  LiquidPosition:", deployed.position);

        // 6. Deploy Transmuter
        console.log("Deploying LiquidTransmuter...");
        ILiquidTransmuter.TransmuterInitializationParams memory transmuterParams = ILiquidTransmuter.TransmuterInitializationParams({
            syntheticToken: config.debtToken,
            feeReceiver: config.protocolFeeReceiver,
            timeToTransmute: DEFAULT_TIME_TO_TRANSMUTE,
            transmutationFee: DEFAULT_TRANSMUTATION_FEE,
            exitFee: DEFAULT_EXIT_FEE,
            graphSize: DEFAULT_GRAPH_SIZE
        });
        LiquidTransmuter transmuter = new LiquidTransmuter(transmuterParams);
        deployed.transmuter = address(transmuter);
        console.log("  LiquidTransmuter:", deployed.transmuter);

        // 7. Initialize Liquid
        console.log("Initializing Liquid...");
        LiquidInitializationParams memory liquidParams = LiquidInitializationParams({
            admin: config.admin,
            debtToken: config.debtToken,
            underlyingToken: config.underlyingToken,
            yieldToken: config.yieldToken,
            depositCap: DEFAULT_DEPOSIT_CAP,
            blocksPerYear: BLOCKS_PER_YEAR,
            minimumCollateralization: DEFAULT_MIN_COLLATERALIZATION,
            globalMinimumCollateralization: DEFAULT_GLOBAL_MIN_COLLATERALIZATION,
            collateralizationLowerBound: DEFAULT_COLLATERALIZATION_LOWER_BOUND,
            tokenAdapter: config.tokenAdapter,
            transmuter: deployed.transmuter,
            protocolFee: DEFAULT_PROTOCOL_FEE,
            protocolFeeReceiver: config.protocolFeeReceiver,
            liquidatorFee: DEFAULT_LIQUIDATOR_FEE,
            repaymentFee: DEFAULT_REPAYMENT_FEE
        });
        liquid.initialize(liquidParams);
        console.log("  Liquid initialized");

        // 8. Set position NFT on liquid
        liquid.setLiquidPositionNFT(deployed.position);
        console.log("  LiquidPosition NFT set on Liquid");

        // 9. Set liquid on transmuter
        transmuter.setLiquid(deployed.liquid);
        console.log("  Liquid set on LiquidTransmuter");

        // Log deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("Liquid:", deployed.liquid);
        console.log("LiquidPosition:", deployed.position);
        console.log("LiquidTransmuter:", deployed.transmuter);
        console.log("LiquidETHVault:", deployed.vault);
        console.log("LiquidCurator:", deployed.curator);
        console.log("LiquidStrategyClassifier:", deployed.classifier);

        return deployed;
    }

    /// @notice Deploy only the Liquid strategy contracts
    function deployStrategies() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("\n=== Deploying Liquid Strategies ===");

        // Strategy deployment would go here
        // Each strategy (EETH, SfrxETH, etc.) would be deployed
        // and registered with the Curator

        vm.stopBroadcast();
    }
}
