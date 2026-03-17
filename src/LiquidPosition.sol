// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ILiquidPosition} from "./interfaces/ILiquidPosition.sol";
import {ILiquid} from "./interfaces/ILiquid.sol";
import {NFTMetadataGenerator} from "./libraries/NFTMetadataGenerator.sol";

/**
 * @title LiquidPosition
 * @notice ERC721 position token for Liquid, where only the Liquid contract
 *         is allowed to mint and burn tokens. Minting returns a unique token id.
 */
contract LiquidPosition is ERC721Enumerable {
    using Strings for uint256;

    /// @notice The only address allowed to mint and burn position tokens.
    address public liquid;

    /// @notice Counter used for generating unique token ids.
    uint256 private _currentTokenId;

    // SVG colors
    string private constant SVG_BG_COLOR = "#d4c3b7";
    string private constant SVG_TEXT_COLOR = "#0a3a60";
    string private constant SVG_ACCENT_COLOR = "#0a3a60";

    /// @notice An error which is used to indicate that the functioin call failed becasue the caller is not the liquid
    error CallerNotLiquid();

    /// @notice An error which is used to indicate that Liquid set is the zero address
    error LiquidZeroAddressError();

    /// @notice An error which is used to indicate that address minted to is the zero address
    error MintToZeroAddressError();

    /// @dev Modifier to restrict calls to only the authorized Liquid contract.
    modifier onlyLiquid() {
        if (msg.sender != liquid) {
            revert CallerNotLiquid();
        }

        _;
    }

    /**
     * @notice Constructor that sets the Liquid address and initializes the ERC721 token.
     * @param liquid_ The address of the Liquid contract.
     */
    constructor(address liquid_) ERC721("LiquidPosition", "LQPOS") {
        if (liquid_ == address(0)) {
            revert LiquidZeroAddressError();
        }
        liquid = liquid_;
    }

    /**
     * @notice Mints a new position NFT to `to`.
     * @dev Only callable by the Liquid contract.
     * @param to The recipient address for the new position.
     * @return tokenId The unique token id minted.
     */
    function mint(address to) external onlyLiquid returns (uint256) {
        if (to == address(0)) {
            revert MintToZeroAddressError();
        }
        _currentTokenId++;
        uint256 tokenId = _currentTokenId;
        _mint(to, tokenId);
        return tokenId;
    }

    function burn(uint256 tokenId) public onlyLiquid {
        _burn(tokenId);
    }

    /**
     * @notice Returns the token URI with embedded SVG
     * @param tokenId The token ID
     * @return The full token URI with data
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // revert if the token does not exist
        ERC721(address(this)).ownerOf(tokenId);
        return NFTMetadataGenerator.generateTokenURI(tokenId, "Liquid Position");
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
            ILiquid(liquid).resetMintAllowances(tokenId);
        }
        // Call parent implementation first
        return super._update(to, tokenId, auth);
    }
}
