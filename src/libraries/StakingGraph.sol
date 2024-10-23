pragma solidity 0.8.26;

import {SafeCast} from "./SafeCast.sol";

library StakingGraph {
    using SafeCast for int256;

    function updateStakingGraph(mapping(uint256 => int256) storage graph, int256 amount, uint256 blocks) public {
        uint256 currentBlock = block.number;
        uint256 expirationBlock = currentBlock + blocks;

        _update(graph, currentBlock, amount);
        _update(graph, expirationBlock, -amount);
    }

    function currentStaked(mapping(uint256 => int256) storage graph, uint256 blockNumber) public view returns (uint256) {
        return uint256(_query(graph, blockNumber));
    }

    function _update(mapping(uint256 => int256) storage graph, uint256 index, int256 delta) internal {
        index += 1;        
        // TODO: Update this with actual size value we want to use
        while (index <= 500000000) {
            graph[index] += delta;

            assembly {
                index := add(index, and(index, sub(0, index)))
            }
        }
    }

    function _query(mapping(uint256 => int256) storage graph, uint256 index) internal view returns (int256 sum) {
        index += 1;
        while (index > 0) {
            sum += graph[index];

            assembly {
                index := sub(index, and(index, sub(0, index)))
            }
        }
    }
}