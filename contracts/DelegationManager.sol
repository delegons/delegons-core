// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

contract DelegationManager {
    mapping(uint256 => address) public delegations;

    event Delegated(uint256 tokenId, address warlord);
    event Revoked(uint256 tokenId);

    function delegate(uint256 tokenId, address warlord) external {
        delegations[tokenId] = warlord;
        emit Delegated(tokenId, warlord);
    }

    function revoke(uint256 tokenId) external {
        delete delegations[tokenId];
        emit Revoked(tokenId);
    }
}
