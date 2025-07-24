// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

contract AlchemistStrategyClassifier {
    address public admin;
    address public pendingAdmin;

    /**
     * @notice globalCap is is the maximum allocation (within the MYT) for ALL strategies of this type together
     * @notice localCap is the maximum  allocation (within the MYT) for this specific type
    */
    struct RiskClass {
        uint256 globalCap;
        uint256 localCap;
    }

    mapping (uint256 => RiskClass) public riskClasses;

    constructor(address _admin) {
        require(_admin != address(0), "IA");
        admin = _admin;
        // low risk
        riskClasses[0] = RiskClass(type(uint256).max, type(uint256).max);

        // medium risk
        // FIXME what are the starting values before the admin sets it?
        riskClasses[1] = RiskClass(type(uint256).max, type(uint256).max);

        // high risk
        // FIXME what are the starting values before the admin sets it?
        riskClasses[2] = RiskClass(type(uint256).max, type(uint256).max);

        pendingAdmin = address(0);
    }

    event AdminChanged(address indexed admin);
    event RiskClassModified(uint256 indexed class, uint256 indexed globalCap, uint256 indexed localCap);

    function transferOwnership(address _newAdmin) external {
        require(msg.sender == admin, "PD");
        pendingAdmin = _newAdmin;
    }

    function acceptOwnership() external {
        require(msg.sender == pendingAdmin, "PD");
        admin = pendingAdmin;
        pendingAdmin = address(0);
        emit AdminChanged(pendingAdmin);
    }

    function setRiskClass(uint256 class, uint256 globalCap, uint256 localCap) external {
        require(msg.sender == admin, "PD");

        riskClasses[class] = RiskClass(globalCap, localCap);
        emit RiskClassModified(class, globalCap, localCap);
    }
}
