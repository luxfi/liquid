// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {PermissionedProxy} from "./utils/PermissionedProxy.sol";

contract AlchemistAllocator is PermissionedProxy {
    IVaultV2 immutable vault;

    constructor(address _vault, address _admin, address _operator)  PermissionedProxy(_admin, _operator) {
        require(IVaultV2(_vault).asset() != address(0), "IV");
        vault = IVaultV2(_vault);

        // allocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x5c9ce04d] = true;
        // deallocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x4b219d16] = true;
    }

    event Allocate(address indexed vault, uint256 indexed amount, address adapter);
    event Deallocate(address indexed vault, uint256 indexed amount, address adapter);

    // Overriden vault actions
    function allocate(bytes32 id, address adapter, bytes memory data, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        uint256 absoluteCap = vault.absoluteCap(id);
        uint256 relativeCap = vault.relativeCap(id);
        // FIXME get this from the StrategyClassificationProxy for the respective risk class
        uint256 daoTarget = type(uint256).max;

        uint256 adjusted = absoluteCap > relativeCap ? absoluteCap : relativeCap;
        if (msg.sender != admin) { // caller is operator
            adjusted = adjusted > daoTarget ? adjusted : daoTarget;
        }

        vault.allocate(adapter, data, amount);
        emit Allocate(address(vault), amount, adapter);
    }

    function deallocate(bytes32 id, address adapter, bytes memory data, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        uint256 absoluteCap = vault.absoluteCap(id);
        uint256 relativeCap = vault.relativeCap(id);
        // FIXME get this from the StrategyClassificationProxy for the respective risk class
        uint256 daoTarget = type(uint256).max;

        uint256 adjusted = absoluteCap < relativeCap ? absoluteCap : relativeCap;

        if (msg.sender != admin) { // caller is operator
            adjusted = adjusted < daoTarget ? adjusted : daoTarget;
        }

        vault.deallocate(adapter, data, amount);
        emit Deallocate(address(vault), amount, adapter);
    }


}
