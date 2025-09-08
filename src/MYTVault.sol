// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMYTVault} from "./interfaces/IMYTVault.sol";
import {IMYTAdapter} from "./MYTAdapter.sol";

contract MYTVault is IMYTVault, Ownable {
    IVaultV2 public immutable MYT;

    IMYTAdapter.StrategyParams public params;

    /// @notice This value is true when the underlying protocol is known to
    /// experience issues or security incidents. In this case the allocation step is simply
    /// bypassed without reverts (to keep external allocators from reverting).
    bool public killSwitch;

    mapping(address => bool) public whitelistedAllocators;

    // bytes32 public adapterId;

    event LogEvent(string message, address value);
    event LogEventBool(string message, bool value);

    constructor(address _vault) Ownable(msg.sender) {
        require(_vault != address(0));
        MYT = IVaultV2(_vault);
        //  adapterId = keccak256(abi.encode("this", address(this)));
        // TODO add the strategy to the perpetual gauge in an authenticated manner
    }
    /* 
    /// @notice call this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    function allocate(uint256 amount) public payable returns (uint256 ret) {
        // TODO additional access control needed?
        require(whitelistedAllocators[msg.sender], "PD");
        ret = _allocate(amount);
        emit Allocate(amount);
    } */

    /// @notice call this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    /*     function allocate(address adapter, bytes memory data, uint256 assets) external
        returns (uint256){
        // TODO additional access control needed?
        require(whitelistedAllocators[msg.sender], "PD");
        emit LogEvent("myt vault allocate, msg.sender : ", msg.sender);
        MYT.allocate(adapter, data, assets);
        return assets;
    }

    /// @notice call this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    function deallocate(address adapter, bytes memory data, uint256 assets)
        external
        returns (uint256){
        // TODO additional access control needed?
        require(whitelistedAllocators[msg.sender], "PD");
        MYT.deallocate(adapter, data,assets);
        return assets;
    } */

    /// @notice can be called by anyone to recalculate the
    /// estimated yields of this strategy based on external price
    /// oracles and protocol heuristics.
    function snapshotYield(address adapter) external returns (uint256) {
        return IMYTAdapter(adapter).snapshotYield();
    }

    /// @notice recategorize this strategy to a different risk class
    function setRiskClass(address strategy, IMYTAdapter.RiskClass newClass) public onlyOwner {
        IMYTAdapter(strategy).setRiskClass(newClass);
    }

    /// @dev some protocols may pay yield in baby tokens
    /// so we need to manually collect them
    function setAdditionalIncentives(address strategy, bool newValue) public onlyOwner {
        IMYTAdapter(strategy).setAdditionalIncentives(newValue);
    }

    function setWhitelistedAllocator(address to, bool val) public onlyOwner {
        require(to != address(0));
        whitelistedAllocators[to] = val;
    }

    /// @notice enter/exit emergency mode for this strategy
    function setKillSwitch(address strategy, bool val) public onlyOwner {
        IMYTAdapter(strategy).setKillSwitch(val);
    }

    /// @notice get the current snapshotted estimated yield for this strategy.
    /// This call does not guarantee the latest up-to-date yield and there might
    /// be discrepancies from the respective protocols numbers.
    function getEstimatedYield(address strategy) public view returns (uint256) {
        return IMYTAdapter(strategy).getEstimatedYield();
    }

    function getCap(address strategy) external view returns (uint256) {
        return IMYTAdapter(strategy).getCap();
    }

    function getGlobalCap(address strategy) external view returns (uint256) {
        return IMYTAdapter(strategy).getGlobalCap();
    }

    function getParams(address strategy) external view returns (IMYTAdapter.StrategyParams memory) {
        return IMYTAdapter(strategy).getParams();
    }

    /// @dev Returns adapter's ids.
    function ids(address strategy) public view returns (bytes32[] memory) {
        bytes32[] memory ids_ = new bytes32[](1);
        ids_[0] = IMYTAdapter(strategy).adapterId();
        return ids_;
    }

    function asset() external view returns (address) {
        return MYT.asset();
    }

    function getAbsoluteCap(bytes32 id) external view returns (uint256) {
        return MYT.absoluteCap(id);
    }

    function getRelativeCap(bytes32 id) external view returns (uint256) {
        return MYT.relativeCap(id);
    }
}
