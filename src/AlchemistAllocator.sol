// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;
import {IVaultV2} from "../lib/vault-v2/src/interfaces/IVaultV2.sol";
import {PermissionedProxy} from "./utils/PermissionedProxy.sol";

/*  The Allocator Proxy allows the Operator to take the following actions:
1. Deallocate funds from enabled markets to the idle market, down to or beyond the minimum of the (DAO target, max hard cap, max relative cap), also restricted by StrategyClassificationProxy risk levels
    1. This needs to be a simple function to call (Association enters an array of yield strats and the % to withdraw down to? Any that are not < the min value get automatically set to the min value (or just skipped over)
2. Allocate funds from the the idle market to enabled markets, up to the maximum of (DAO target, max hard cap, max relative cap), also restricted by StrategyClassificationProxy risk levels

The Allocator Proxy allows the Admin (Alchemix DAO) to take the following actions:

1. Deallocate funds down to minimum of (max hard cap, max relative cap) with no other restrictions
2. Allocate funds up to the maximum of (max hard cap, max relative cap) with no other restrictions
3. Set the liquidityAdapter
4. Set liquidityData
*/

contract AlchemistAllocator is PermissionedProxy {
    IVaultV2 immutable vault;

    constructor(address _vault, address _admin, address _operator)  PermissionedProxy(_admin, _operator) {
        require(IVaultV2(_vault).asset() != address(0), "IV");
        vault = IVaultV2(_vault);

        // allocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x5c9ce04d] = true;
        // deallocate(address adapter, bytes memory data, uint256 assets)
        permissionedCalls[0x4b219d16] = true;
    }

    event Allocate(address indexed vault, uint256 indexed amount, address adapter);
    event Deallocate(address indexed vault, uint256 indexed amount, address adapter);



    // Overriden vault actions
    function allocate(bytes32 id, address adapter, bytes memory data, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        uint256 absoluteCap = vault.absoluteCap(id);
        uint256 relativeCap = vault.relativeCap(id);
        uint256 daoTarget = type(uint256).max; // FIXME where do I get this from?

        uint256 adjusted = absoluteCap > relativeCap ? absoluteCap : relativeCap;
        if (msg.sender != admin) { // caller is operator
            adjusted = adjusted > daoTarget ? adjusted : daoTarget;
        }

        vault.allocate(adapter, data, amount);
        emit Allocate(address(vault), amount, adapter);
    }

    function deallocate(bytes32 id, address adapter, bytes memory data, uint256 amount) external {
        require(msg.sender == admin || operators[msg.sender], "PD");
        uint256 absoluteCap = vault.absoluteCap(id);
        uint256 relativeCap = vault.relativeCap(id);
        uint256 daoTarget = type(uint256).max; // FIXME where do I get this from?

        uint256 adjusted = absoluteCap < relativeCap ? absoluteCap : relativeCap;

        if (msg.sender != admin) { // caller is operator
            adjusted = adjusted < daoTarget ? adjusted : daoTarget;
        }

        vault.deallocate(adapter, data, amount);
        emit Deallocate(address(vault), amount, adapter);
    }


    // function setLiquidityAdapterAndData(address vault, address newLiquidityAdapter, bytes memory newLiquidityData) external onlyAdmin {
    //    IVaultV2(vault).setLiquidityAdapterAndData(newLiquidityAdapter, newLiquidityData);
    //    require(IVaultV2(vault).liquidityAdapter() == newLiquidityAdapter);
    // }


    
}
