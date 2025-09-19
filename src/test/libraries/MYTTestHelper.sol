// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockMYTStrategy} from "../mocks/MockMYTStrategy.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {VaultV2} from "../../../lib/vault-v2/src/VaultV2.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IMYTStrategy} from "../../interfaces/IMYTStrategy.sol";

library MYTTestHelper {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _setupVault(address collateral, address admin, address curator) internal returns (VaultV2) {
        // create vault with collateral
        VaultV2 vault = new VaultV2(admin, collateral);
        // set curator
        vault.setCurator(curator);

        return vault;
    }

    function _setupStrategy(address myt, address yieldToken, address owner, string memory name, string memory protocol, IMYTStrategy.RiskClass riskClass)
        external
        returns (MockMYTStrategy)
    {
        IMYTStrategy.StrategyParams memory params = IMYTStrategy.StrategyParams({
            owner: owner,
            name: name,
            protocol: protocol,
            riskClass: riskClass,
            cap: 100 ether,
            globalCap: 100 ether,
            estimatedYield: 100 ether,
            additionalIncentives: false
        });
        return new MockMYTStrategy(myt, yieldToken, params);
    }
}
