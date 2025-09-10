// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVaultV2} from "../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {PermissionedProxy} from "../utils/PermissionedProxy.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IMYTVault} from "./interfaces/IMYTVault.sol";
import {IMYTAdapter} from "./MYTAdapter.sol";

interface IMYTAllocator {
    function allocate(address adapter, uint256 amount) external;
    function deallocate(address adapter, uint256 amount) external;
}

// Only MYT Vault Allocator may call allocate and deallocate on the MYT Vault
// The MYT vault is just a Morpho V2 Vault
contract MYTAllocator is PermissionedProxy, IMYTAllocator {
    IVaultV2 immutable mytVault;

    event IncreaseAbsoluteCap(address indexed strategy, uint256 amount, bytes indexed id);
    event IncreaseRelativeCap(address indexed strategy, uint256 amount, bytes indexed id);

    event MYTAllocatorDebugLog(string message, uint256 amount);

    constructor(address _vault, address _admin, address _operator) PermissionedProxy(_admin, _operator) {
        require(IVaultV2(_vault).asset() != address(0), "IV");
        mytVault = IVaultV2(_vault);

        // allocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x5c9ce04d] = true;
        // deallocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x4b219d16] = true;
    }

    // Overriden vault actions
    function allocate(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        bytes32 id = IMYTAdapter(adapter).adapterId();

        uint256 absoluteCap = mytVault.absoluteCap(id);
        uint256 relativeCap = mytVault.relativeCap(id);
        // FIXME get this from the StrategyClassificationProxy for the respective risk class
        uint256 daoTarget = type(uint256).max;
        uint256 adjusted = absoluteCap > relativeCap ? absoluteCap : relativeCap;
        if (msg.sender != admin) {
            // caller is operator
            adjusted = adjusted > daoTarget ? adjusted : daoTarget;
        }
        // pass the old allocation to the adapter
        bytes memory oldAllocation = abi.encode(mytVault.allocation(id));
        mytVault.allocate(adapter, oldAllocation, amount);
    }

    function deallocate(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        bytes32 id = IMYTAdapter(adapter).adapterId();

        uint256 absoluteCap = mytVault.absoluteCap(id);
        uint256 relativeCap = mytVault.relativeCap(id);
        // FIXME get this from the StrategyClassificationProxy for the respective risk class
        uint256 daoTarget = type(uint256).max;
        uint256 adjusted = absoluteCap < relativeCap ? absoluteCap : relativeCap;
        if (msg.sender != admin) {
            // caller is operator
            adjusted = adjusted < daoTarget ? adjusted : daoTarget;
        }
        // pass the old allocation to the adapter
        bytes memory oldAllocation = abi.encode(mytVault.allocation(id));
        mytVault.deallocate(adapter, oldAllocation, amount);
    }

    function increaseAbsoluteCap(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        bytes memory id = IMYTAdapter(adapter).getIdData();
        _increaseAbsoluteCap(id, amount);
        emit IncreaseAbsoluteCap(adapter, amount, id);
    }

    function increaseRelativeCap(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        bytes memory id = IMYTAdapter(adapter).getIdData();
        _increaseRelativeCap(id, amount);
        emit IncreaseRelativeCap(adapter, amount, id);
    }

    function _increaseAbsoluteCap(bytes memory id, uint256 amount) internal {
        mytVault.increaseAbsoluteCap(id, amount);
    }

    function _increaseRelativeCap(bytes memory id, uint256 amount) internal {
        mytVault.increaseRelativeCap(id, amount);
    }

    function submitIncreaseAbsoluteCap(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        bytes memory id = IMYTAdapter(adapter).getIdData();
        _submitIncreaseAbsoluteCap(id, amount);
    }

    function submitIncreaseRelativeCap(address adapter, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        bytes memory id = IMYTAdapter(adapter).getIdData();
        _submitIncreaseRelativeCap(id, amount);
    }

    function _submitIncreaseAbsoluteCap(bytes memory id, uint256 amount) internal {
        bytes memory data = abi.encodeCall(IVaultV2.increaseAbsoluteCap, (id, amount));
        _vaultSubmit(data);
    }

    function _submitIncreaseRelativeCap(bytes memory id, uint256 amount) internal {
        bytes memory data = abi.encodeCall(IVaultV2.increaseRelativeCap, (id, amount));
        _vaultSubmit(data);
    }

    function _vaultSubmit(bytes memory data) internal {
        mytVault.submit(data);
        bytes4 selector = bytes4(data);
    }
}
