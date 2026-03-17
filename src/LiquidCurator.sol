// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {PermissionedProxy} from "./utils/PermissionedProxy.sol";
import {ILiquidStrategy} from "./interfaces/ILiquidStrategy.sol";
import {ILiquidCurator} from "./interfaces/ILiquidCurator.sol";

// LiquidCurator is a Minimal contract that allows only the admin (e.g. DAO) to modify the absolute and relative caps of an vault strategy
contract LiquidCurator is ILiquidCurator, PermissionedProxy {
    // map of vault adapter(strategy) address to vault address
    mapping(address => address) public adapterToVault;

    address public operator;
    address public pendingOperator;
    address public pendingAdmin;
    address public pendingStrategy;

    constructor(address _admin, address _operator) PermissionedProxy(_admin, _operator) {}

    // ===== Admin Management =====
    function transferAdminOwnerShip(address _newAdmin) external onlyAdmin {
        pendingAdmin = _newAdmin;
    }

    function acceptAdminOwnership() external onlyAdmin {
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminChanged(admin);
    }

    function submitSetStrategy(address adapter, address vault) external onlyOperator {
        require(adapter != address(0), "INVALID_ADDRESS");
        require(vault != address(0), "INVALID_ADDRESS");
        _submitSetStrategy(adapter, vault);
    }

    function setStrategy(address adapter, address vault) external onlyOperator {
        require(adapter != address(0), "INVALID_ADDRESS");
        require(vault != address(0), "INVALID_ADDRESS");
        _setStrategy(adapter, vault, false);
    }

    function removeStrategy(address adapter, address vault) external onlyOperator {
        require(adapter != address(0), "INVALID_ADDRESS");
        require(vault != address(0), "INVALID_ADDRESS");
        _setStrategy(adapter, vault, true); // remove
    }

    function _submitSetStrategy(address adapter, address vault) internal {
        IVaultV2 vaultContract = IVaultV2(vault);
        bytes memory data = abi.encodeCall(IVaultV2.addAdapter, adapter);
        vaultContract.submit(data);
        emit SubmitSetStrategy(adapter, vault);
    }

    function _setStrategy(address adapter, address vault, bool remove) internal {
        adapterToVault[adapter] = vault;
        IVaultV2 vaultContract = _vault(adapter);
        if (remove) {
            vaultContract.removeAdapter(adapter);
        } else {
            vaultContract.addAdapter(adapter);
        }
        emit StrategySet(adapter, vault);
    }

    function decreaseAbsoluteCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = ILiquidStrategy(adapter).getIdData();
        _decreaseAbsoluteCap(adapter, id, amount);
    }

    function submitDecreaseAbsoluteCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = ILiquidStrategy(adapter).getIdData();
        _submitDecreaseAbsoluteCap(adapter, id, amount);
    }

    function decreaseRelativeCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = ILiquidStrategy(adapter).getIdData();
        _decreaseRelativeCap(adapter, id, amount);
    }

    function submitDecreaseRelativeCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = ILiquidStrategy(adapter).getIdData();
        _submitDecreaseRelativeCap(adapter, id, amount);
    }

    function _decreaseRelativeCap(address adapter, bytes memory id, uint256 amount) internal {
        IVaultV2 vault = _vault(adapter);
        vault.decreaseRelativeCap(id, amount);
        emit DecreaseRelativeCap(adapter, amount, id);
    }

    function _submitDecreaseRelativeCap(address adapter, bytes memory id, uint256 amount) internal {
        bytes memory data = abi.encodeCall(IVaultV2.decreaseRelativeCap, (id, amount));
        _vaultSubmit(adapter, data);
        emit SubmitDecreaseRelativeCap(adapter, amount, id);
    }

    function _submitDecreaseAbsoluteCap(address adapter, bytes memory id, uint256 amount) internal {
        bytes memory data = abi.encodeCall(IVaultV2.decreaseAbsoluteCap, (id, amount));
        _vaultSubmit(adapter, data);
        emit SubmitDecreaseAbsoluteCap(adapter, amount, id);
    }

    function _decreaseAbsoluteCap(address adapter, bytes memory id, uint256 amount) internal {
        IVaultV2 vault = _vault(adapter);
        vault.decreaseAbsoluteCap(id, amount);
        emit DecreaseAbsoluteCap(adapter, amount, id);
    }

    function increaseAbsoluteCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = ILiquidStrategy(adapter).getIdData();
        _increaseAbsoluteCap(adapter, id, amount);
    }

    function increaseRelativeCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = ILiquidStrategy(adapter).getIdData();
        _increaseRelativeCap(adapter, id, amount);
    }

    function submitIncreaseAbsoluteCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = ILiquidStrategy(adapter).getIdData();
        _submitIncreaseAbsoluteCap(adapter, id, amount);
    }

    function submitIncreaseRelativeCap(address adapter, uint256 amount) external onlyAdmin {
        bytes memory id = ILiquidStrategy(adapter).getIdData();
        _submitIncreaseRelativeCap(adapter, id, amount);
    }

    function _increaseAbsoluteCap(address adapter, bytes memory id, uint256 amount) internal {
        IVaultV2 vault = _vault(adapter);
        vault.increaseAbsoluteCap(id, amount);
        emit IncreaseAbsoluteCap(adapter, amount, id);
    }

    function _increaseRelativeCap(address adapter, bytes memory id, uint256 amount) internal {
        IVaultV2 vault = _vault(adapter);
        vault.increaseRelativeCap(id, amount);
        emit IncreaseRelativeCap(adapter, amount, id);
    }

    function _submitIncreaseAbsoluteCap(address adapter, bytes memory id, uint256 amount) internal {
        bytes memory data = abi.encodeCall(IVaultV2.increaseAbsoluteCap, (id, amount));
        _vaultSubmit(adapter, data);
        emit SubmitIncreaseAbsoluteCap(adapter, amount, id);
    }

    function _submitIncreaseRelativeCap(address adapter, bytes memory id, uint256 amount) internal {
        bytes memory data = abi.encodeCall(IVaultV2.increaseRelativeCap, (id, amount));
        _vaultSubmit(adapter, data);
        emit SubmitIncreaseRelativeCap(adapter, amount, id);
    }

    function _vaultSubmit(address adapter, bytes memory data) internal {
        IVaultV2 vault = _vault(adapter);
        vault.submit(data);
    }

    function _vault(address adapter) internal returns (IVaultV2) {
        require(adapterToVault[adapter] != address(0), "INVALID_ADDRESS");
        return IVaultV2(adapterToVault[adapter]);
    }
}
