// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultV2} from "../../../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {IMYTAdapter} from "./IMYTAdapter.sol";

interface IMYTVault {
    // Events
    event Allocate(uint256 indexed amount);
    event Deallocate(uint256 indexed amount);
    event YieldUpdated(uint256 indexed yield);
    event RiskClassUpdated(IMYTAdapter.RiskClass indexed class);
    event IncentivesUpdated(bool indexed enabled);
    event Emergency(bool indexed isEmergency);

    // Functions

    /*     /// @dev override this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    function allocate(address adapter, bytes memory data, uint256 assets) external
        returns (uint256);
    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    function deallocate(address adapter, bytes memory data, uint256 assets)
        external
        returns (uint256); */

    /// @notice can be called by anyone to recalculate the
    /// estimated yields of this strategy based on external price
    /// oracles and protocol heuristics.
    function snapshotYield(address adapter) external returns (uint256);

    /// @notice recategorize this strategy to a different risk class
    function setRiskClass(address strategy, IMYTAdapter.RiskClass newClass) external;

    function setAdditionalIncentives(address strategy, bool newValue) external;

    function setWhitelistedAllocator(address to, bool val) external;

    /// @notice enter/exit emergency mode for this strategy
    function setKillSwitch(address strategy, bool val) external;

    /// @notice get the current snapshotted estimated yield for this strategy.
    /// This call does not guarantee the latest up-to-date yield and there might
    /// be discrepancies from the respective protocols numbers.
    function getEstimatedYield(address strategy) external view returns (uint256);

    // Getter for params
    function getParams(address strategy) external view returns (IMYTAdapter.StrategyParams memory);

    function getCap(address strategy) external view returns (uint256);
    function getGlobalCap(address strategy) external view returns (uint256);
    function asset() external view returns (address);
    function getAbsoluteCap(bytes32 id) external view returns (uint256);
    function getRelativeCap(bytes32 id) external view returns (uint256);
    function MYT() external view returns (IVaultV2);
}
