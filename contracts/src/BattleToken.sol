// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

interface IPancakeFactory {
    function createPair(address a, address b) external returns (address);
    function getPair(address a, address b) external view returns (address);
}

/// @title BATTLE token — fixed supply 1,000,000,000, no mint function, no tax, burnable.
/// The PancakeSwap BATTLE/WBNB pair is created in the constructor. Until the launcher (the NFT
/// contract) opens trading, nobody can send BATTLE into that pair, so nobody can pre-seed the pool
/// at a bad price. The launcher can only open trading once; there is no owner.
contract BattleToken is ERC20, ERC20Burnable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    address public immutable pair;
    address public immutable deployer;
    address public launcher;          // set once by deployer (the NFT contract)
    bool public tradingOpen;

    event LauncherSet(address launcher);
    event TradingOpened();

    constructor(address factory, address wbnb) ERC20("AgentBattle Token", "BATTLE") {
        deployer = msg.sender;
        address p = IPancakeFactory(factory).getPair(address(this), wbnb);
        if (p == address(0)) p = IPancakeFactory(factory).createPair(address(this), wbnb);
        pair = p;
        _mint(msg.sender, TOTAL_SUPPLY); // deployer splits it to NFT / vesting / arena in the deploy script
    }

    function setLauncher(address l) external {
        require(msg.sender == deployer, "only deployer");
        require(launcher == address(0) && l != address(0), "set once");
        launcher = l;
        emit LauncherSet(l);
    }

    function openTrading() external {
        require(msg.sender == launcher, "only launcher");
        require(!tradingOpen, "already open");
        tradingOpen = true;
        emit TradingOpened();
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!tradingOpen && to == pair) {
            require(from == launcher, "trading not open");
        }
        super._update(from, to, value);
    }
}
