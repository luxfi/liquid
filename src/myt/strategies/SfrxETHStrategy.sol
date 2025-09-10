// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
// import {MYTStrategy} from "../MYTStrategy.sol";

import {MYTAdapter} from "../MYTAdapter.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

interface FraxMinter {
    function submitAndDeposit(address recipient) external payable returns (uint256);
}

interface FraxRedemptionQueue {
    function enterRedemptionQueueViaSfrxEth(address _recipient, uint120 _sfrxEthAmount) external returns (uint256 _nftId);
    function burnRedemptionTicketNft(uint256 nftId, address payable recipient) external;
}

interface StakedFraxEth {
    function convertToAssets(uint256 shares) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract SfrxETHStrategy is MYTAdapter {
    FraxMinter public immutable minter;
    FraxRedemptionQueue public immutable redemptionQueue;
    StakedFraxEth public immutable sfrxEth;
    uint256 lastSnapshotTime;
    uint256 lastIndex;
    uint256 FIXED_POINT_SCALAR = 1e18;
    address public immutable WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    event SfrxETHStrategyDebugLog(string message, uint256 amount);

    constructor(address _myt, StrategyParams memory _params, address _sfrxEth, address _fraxMinter, address _redemptionQueue)
        MYTAdapter(_myt, _sfrxEth, _params)
    {
        minter = FraxMinter(_fraxMinter);
        redemptionQueue = FraxRedemptionQueue(_redemptionQueue);
        sfrxEth = StakedFraxEth(_sfrxEth);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        // need to unwrap ether since strats only recieve weth (morpho v2 vault cannot hold native eth by default)
        IWETH(WETH).withdraw(amount);
        // check that eth balance is equal to amount
        emit SfrxETHStrategyDebugLog("Cheking if ETH balance is greater than amount.", address(this).balance);
        require(address(this).balance >= amount, "ETH balance is less than amount");
        emit SfrxETHStrategyDebugLog("Success. ETH balance is greater than amount.", address(this).balance);
        depositReturn = minter.submitAndDeposit{value: amount}(address(this));
    }

    function _deallocate(uint256 amount) internal override returns (uint256 requestedAmount) {
        // protection for uint120 requirement
        require(amount <= type(uint120).max);
        require(sfrxEth.transferFrom(msg.sender, address(this), amount), "pull shares fail");

        sfrxEth.approve(address(redemptionQueue), amount);
        // how do we handle nfts and delayed withdrawals?
        uint256 positionId = redemptionQueue.enterRedemptionQueueViaSfrxEth(address(this), uint120(amount));
        require(positionId != 0);
        requestedAmount = amount;
    }

    function _claimWithdrawalQueue(uint256 positionId) internal returns (uint256 ethOut) {
        redemptionQueue.burnRedemptionTicketNft(positionId, payable(address(this)));
    }

    function _computeBaseRatePerSecond() internal returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = sfrxEth.convertToAssets(1e18);

        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    function realAssets() external view override returns (uint256) {
        return sfrxEth.convertToAssets(sfrxEth.balanceOf(address(this)));
    }

    receive() external payable {
        require(msg.sender == WETH, "Only WETH unwrap");
    }
}
