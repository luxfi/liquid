pragma solidity ^0.8.23;

import {ERC20} from "../../../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

import "../../libraries/TokenUtils.sol";
import "../../interfaces/test/ITestYieldToken.sol";
import "./TestERC20.sol";

/// @title  TestYieldToken
/// @author Lux Liquid
contract TestYieldToken is ITestYieldToken, ERC20 {
    address private constant BLACKHOLE = address(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
    uint256 private constant BPS = 10_000;

    address public override underlyingToken;
    uint8 private _decimals;
    uint256 public slippage;
    uint256 public mockedSupply;

    event TestYieldTokenLogEvent(string message, uint256 amount, address recipient);

    constructor(address _underlyingToken) ERC20("Yield Token", "Yield Token") {
        underlyingToken = _underlyingToken;
        _decimals = TokenUtils.expectDecimals(_underlyingToken);
        slippage = 0;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function price() external view override returns (uint256) {
        return _shareValue(10 ** _decimals);
    }

    /// @dev This token is its own adapter in the test harness, so the yield
    ///      token the adapter reports is itself.
    function token() external view returns (address) {
        return address(this);
    }

    function setSlippage(uint256 _slippage) external {
        slippage = _slippage;
    }

    function updateMockTokenSupply(uint256 value) external {
        mockedSupply = value;
    }

    function mint(uint256 amount, address recipient) external override returns (uint256) {
        assert(amount > 0);

        uint256 shares = _issueSharesForAmount(recipient, amount);
        TokenUtils.safeTransferFrom(underlyingToken, msg.sender, address(this), amount);

        return shares;
    }

    function redeem(uint256 shares, address recipient) external override returns (uint256) {
        assert(shares > 0);

        uint256 value = _shareValue(shares);
        value = (value * (BPS - slippage)) / BPS;
        _burn(msg.sender, shares);
        if (mockedSupply > shares) mockedSupply -= shares;
        TokenUtils.safeTransfer(underlyingToken, recipient, value);

        return value;
    }

    function slurp(uint256 amount) external override {
        TokenUtils.safeTransferFrom(underlyingToken, msg.sender, address(this), amount);
    }

    function siphon(uint256 amount) external override {
        TokenUtils.safeTransfer(underlyingToken, BLACKHOLE, amount);
    }

    function _issueSharesForAmount(address to, uint256 amount) internal returns (uint256) {
        uint256 shares = 0;
        if (mockTokenSupply() > 0) {
            shares = (amount * mockTokenSupply()) / TokenUtils.safeBalanceOf(underlyingToken, address(this));
        } else {
            shares = amount;
        }
        shares = (shares * (BPS - slippage)) / BPS;
        _mint(to, shares);
        // The mocked count stands in for the share supply the price is quoted
        // against, so it has to move with the shares. Left frozen at whatever
        // {updateMockTokenSupply} last set, it keeps dividing a growing
        // underlying balance by the count from one deposit ago, and the price
        // runs away from anything a vault could report -- far enough that
        // converting a debt to yield tokens throws away twelve digits, and the
        // engine's own accounting appears to leak.
        if (mockedSupply > 0) mockedSupply += shares;
        return shares;
    }

    function _shareValue(uint256 shares) internal view returns (uint256) {
        if (mockTokenSupply() == 0) {
            return shares;
        }
        return (shares * TokenUtils.safeBalanceOf(underlyingToken, address(this))) / mockTokenSupply();
    }

    function mockTokenSupply() public view returns (uint256) {
        return mockedSupply > 0 ? mockedSupply : totalSupply();
    }
}
