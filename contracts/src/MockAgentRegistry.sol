// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// TESTNET ONLY: anyone can register a test ".ai" label (tokenId = keccak256(label)).
contract MockAgentRegistry is ERC721 {
    constructor() ERC721("Test Agent ID", "tAI") {}
    function register(string calldata label) external {
        _mint(msg.sender, uint256(keccak256(bytes(label))));
    }
}
