// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {BattleToken} from "../src/BattleToken.sol";
import {BattleNFT} from "../src/BattleNFT.sol";
import {Arena} from "../src/Arena.sol";
import {TeamVesting} from "../src/TeamVesting.sol";

/// env: REGISTRY, FACTORY, ROUTER, WBNB, ADMIN, FREE, LAUNCH, MAX, LB_START, BASE_URI
contract Deploy is Script {
    function run() external {
        address registry = vm.envAddress("REGISTRY");
        address factory = vm.envAddress("FACTORY");
        address router = vm.envAddress("ROUTER");
        address wbnb = vm.envAddress("WBNB");
        address admin = vm.envAddress("ADMIN");
        uint256 free = vm.envUint("FREE");
        uint256 launch = vm.envUint("LAUNCH");
        uint256 max = vm.envUint("MAX");
        uint256 lbStart = vm.envUint("LB_START");
        string memory uri = vm.envString("BASE_URI");

        vm.startBroadcast();
        BattleToken tok = new BattleToken(factory, wbnb);
        BattleNFT nft = new BattleNFT(registry, address(tok), router, wbnb, admin, free, launch, max, uri);
        TeamVesting vest = new TeamVesting(address(tok), admin, block.timestamp);
        Arena arena = new Arena(address(nft), address(tok), admin, lbStart);
        tok.setLauncher(address(nft));
        tok.transfer(address(vest), 100_000_000 ether);
        tok.transfer(address(arena), 50_000_000 ether);
        tok.transfer(address(nft), 850_000_000 ether);
        if (vm.envOr("MINT_OPEN", true)) nft.setMintOpen(true);
        vm.stopBroadcast();

        console.log("BATTLE", address(tok));
        console.log("PAIR", tok.pair());
        console.log("NFT", address(nft));
        console.log("VESTING", address(vest));
        console.log("ARENA", address(arena));
    }
}
