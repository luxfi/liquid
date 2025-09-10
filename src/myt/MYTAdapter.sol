// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IAdapter} from "../../lib/vault-v2/src/interfaces/IAdapter.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IMYTVault} from "./interfaces/IMYTVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMYTAdapter} from "./interfaces/IMYTAdapter.sol";

/**
 * @title MYTAdapter
 * @notice This contract is a wrapper around a single MYT strategy. It is used to allocate and deallocate funds to a single strategy.
 * @dev Workflow for creating new adapters :
 *     1) Deploy adapter
 *     2) Add adapter via setIsAdapter() on Morpho V2 Vault(timelocked), via the myt curator proxy
 *     3) Set absolute cap via increaseAbsoluteCap() on Morpho V2 Vault(timelocked)
 *     4) Only then can allocations happen
 */
contract MYTAdapter is IMYTAdapter, Ownable {
    ERC20 public immutable yieldToken;
    address public immutable myt;
    bytes32 public immutable adapterId;
    StrategyParams public params;
    bool public killSwitch;

    constructor(address _myt, address _yieldToken, StrategyParams memory _params) Ownable(_params.owner) {
        require(_myt != address(0));
        require(_yieldToken != address(0));
        require(_params.owner != address(0));
        myt = _myt;
        yieldToken = ERC20(_yieldToken);
        adapterId = keccak256(abi.encode(_params.protocol, address(this)));
        params = _params;
    }

    /// @notice Modifier to restrict access to the vault **managed** by the MYT contract
    modifier onlyVault() {
        require(msg.sender == address(IMYTVault(myt).MYT()), "Only vault can call this function");
        _;
    }

    /// @notice Modifier to restrict access to the MYT contract
    modifier onlyMYT() {
        require(msg.sender == address(myt), "Only MYT can call this function");
        _;
    }

    function getParams() external view returns (StrategyParams memory) {
        return params;
    }

    function getIdData() external view returns (bytes memory) {
        return abi.encode(params.protocol, address(this));
    }

    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        override
        onlyVault
        returns (bytes32[] memory strategyIds, int256 change)
    {
        // lets decode the old allocation from the data
        uint256 oldAllocation = abi.decode(data, (uint256));
        uint256 amountAllocated = _allocate(assets);
        uint256 newAllocation = oldAllocation + amountAllocated;
        emit Allocate(amountAllocated, address(this), address(IMYTVault(myt).MYT()));
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        override
        onlyVault
        returns (bytes32[] memory strategyIds, int256 change)
    {
        uint256 oldAllocation = abi.decode(data, (uint256));
        uint256 amountDeallocated = _deallocate(assets);
        uint256 newAllocation = oldAllocation - amountDeallocated;
        emit Deallocate(amountDeallocated, address(this), address(IMYTVault(myt).MYT()));
        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    function _allocate(uint256 assets) internal virtual returns (uint256) {}

    function _deallocate(uint256 assets) internal virtual returns (uint256) {}

    function snapshotYield() external virtual returns (uint256) {}

    function realAssets() external view virtual override returns (uint256) {}

    function ids() public view override returns (bytes32[] memory) {
        bytes32[] memory ids_ = new bytes32[](1);
        ids_[0] = adapterId;
        return ids_;
    }

    function setRiskClass(RiskClass newClass) external override onlyMYT {
        params.riskClass = newClass;
        emit RiskClassUpdated(newClass);
    }

    function setAdditionalIncentives(bool newValue) external override onlyMYT {
        params.additionalIncentives = newValue;
        emit IncentivesUpdated(newValue);
    }

    function setKillSwitch(bool val) external override onlyMYT {
        killSwitch = val;
        emit KillSwitchUpdated(val);
    }

    function getEstimatedYield() external view override returns (uint256) {
        return params.estimatedYield;
    }

    function getCap() external view override returns (uint256) {
        return params.cap;
    }

    function getGlobalCap() external view override returns (uint256) {
        return params.globalCap;
    }
}
