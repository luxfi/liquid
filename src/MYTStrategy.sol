// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IMYTStrategy} from "./interfaces/IMYTStrategy.sol";
contract MYTStrategy is IMYTStrategy, Ownable {
    IVaultV2 public immutable MYT;

    StrategyParams public params;

    /// @notice This value is true when the underlying protocol is known to
    /// experience issues or security incidents. In this case the allocation step is simply
    /// bypassed without reverts (to keep external allocators from reverting).
    bool public killSwitch;

    mapping (address => bool) public whitelistedAllocators;

    constructor(address _myt, StrategyParams memory _params) Ownable(_params.owner) {
        require(params.owner != address(0));
        require(_myt != address(0));
        MYT = IVaultV2(_myt);
        params = _params;
        // TODO add the strategy to the perpetual gauge in an authenticated manner
    }

    /// @notice call this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    function allocate(uint256 amount) public payable returns (uint256 ret) {
        // TODO additional access control needed?
        require(whitelistedAllocators[msg.sender], "PD");
        ret = _allocate(amount);
        emit Allocate(amount);
    }

    /// @notice call this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    function deallocate(uint256 amount) public virtual returns (uint256 ret) {
        // TODO additional access control needed?
        require(whitelistedAllocators[msg.sender], "PD");
        ret = _deallocate(amount);
        emit Deallocate(amount);
    }

    /// @dev override this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    function _allocate(uint256 amount) internal virtual returns (uint256) {}

    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    function _deallocate(uint256 amount) internal virtual returns (uint256) {}

    /// @notice can be called by anyone to recalculate the
    /// estimated yields of this strategy based on external price
    /// oracles and protocol heuristics.
    function snapshotYield() public virtual returns (uint256) {}

    /// @notice recategorize this strategy to a different risk class
    function setRiskClass(RiskClass newClass) public onlyOwner {
        params.riskClass = newClass;
        emit RiskClassUpdated(newClass);
    }

    /// @dev some protocols may pay yield in baby tokens
    /// so we need to manually collect them
    function setAdditionalIncentives(bool newValue) public onlyOwner {
        params.additionalIncentives = newValue;
        emit IncentivesUpdated(newValue);
    }

    function setWhitelistedAllocator(address to, bool val) public onlyOwner {
        require(to != address(0));
        whitelistedAllocators[to] = val;
    }

    /// @notice enter/exit emergency mode for this strategy
    function setKillSwitch(bool val) public onlyOwner {
        killSwitch = val;
        emit Emergency(val);
    }

    /// @notice get the current snapshotted estimated yield for this strategy.
    /// This call does not guarantee the latest up-to-date yield and there might
    /// be discrepancies from the respective protocols numbers.
    function getEstimatedYield() public view returns (uint256) {
        return params.estimatedYield;
    }

    function getCap() external view returns (uint256) {
        return params.cap;
    }

    function getGlobalCap() external view returns (uint256) {
        return params.globalCap;
    }
}
