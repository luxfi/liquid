// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MYTAdapter} from "../../myt/MYTAdapter.sol";
import {IMYTAdapter} from "../../myt/interfaces/IMYTAdapter.sol";
import {TokenUtils} from "../../libraries/TokenUtils.sol";
import {IMockYieldToken} from "./MockYieldToken.sol";

contract MockMYTStrategy is MYTAdapter {
    event TestLogger(string message, uint256 value);
    event TestLoggerAddress(string message, address value);

    IMockYieldToken public immutable token;

    constructor(address _myt, address _token, IMYTAdapter.StrategyParams memory _params) MYTAdapter(_myt, _token, _params) {
        token = IMockYieldToken(_token);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        // if native eth used, most strats will have theor own function to wrap eth to weth
        // so will assume that all token deposits are done with weth
        TokenUtils.safeApprove(token.underlyingToken(), address(token), 2 * amount);
        depositReturn = token.deposit(amount);
        require(depositReturn == amount);
    }

    function _deallocate(uint256 amount) internal override returns (uint256 amountRequested) {
        amountRequested = token.requestWithdraw(address(this), amount);
        TokenUtils.safeApprove(token.underlyingToken(), msg.sender, amount);
        require(amountRequested != 0);
    }

    function snapshotYield() external override returns (uint256) {
        // TODO calculate & snapshot yield
    }

    function realAssets() external view override returns (uint256) {
        return (token.balanceOf(address(this)) * token.price()) / 10 ** token.decimals();
    }

    function mockUpdateWhitelistedAllocators(address allocator, bool value) public {}
}
