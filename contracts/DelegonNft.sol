// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract DelegonNFT is ERC721Enumerable, Ownable {
    uint256 public nextTokenId;

    // Extended stats including critical hit chance and evasion.
    struct Stats {
        uint8 atk;       // Attack stat.
        uint8 def;       // Defense stat.
        uint8 spd;       // Speed stat.
        string element;  // Element type.
        uint8 crit;      // Critical hit chance (percentage; 0-100).
        uint8 evasion;   // Chance to evade an incoming attack (percentage; 0-100).
    }

    mapping(uint256 => Stats) public delegonStats;

    constructor() ERC721("Delegons", "DLGN") {}

    /// @dev Mints a new Delegon NFT with extended stats.
    function mint(
        address to,
        uint8 _atk,
        uint8 _def,
        uint8 _spd,
        string memory _element,
        uint8 _crit,
        uint8 _evasion
    ) external onlyOwner {
        uint256 tokenId = nextTokenId++;
        _safeMint(to, tokenId);
        delegonStats[tokenId] = Stats(_atk, _def, _spd, _element, _crit, _evasion);
    }

    /// @dev Returns the stats for a given tokenId.
    function getStats(uint256 tokenId) external view returns (Stats memory) {
        return delegonStats[tokenId];
    }
}
