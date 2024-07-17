pragma solidity >=0.5.0;

import "./alchemist/IAlchemistV3Actions.sol";
import "./alchemist/IAlchemistV3AdminActions.sol";
import "./alchemist/IAlchemistV3Errors.sol";
import "./alchemist/IAlchemistV3Immutables.sol";
import "./alchemist/IAlchemistV3Events.sol";
import "./alchemist/IAlchemistV3State.sol";

/// @title  IAlchemistV3
/// @author Alchemix Finance
interface IAlchemistV3 is IAlchemistV3Actions, IAlchemistV3AdminActions, IAlchemistV3Errors, IAlchemistV3Immutables, IAlchemistV3Events, IAlchemistV3State {}
