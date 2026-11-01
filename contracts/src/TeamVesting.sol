// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Team vesting — 100M BATTLE in 12 equal tranches, one every 30 days after start.
/// No owner. Anyone may call release(); tokens always go to the fixed beneficiary.
contract TeamVesting {
    using SafeERC20 for IERC20;

    uint256 public constant TRANCHES = 12;
    uint256 public constant PERIOD = 30 days;
    uint256 public constant TOTAL = 100_000_000 ether;

    IERC20 public immutable token;
    address public immutable beneficiary;
    uint256 public immutable start;
    uint256 public released;

    event Released(uint256 amount, uint256 totalReleased);

    constructor(address token_, address beneficiary_, uint256 start_) {
        require(token_ != address(0) && beneficiary_ != address(0), "zero");
        token = IERC20(token_);
        beneficiary = beneficiary_;
        start = start_;
    }

    function vested() public view returns (uint256) {
        if (block.timestamp < start) return 0;
        uint256 n = (block.timestamp - start) / PERIOD;
        if (n > TRANCHES) n = TRANCHES;
        return (TOTAL * n) / TRANCHES;
    }

    function releasable() public view returns (uint256) { return vested() - released; }

    function release() external {
        uint256 amt = releasable();
        require(amt > 0, "nothing vested");
        released += amt;
        token.safeTransfer(beneficiary, amt);
        emit Released(amt, released);
    }
}
