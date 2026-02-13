// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AlchemistV3} from "../src/AlchemistV3.sol";
import {AlchemistV3Position} from "../src/AlchemistV3Position.sol";
import {Transmuter} from "../src/Transmuter.sol";
import {AlchemistETHVault} from "../src/AlchemistETHVault.sol";
import {AlchemistTokenVault} from "../src/AlchemistTokenVault.sol";
import {AlchemistCurator} from "../src/AlchemistCurator.sol";
import {AlchemistAllocator} from "../src/AlchemistAllocator.sol";
import {AlchemistStrategyClassifier} from "../src/AlchemistStrategyClassifier.sol";
import {MYTStrategy} from "../src/MYTStrategy.sol";
import {IAlchemistV3, AlchemistInitializationParams} from "../src/interfaces/IAlchemistV3.sol";
import {ITransmuter} from "../src/interfaces/ITransmuter.sol";

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
        address alchemist;
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
        address yieldToken = address(0); // MYT yield token address

        DeploymentConfig memory config = DeploymentConfig({
            admin: deployer,
            debtToken: address(0), // Will be deployed
            underlyingToken: wlux,
            yieldToken: yieldToken,
            tokenAdapter: address(0), // Will be deployed
            protocolFeeReceiver: deployer,
            debtTokenName: "Alchemix LUX",
            debtTokenSymbol: "alLUX"
        });

        _deployFullStack(config);
    }

    function deployZooNetwork(address deployer) internal {
        console.log("\n=== Deploying to Zoo Network ===");

        address wzoo = address(0); // WZOO address
        address yieldToken = address(0); // MYT yield token address

        DeploymentConfig memory config = DeploymentConfig({
            admin: deployer,
            debtToken: address(0),
            underlyingToken: wzoo,
            yieldToken: yieldToken,
            tokenAdapter: address(0),
            protocolFeeReceiver: deployer,
            debtTokenName: "Alchemix ZOO",
            debtTokenSymbol: "alZOO"
        });

        _deployFullStack(config);
    }

    function deployHanzoNetwork(address deployer) internal {
        console.log("\n=== Deploying to Hanzo Network ===");

        address whanzo = address(0); // WHANZO address
        address yieldToken = address(0); // MYT yield token address

        DeploymentConfig memory config = DeploymentConfig({
            admin: deployer,
            debtToken: address(0),
            underlyingToken: whanzo,
            yieldToken: yieldToken,
            tokenAdapter: address(0),
            protocolFeeReceiver: deployer,
            debtTokenName: "Alchemix HANZO",
            debtTokenSymbol: "alHANZO"
        });

        _deployFullStack(config);
    }

    function _deployFullStack(DeploymentConfig memory config) internal returns (DeployedContracts memory deployed) {
        // 1. Deploy Strategy Classifier
        console.log("Deploying AlchemistStrategyClassifier...");
        AlchemistStrategyClassifier classifier = new AlchemistStrategyClassifier(config.admin);
        deployed.classifier = address(classifier);
        console.log("  AlchemistStrategyClassifier:", deployed.classifier);

        // 2. Deploy Curator
        console.log("Deploying AlchemistCurator...");
        AlchemistCurator curator = new AlchemistCurator(config.admin);
        deployed.curator = address(curator);
        console.log("  AlchemistCurator:", deployed.curator);

        // 3. Deploy Allocator
        console.log("Deploying AlchemistAllocator...");
        AlchemistAllocator allocator = new AlchemistAllocator(config.admin);
        deployed.allocator = address(allocator);
        console.log("  AlchemistAllocator:", deployed.allocator);

        // 4. Deploy Vault (ETH or Token based on underlying)
        console.log("Deploying AlchemistETHVault...");
        AlchemistETHVault vault = new AlchemistETHVault(
            config.underlyingToken,
            config.admin,
            deployed.curator,
            deployed.allocator
        );
        deployed.vault = address(vault);
        console.log("  AlchemistETHVault:", deployed.vault);

        // 5. Deploy Position NFT
        console.log("Deploying AlchemistV3Position...");
        AlchemistV3Position position = new AlchemistV3Position("Liquid V3 Position", "LIQ-V3-POS");
        deployed.position = address(position);
        console.log("  AlchemistV3Position:", deployed.position);

        // 6. Deploy Transmuter
        console.log("Deploying Transmuter...");
        ITransmuter.TransmuterInitializationParams memory transmuterParams = ITransmuter.TransmuterInitializationParams({
            syntheticToken: config.debtToken, // Will need to be set after alchemist deployment
            feeReceiver: config.protocolFeeReceiver,
            timeToTransmute: DEFAULT_TIME_TO_TRANSMUTE,
            transmutationFee: DEFAULT_TRANSMUTATION_FEE,
            exitFee: DEFAULT_EXIT_FEE,
            graphSize: DEFAULT_GRAPH_SIZE
        });

        // Note: Transmuter deployment requires the synthetic token address
        // This would be updated after the debt token is deployed
        console.log("  Transmuter params configured (deploy after debt token)");

        // 7. Deploy Alchemist V3
        console.log("Deploying AlchemistV3...");
        AlchemistInitializationParams memory alchemistParams = AlchemistInitializationParams({
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
            transmuter: address(0), // Will be set after transmuter deployment
            protocolFee: DEFAULT_PROTOCOL_FEE,
            protocolFeeReceiver: config.protocolFeeReceiver,
            liquidatorFee: DEFAULT_LIQUIDATOR_FEE,
            repaymentFee: DEFAULT_REPAYMENT_FEE
        });

        AlchemistV3 alchemist = new AlchemistV3(alchemistParams);
        deployed.alchemist = address(alchemist);
        console.log("  AlchemistV3:", deployed.alchemist);

        // Log deployment summary
        console.log("\n=== Deployment Summary ===");
        console.log("AlchemistV3:", deployed.alchemist);
        console.log("AlchemistV3Position:", deployed.position);
        console.log("AlchemistETHVault:", deployed.vault);
        console.log("AlchemistCurator:", deployed.curator);
        console.log("AlchemistAllocator:", deployed.allocator);
        console.log("AlchemistStrategyClassifier:", deployed.classifier);

        return deployed;
    }

    /// @notice Deploy only the MYT strategy contracts
    function deployStrategies() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        console.log("\n=== Deploying MYT Strategies ===");

        // Strategy deployment would go here
        // Each strategy (EETH, SfrxETH, etc.) would be deployed
        // and registered with the Curator

        vm.stopBroadcast();
    }
}
