pragma solidity ^0.8.23;

import {IYieldToken} from "../../interfaces/IYieldToken.sol";

contract TokenAdapterMock {
    address public token;
    address public underlyingToken;

    constructor(address _token) {
        token = _token;
        underlyingToken = IYieldToken(_token).underlyingToken();
    }

    function price() external view returns (uint256) {
        return IYieldToken(token).price();
    }
}
