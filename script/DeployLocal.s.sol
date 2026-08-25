// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Liquid} from "../src/Liquid.sol";
import {LiquidPosition} from "../src/LiquidPosition.sol";
import {LiquidTransmuter} from "../src/LiquidTransmuter.sol";
import {LiquidETHVault} from "../src/LiquidETHVault.sol";
import {LiquidTokenVault} from "../src/LiquidTokenVault.sol";
import {LiquidCurator} from "../src/LiquidCurator.sol";
import {LiquidStrategyClassifier} from "../src/LiquidStrategyClassifier.sol";
import {LiquidCompliance} from "../src/LiquidCompliance.sol";
import {SecurityTokenAdapter} from "../src/adapters/SecurityTokenAdapter.sol";
import {ILiquid, LiquidInitializationParams} from "../src/interfaces/ILiquid.sol";
import {ILiquidTransmuter} from "../src/interfaces/ILiquidTransmuter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @dev Minimal ERC-20 for local dev tokens (WLUX, LLUX, mock securities)
contract DevToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint256 _premint) {
        name = _name;
        symbol = _symbol;
        if (_premint > 0) _mint(msg.sender, _premint);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return transferFrom(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }
}

/// @title DeployLocal — full Liquid stack on local dev node
contract DeployLocal is Script {
    uint256 constant BLOCKS_PER_YEAR = 15_768_000;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        console.log("=== Deploying Liquid Protocol (local dev) ===");
        console.log("Deployer:", deployer);

        // 1. Deploy tokens
        DevToken wlux = new DevToken("Wrapped LUX", "WLUX", 0);
        console.log("WLUX:", address(wlux));

        // The market's synthetic. It denominates the same asset as the
        // collateral -- LUX against wrapped LUX -- because the engine converts
        // underlying to debt with a decimals scalar and no price source. A
        // dollar-denominated synthetic against LUX collateral would be a market
        // the engine cannot value.
        DevToken llux = new DevToken("Liquid LUX", "LLUX", 1_000_000 ether);
        console.log("LLUX:", address(llux));

        DevToken ibit = new DevToken("iShares Bitcoin ETF", "IBIT", 100_000 ether);
        console.log("IBIT (mock):", address(ibit));

        // 2. Deploy Liquid core
        LiquidStrategyClassifier classifier = new LiquidStrategyClassifier(deployer);
        console.log("Classifier:", address(classifier));

        Liquid liquidImpl = new Liquid();
        ERC1967Proxy liquidProxy = new ERC1967Proxy(address(liquidImpl), "");
        Liquid liquid = Liquid(address(liquidProxy));
        console.log("Liquid (proxy):", address(liquid));

        LiquidCurator curator = new LiquidCurator(deployer, deployer);
        console.log("Curator:", address(curator));

        LiquidETHVault vault = new LiquidETHVault(address(wlux), address(liquid), deployer);
        console.log("ETHVault:", address(vault));

        LiquidPosition position = new LiquidPosition(address(liquid));
        console.log("Position:", address(position));

        // 3. Deploy Transmuter with LLUX as synthetic token
        ILiquidTransmuter.TransmuterInitializationParams memory tParams = ILiquidTransmuter.TransmuterInitializationParams({
            syntheticToken: address(llux), feeReceiver: deployer, timeToTransmute: 45 days, transmutationFee: 0.005e18, exitFee: 0.02e18, graphSize: 1000
        });
        LiquidTransmuter transmuter = new LiquidTransmuter(tParams);
        console.log("Transmuter:", address(transmuter));

        // 4. Fee vault. It holds the market's underlying token: the liquidator
        //    bonus is denominated in underlying, and Liquid rejects a vault
        //    whose token does not match.
        LiquidTokenVault tokenVault = new LiquidTokenVault(address(wlux), address(liquid), deployer);
        console.log("TokenVault:", address(tokenVault));

        // 5. Deploy WLUX adapter (simple 1:1 price)
        SecurityTokenAdapter wluxAdapter = new SecurityTokenAdapter(address(wlux), "LUX", "", "", "native", 1e18);
        console.log("WLUX Adapter:", address(wluxAdapter));

        // 6. Initialize Liquid
        console.log("Initializing Liquid...");
        LiquidInitializationParams memory initParams = LiquidInitializationParams({
            admin: deployer,
            debtToken: address(llux),
            underlyingToken: address(wlux),
            yieldToken: address(wlux),
            depositCap: 10_000_000 ether,
            blocksPerYear: BLOCKS_PER_YEAR,
            minimumCollateralization: 1.1111e18,
            // Both floors sit below the mint bar: a global floor above it marks a
            // fully-drawn healthy protocol insolvent and forces full seizure.
            globalMinimumCollateralization: 1.0526e18,
            collateralizationLowerBound: 1.05e18,
            tokenAdapter: address(wluxAdapter),
            // Freezes price movement within a block; 1 BPS/block elapsed thereafter.
            maxPriceDeviation: 1,
            transmuter: address(transmuter),
            protocolFee: 1000, // 10% in BPS
            protocolFeeReceiver: deployer,
            liquidatorFee: 500, // 5% in BPS
            repaymentFee: 100 // 1% in BPS
        });
        liquid.initialize(initParams);
        liquid.setLiquidPositionNFT(address(position));
        // Liquidation survives an unset fee vault; the incentive to perform one
        // on a deeply underwater position does not. Seed it to exercise that path.
        liquid.setLiquidFeeVault(address(tokenVault));
        console.log("Liquid initialized + Position NFT and fee vault set");

        // 7. Deploy SecurityTokenAdapter for IBIT
        SecurityTokenAdapter ibitAdapter = new SecurityTokenAdapter(address(ibit), "IBIT", "46438F101", "US46438F1012", "ETF", 52.34e18);
        console.log("IBIT Adapter:", address(ibitAdapter));

        // 8. Deploy ComplianceGate
        LiquidCompliance gate = new LiquidCompliance(deployer);
        console.log("ComplianceGate:", address(gate));

        // Compliance is now delegated to ERC-3643 IIdentityRegistry +
        // ONCHAINID claim topics, configured per-vault via:
        //   gate.setVaultRegistry(vault, identityRegistry)
        //   gate.setRequiredTopics(vault, [topicId, ...])
        //   gate.setCountryBlock(vault, countryCode, true)
        // Local dev leaves vaults unconfigured; canRedeem returns false
        // until an Identity Registry is wired up.

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("Chain ID: 1337 (local dev)");
    }
}
