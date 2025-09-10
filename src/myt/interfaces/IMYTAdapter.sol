// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAdapter} from "../../../lib/vault-v2/src/interfaces/IAdapter.sol";

interface IMYTAdapter is IAdapter {
    enum RiskClass {
        LOW,
        MEDIUM,
        HIGH
    }

    function ids() external view returns (bytes32[] memory);
    function snapshotYield() external returns (uint256);

    struct StrategyParams {
        address owner;
        string name;
        string protocol;
        RiskClass riskClass;
        uint256 cap;
        uint256 globalCap;
        uint256 estimatedYield;
        bool additionalIncentives;
    }

    function adapterId() external view returns (bytes32);
    function getIdData() external view returns (bytes memory);
    function getCap() external view returns (uint256);
    function getGlobalCap() external view returns (uint256);
    function getEstimatedYield() external view returns (uint256);
    function getParams() external view returns (StrategyParams memory);
    function setRiskClass(RiskClass newClass) external;
    function setAdditionalIncentives(bool newValue) external;
    function setKillSwitch(bool val) external;

    // Events
    event Allocate(uint256 indexed amount, address indexed strategy, address indexed vault);
    event Deallocate(uint256 indexed amount, address indexed strategy, address indexed vault);
    event YieldUpdated(uint256 indexed yield);
    event RiskClassUpdated(RiskClass indexed class);
    event IncentivesUpdated(bool indexed enabled);
    event Emergency(bool indexed isEmergency);
    event KillSwitchUpdated(bool indexed isEmergency);
}
