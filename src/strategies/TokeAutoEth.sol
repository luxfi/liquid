// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {MYTStrategy} from "../MYTStrategy.sol";

import {IERC4626} from "../../lib/openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IMainRewarder, IAutopilotRouter} from "./interfaces/ITokemac.sol";

interface WETH {
    function withdraw(uint256) external;
}

interface RootOracle {
    function getPriceInEth(address token) external returns (uint256 price);
}

contract TokeAutoEthStrategy is MYTStrategy {
    IERC4626 public immutable autoEth;
    IAutopilotRouter public immutable router;
    IMainRewarder public immutable rewarder;
    WETH public immutable weth;
    RootOracle public immutable oracle;
    address public immutable rewardToken;

    // address public constant REWARD_TOKEN = ;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    constructor(
        address _myt,
        StrategyParams memory _params,
        address _autoEth,
        address _router,
        address _rewarder,
        address _weth,
        address _oracle
    ) MYTStrategy(_myt, _params) {
        autoEth = IERC4626(_autoEth);
        router = IAutopilotRouter(_router);
        rewarder = IMainRewarder(_rewarder);
        weth = WETH(_weth);
        oracle = RootOracle(_oracle);
    }

    function _allocate(uint256 amount) internal override returns (uint256 depositReturn) {
        require(msg.value == amount);
        // Slippage handled upstream
        depositReturn = router.depositMax{value: msg.value}(autoEth, address(this), 0);
        // Stakes tokens for TOKE rewards
        router.stakeVaultToken(autoEth, depositReturn);
    }
    
    // todo slippage checks
    function _deallocate(uint256 amount) internal override returns (uint256 withdrawReturn) {
        withdrawReturn = autoEth.redeem(amount, msg.sender, address(this));
        router.withdrawVaultToken(autoEth, rewarder, type(uint256).max, false);
        _unwrapWETH(withdrawReturn, address(MYT));
    }

    function _claimRewards() internal override returns (uint256 rewardsClaimed) {
        rewarder.getReward(msg.sender, address(MYT), false);
    }

    function _unwrapWETH(uint256 amount, address to) internal {
        weth.withdraw(amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "ETH send failed");
    }

    function snapshotYield() public override returns (uint256) {
        uint256 currentTime = block.timestamp;

        // todo decide to implement this
        // if (lastSnapshotTime != 0 && currentTime - lastSnapshotTime < MIN_SNAPSHOT_INTERVAL) {
        //     return estApy;
        // }

        // Base rate of strategy
        (uint256 baseRatePerSec, uint256 newIndex) = _computeBaseRatePerSecond();

        // Add incentives to calculation if applicable 
        uint256 rewardsRatePerSec; 
        if (params.additionalIncentives == true) rewardsRatePerSec = _computeRewardsRatePerSecond();

        // Combine rates
        uint256 totalRatePerSec = baseRatePerSec + rewardsRatePerSec;
        uint256 apr = totalRatePerSec * SECONDS_PER_YEAR; // simple annualization (APR)
        uint256 apy = _approxAPY(totalRatePerSec);

        // Smoothing
        uint256 alpha = 7e17;
        estApr = lastSnapshotTime == 0 ? apr : _lerp(estApr, apr, alpha);
        estApy = lastSnapshotTime == 0 ? apy : _lerp(estApy, apy, alpha);

        lastSnapshotTime = uint64(currentTime);
        lastIndex = newIndex;

        emit YieldUpdated(estApy);

        return estApy;
    }

    function _computeBaseRatePerSecond() internal returns (uint256 ratePerSec, uint256 newIndex) {
        uint256 dt = lastSnapshotTime == 0 ? 0 : block.timestamp - lastSnapshotTime;

        uint256 currentPPS = oracle.getPriceInEth(address(autoEth));

        newIndex = currentPPS;
        if (lastIndex == 0 || dt == 0 || currentPPS <= lastIndex) return (0, newIndex);
        uint256 growth = (currentPPS - lastIndex) * FIXED_POINT_SCALAR / lastIndex;
        ratePerSec = growth / dt;
        return (ratePerSec, newIndex);
    }

    function _computeRewardsRatePerSecond() internal returns (uint256) {
        if (rewarder.rewardToken() == address(0)) return 0;

        uint256 assetPrice = oracle.getPriceInEth(address(autoEth));
        uint256 tvlAssets = autoEth.balanceOf(MYT);
        if (tvlAssets == 0 || assetPrice == 0) return 0;

        (uint256 rewardPrice, bool haveRew) = _rewardPricePerSecond();
        if (!haveRew || rewardPrice == 0) return 0;

        uint256 tvlEth = tvlAssets * assetPrice / FIXED_POINT_SCALAR;

        if (tvlEth == 0) return 0;
        return rewardPrice * FIXED_POINT_SCALAR / tvlEth;
    }

    function _rewardPricePerSecond() internal returns (uint256 usdPerSecRaw, bool ok) {
        if (rewarder.rewardToken() == address(0)) return (0, false);
        uint256 rewardPrice = oracle.getPriceInEth(rewarder.rewardToken());
        if (rewardPrice == 0) return (0, false);

        uint256 rate = rewarder.rewardRate();
        if (rate == 0) return (0, false);

        return (rate * rewardPrice, true);
    }

    function _approxAPY(uint256 ratePerSecWad) internal pure returns (uint256) {
        uint256 apr = ratePerSecWad * SECONDS_PER_YEAR;
        uint256 aprSq = apr * apr / FIXED_POINT_SCALAR;
        return apr + aprSq / (2 * SECONDS_PER_YEAR);
    }

    function _lerp(uint256 oldVal, uint256 newVal, uint256 alpha) internal pure returns (uint256) {
        return alpha * oldVal / FIXED_POINT_SCALAR + (FIXED_POINT_SCALAR - alpha) * newVal / FIXED_POINT_SCALAR;
    }
}