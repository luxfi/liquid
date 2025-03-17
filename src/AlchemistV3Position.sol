// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IAlchemistV3Position} from "./interfaces/IAlchemistV3Position.sol";
import {IAlchemistV3} from "./interfaces/IAlchemistV3.sol";

/**
 * @title AlchemistV3Position
 * @notice ERC721 position token for AlchemistV3, where only the AlchemistV3 contract
 *         is allowed to mint and burn tokens. Minting returns a unique token id.
 */
contract AlchemistV3Position is ERC721Enumerable {
    /// @notice The only address allowed to mint and burn position tokens.
    address public alchemist;

    /// @notice Counter used for generating unique token ids.
    uint256 private _currentTokenId;

    /// @dev Modifier to restrict calls to only the authorized AlchemistV3 contract.
    modifier onlyAlchemist() {
        require(msg.sender == alchemist, "AlchemistV3Position: caller is not the alchemist");
        _;
    }

    /**
     * @notice Constructor that sets the Alchemist address and initializes the ERC721 token.
     * @param alchemist_ The address of the Alchemist contract.
     */
    constructor(address alchemist_) ERC721("AlchemistV3Position", "ALCV3") {
        require(alchemist_ != address(0), "AlchemistV3Position: alchemist address is zero");
        alchemist = alchemist_;
    }

    /**
     * @notice Mints a new position NFT to `to`.
     * @dev Only callable by the AlchemistV3 contract.
     * @param to The recipient address for the new position.
     * @return tokenId The unique token id minted.
     */
    function mint(address to) external onlyAlchemist returns (uint256) {
        require(to != address(0), "AlchemistV3Position: mint to the zero address");
        _currentTokenId++;
        uint256 tokenId = _currentTokenId;
        _mint(to, tokenId);
        return tokenId;
    }

    function burn(uint256 tokenId) public onlyAlchemist {
        _burn(tokenId);
    }

    /**
     * @notice Override supportsInterface to resolve inheritance conflicts.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @notice Hook that is called before any token transfer
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        // Reset mint allowances before the transfer completes
        if (from != address(0)) {
            // Skip during minting
            IAlchemistV3(alchemist).resetMintAllowances(tokenId);
        }
        // Call parent implementation first
        return super._update(to, tokenId, auth);
    }
}
