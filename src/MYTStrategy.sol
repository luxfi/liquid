// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IMYTStrategy} from "./interfaces/IMYTStrategy.sol";
import "forge-std/console.sol";
import {ISettlerActions} from './external/interfaces/ISettlerActions.sol';
import {IVelodromePair} from './external/interfaces/IVelodromePair.sol';
import {ISignatureTransfer} from '../lib/permit2/src/interfaces/ISignatureTransfer.sol';
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ZeroXSwapVerifier} from './utils/ZeroXSwapVerifier.sol';

interface IERC721Tiny {
    function ownerOf(uint256 tokenId) external view returns (address);
}
interface IDeployerTiny is IERC721Tiny {
    function prev(uint128 featureId) external view returns (address);
}
contract MYTStrategy is IMYTStrategy, Ownable {
    IVaultV2 public immutable MYT;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant FIXED_POINT_SCALAR = 1e18;

    StrategyParams public params;

    uint256 public lastSnapshotTime;
    uint256 public lastIndex;
    uint256 public estApr;
    uint256 public estApy;

    /// @notice This value is true when the underlying protocol is known to
    /// experience issues or security incidents. In this case the allocation step is simply
    /// bypassed without reverts (to keep external allocators from reverting).
    bool public killSwitch;

    mapping (address => bool) public whitelistedAllocators;

    IDeployerTiny constant ZERO_EX_DEPLOYER =
    IDeployerTiny(0x00000000000004533Fe15556B1E086BB1A72cEae);

    error CounterfeitSettler(address);


    constructor(address _myt, StrategyParams memory _params) Ownable(_params.owner) {
        require(_params.owner != address(0));
        require(_myt != address(0));
        MYT = IVaultV2(_myt);
        params = _params;
        // TODO add the strategy to the perpetual gauge in an authenticated manner
        // TODO perhap take initial snapshot now to set up start block
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

    /// @notice call this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy in case we want to bypass
    /// a withdrawal queue or similar mechanism and directly go to a DEX
    function deallocateDex(bytes calldata quote, bool prevSettler) external returns (uint256 ret) {
        IERC20 asset = IERC20(address(MYT.asset()));
        // TODO additional access control needed?
        require(whitelistedAllocators[msg.sender], "PD");
        address currentSettler = prevSettler ? ZERO_EX_DEPLOYER.prev(2) : ZERO_EX_DEPLOYER.ownerOf(2);
        uint256 balanceBefore = asset.balanceOf(address(this));
        uint256 limit = balanceBefore * 10 / 100; // 10% of balance
        require(ZeroXSwapVerifier.verifySwapCalldata(quote, address(this), address(MYT.asset()), limit));

        (bool success,) = currentSettler.call(quote);
        require(success, "SF"); // settler failed
        uint256 balanceAfter = asset.balanceOf(address(this));
        ret = balanceBefore - balanceAfter;
        emit DeallocateDex(ret);
    }

    /// @notice call this function to handle strategies with withdrawal queue NFT
    function claimWithdrawalQueue(uint256 positionId) public virtual returns (uint256 ret) {
        _claimWithdrawalQueue(positionId);
    }

    /// @notice call this function to claim all available rewards from the respective
    /// protocol of this strategy
    function claimRewards() public virtual returns (uint256) {
        _claimRewards();
    }

    /// @dev override this function to handle wrapping/allocation/moving funds to
    /// the respective protocol of this strategy
    function _allocate(uint256 amount) internal virtual returns (uint256) {}

    /// @dev override this function to handle unwrapping/deallocation/moving funds from
    /// the respective protocol of this strategy
    function _deallocate(uint256 amount) internal virtual returns (uint256) {}

    /// @dev override this function to handle strategies with withdrawal queue NFT
    function _claimWithdrawalQueue(uint256 positionId) internal virtual returns (uint256) {}

    /// @dev override this function to claim all available rewards from the respective
    /// protocol of this strategy
    function _claimRewards() internal virtual returns (uint256){}

    /// @notice can be called by anyone to recalculate the
    /// estimated yields of this strategy based on external price
    /// oracles and protocol heuristics.
    function snapshotYield() public virtual returns (uint256) {
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

        // Smoothing factor
        // TODO need to figure out how to ramp this up
        // Since first call is 0 the second call will be skewed
        // perhaps no smoothing on second pass
        uint256 alpha = 7e17; // 0.7
        estApr = _lerp(estApr, apr, alpha);
        estApy = _lerp(estApy, apy, alpha);

        lastSnapshotTime = uint64(currentTime);
        lastIndex = newIndex;

        emit YieldUpdated(estApy);

        return estApy;
    }

    /// @dev override this function to handle strategy specific base rate calculation
    // TODO this one is only different by how we get the asset price
    // may be good to move this logic here and host only the price in the adapter
    function _computeBaseRatePerSecond() internal virtual returns (uint256 ratePerSec, uint256 newIndex) {}

    /// @dev override this function to handle strategy specific reward rate calculation   
    function _computeRewardsRatePerSecond() internal virtual returns (uint256) {}

    // Helper for yield snapshot calculation
    function _approxAPY(uint256 ratePerSecWad) internal pure returns (uint256) {
        uint256 apr = ratePerSecWad * SECONDS_PER_YEAR;
        uint256 aprSq = apr * apr / FIXED_POINT_SCALAR;
        return apr + aprSq / (2 * SECONDS_PER_YEAR);
    }

    // Helper for yield snapshot calculation
    function _lerp(uint256 oldVal, uint256 newVal, uint256 alpha) internal pure returns (uint256) {
        return alpha * oldVal / FIXED_POINT_SCALAR + (FIXED_POINT_SCALAR - alpha) * newVal / FIXED_POINT_SCALAR;
    }

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
