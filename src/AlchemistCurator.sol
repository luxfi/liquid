// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {PermissionedProxy} from "./utils/PermissionedProxy.sol";

contract AlchemistCurator is PermissionedProxy {
    IVaultV2 immutable vault;
    // TODO connect StrategyClassificationProxy

    constructor(address _vault, address _admin, address _operator)  PermissionedProxy(_admin, _operator) {
        require(IVaultV2(_vault).asset() != address(0), "IV");
        vault = IVaultV2(_vault);

        // setIsAdapter(address account, bool newIsAdapter)

        //permissionedCalls[0xb332ebf2] = true;
    }
}
