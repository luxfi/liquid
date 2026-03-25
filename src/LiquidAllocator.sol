// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {PermissionedProxy} from "./utils/PermissionedProxy.sol";
import {ILiquidAllocator} from "./interfaces/ILiquidAllocator.sol";
import {ILiquidStrategy} from "./interfaces/ILiquidStrategy.sol";

contract LiquidAllocator is PermissionedProxy, ILiquidAllocator {
    IVaultV2 immutable vault;

    /// @notice Maximum allocation per strategy, configurable by admin
    uint256 public maxAllocationPerStrategy = 1e24; // 1M tokens default cap

    constructor(address _vault, address _admin, address _operator) PermissionedProxy(_admin, _operator) {
        require(IVaultV2(_vault).asset() != address(0), "IV");
        vault = IVaultV2(_vault);

        // allocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x5c9ce04d] = true;
        // deallocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x4b219d16] = true;
    }

    /// @notice Set the maximum allocation per strategy
    /// @param _cap The new cap value
    function setMaxAllocationPerStrategy(uint256 _cap) external {
        require(msg.sender == admin, "PD");
        require(_cap > 0, "Zero cap");
        maxAllocationPerStrategy = _cap;
    }

    // Overriden vault actions
    function allocate(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        require(amount <= maxAllocationPerStrategy, "Exceeds allocation cap");
        bytes32 id = ILiquidStrategy(adapter).adapterId();
        uint256 absoluteCap = vault.absoluteCap(id);
        uint256 relativeCap = vault.relativeCap(id);
        uint256 daoTarget = maxAllocationPerStrategy;
        uint256 adjusted = absoluteCap > relativeCap ? absoluteCap : relativeCap;
        if (msg.sender != admin) {
            // caller is operator
            adjusted = adjusted > daoTarget ? adjusted : daoTarget;
        }
        require(amount <= adjusted, "Exceeds vault cap");
        // pass the old allocation to the adapter
        bytes memory oldAllocation = abi.encode(vault.allocation(id));
        vault.allocate(adapter, oldAllocation, amount);
    }

    function deallocate(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        bytes32 id = ILiquidStrategy(adapter).adapterId();
        uint256 absoluteCap = vault.absoluteCap(id);
        uint256 relativeCap = vault.relativeCap(id);
        uint256 daoTarget = maxAllocationPerStrategy;
        uint256 adjusted = absoluteCap < relativeCap ? absoluteCap : relativeCap;
        if (msg.sender != admin) {
            // caller is operator
            adjusted = adjusted < daoTarget ? adjusted : daoTarget;
        }
        // pass the old allocation to the adapter
        bytes memory oldAllocation = abi.encode(vault.allocation(id));
        vault.deallocate(adapter, oldAllocation, amount);
    }
}
