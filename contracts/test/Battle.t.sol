// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BattleToken} from "../src/BattleToken.sol";
import {BattleNFT} from "../src/BattleNFT.sol";
import {Arena} from "../src/Arena.sol";
import {TeamVesting} from "../src/TeamVesting.sol";
import {MockAgentRegistry} from "../src/MockAgentRegistry.sol";

interface IPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function sync() external;
    function mint(address) external returns (uint256);
}
interface IWBNBt { function deposit() external payable; function transfer(address, uint256) external returns (bool); }
interface IRouter {
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
    function swapExactETHForTokens(uint256, address[] calldata, address, uint256) external payable returns (uint256[] memory);
    function addLiquidityETH(address, uint256, uint256, uint256, address, uint256) external payable returns (uint256, uint256, uint256);
}

/// Run with: forge test --fork-url https://bsc-testnet-rpc.publicnode.com
contract BattleTest is Test {
    address constant FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address constant ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address constant ADMIN = address(0xaD000000000000000000000000000000000000AD);
    address constant OPS = address(0x0b50000000000000000000000000000000000b05);

    uint256 constant FREE = 5;
    uint256 constant LAUNCH = 10;
    uint256 constant MAX = 30;

    BattleToken tok;
    BattleNFT nft;
    Arena arena;
    TeamVesting vest;
    MockAgentRegistry reg;
    uint256 start;

    function setUp() public {
        start = block.timestamp;
        reg = new MockAgentRegistry();
        tok = new BattleToken(FACTORY, WBNB);
        nft = new BattleNFT(address(reg), address(tok), ROUTER, WBNB, ADMIN, FREE, LAUNCH, MAX, "");
        vest = new TeamVesting(address(tok), ADMIN, start);
        arena = new Arena(address(nft), address(tok), OPS, start);
        tok.setLauncher(address(nft));
        tok.transfer(address(vest), 100_000_000 ether);
        tok.transfer(address(arena), 50_000_000 ether);
        tok.transfer(address(nft), 850_000_000 ether);
        nft.setMintOpen(true);
    }

    function _user(uint256 i) internal returns (address u, string memory label) {
        u = address(uint160(uint256(keccak256(abi.encode("user", i)))));
        label = string(abi.encodePacked("agent", vm.toString(i)));
        vm.deal(u, 1 ether);
        vm.prank(u);
        reg.register(label);
    }

    function _pl(uint256 i) internal pure returns (string memory) { return string(abi.encodePacked("pl", vm.toString(i))); }

    function test_joinRequiresAgentId() public {
        (address[] memory us, uint256[] memory ids) = _launchAndPlayers(2);
        vm.prank(us[0]); vm.expectRevert("not Agent ID owner"); arena.join(ids[0], _pl(1));
        vm.prank(us[0]); vm.expectRevert(); arena.join(ids[0], "nobody");
        vm.prank(us[1]); vm.expectRevert(); arena.join(ids[1], "");
        vm.prank(us[0]); arena.join(ids[0], _pl(0));
        assertEq(arena.roomOf(ids[0]), 1);
    }

    function _freePhase() internal {
        for (uint256 i; i < FREE; ++i) {
            (address u, string memory l) = _user(i);
            vm.prank(u);
            nft.freeMint(l);
        }
    }

    function _path() internal view returns (address[] memory p) {
        p = new address[](2); p[0] = WBNB; p[1] = address(tok);
    }

    function test_distribution() public view {
        assertEq(tok.totalSupply(), 1_000_000_000 ether);
        assertEq(tok.balanceOf(address(this)), 0);
        assertGe(tok.balanceOf(address(nft)), nft.requiredBattle());
    }

    function test_freeMintRules() public {
        (address u, string memory l) = _user(1);
        vm.prank(u); nft.freeMint(l);
        assertEq(tok.balanceOf(u), 10_000 ether);
        vm.prank(u); vm.expectRevert("free already claimed"); nft.freeMint(l);
        (address v,) = _user(2);
        vm.prank(v); vm.expectRevert("not Agent ID owner"); nft.freeMint(l);
        vm.prank(u); vm.expectRevert("free phase"); nft.paidMint{value: 0.001 ether}(l, 1, 0);
    }

    function test_noPreLaunchPool() public {
        _freePhase();
        address u = address(uint160(uint256(keccak256(abi.encode("user", uint256(0))))));
        // cannot send BATTLE into the pair before launch
        address pair = tok.pair();
        vm.prank(u); vm.expectRevert("trading not open"); tok.transfer(pair, 1 ether);
        // router add liquidity also blocked
        vm.startPrank(u);
        tok.approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        IRouter(ROUTER).addLiquidityETH{value: 0.01 ether}(address(tok), 1000 ether, 0, 0, u, block.timestamp);
        vm.stopPrank();
    }

    function test_launchFlowAndDonationGrief() public {
        _freePhase();
        // attacker donates WBNB and syncs before launch
        address pair = tok.pair();
        address att = address(0xBAd00000000000000000000000000000000000bd);
        vm.deal(att, 1 ether);
        vm.startPrank(att);
        IWBNBt(WBNB).deposit{value: 0.01 ether}();
        IWBNBt(WBNB).transfer(pair, 0.01 ether);
        IPair(pair).sync();
        vm.expectRevert(); IPair(pair).mint(att); // cannot mint LP with only WBNB
        vm.stopPrank();

        (address u, string memory l) = _user(100);
        vm.prank(u); nft.paidMint{value: 0.004 ether}(l, 4, 0);
        assertEq(tok.balanceOf(u), 200_000 ether);
        assertFalse(nft.launched());
        uint256 burnedBefore = tok.totalSupply();
        // crosses launch: 1 pre-launch + 1 post-launch (6 = default per-agent cap)
        uint256 quoteMin = 1; 
        vm.prank(u); nft.paidMint{value: 0.002 ether}(l, 2, quoteMin);
        assertTrue(nft.launched());
        assertTrue(tok.tradingOpen());
        assertEq(tok.balanceOf(address(nft)), 0, "rest burned");
        assertLt(tok.totalSupply(), burnedBefore);
        // pool: 5 phase-B mints -> 175,000 BATTLE, 0.0035 BNB (+ donation)
        (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
        (uint256 rT, uint256 rB) = IPair(pair).token0() == address(tok) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        assertGt(rB, 0.0035 ether); // includes donation + the swap
        assertLt(rT, 175_000 ether);
        assertEq(IPair(pair).balanceOf(address(0xdEaD)) > 0, true);
        assertGt(tok.balanceOf(u), 250_000 ether); // 5*50k + swap output
        // admin: 5*0.0003 + 1*0.0001
        assertEq(nft.adminOwed(), 0.0016 ether);
        nft.withdrawAdmin();
        assertEq(ADMIN.balance, 0.0016 ether);
        assertEq(address(nft).balance, 0);
    }

    function test_launchPriceMatchesMint() public {
        _freePhase();
        (address u, string memory l) = _user(100);
        vm.prank(u); nft.paidMint{value: 0.005 ether}(l, 5, 0);
        assertTrue(nft.launched());
        address pair = tok.pair();
        (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
        (uint256 rT, uint256 rB) = IPair(pair).token0() == address(tok) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        assertEq(rT, 175_000 ether);
        assertEq(rB, 0.0035 ether);
        // price = 0.0035 / 175,000 = 0.001 / 50,000
        assertEq(rB * 50_000 ether / rT, 0.001 ether);
        // supply = 1B - burned rest. Paid out: 5*10k + 5*50k = 300k; pool 175k; vest 100M; arena 50M
        assertEq(tok.totalSupply(), 150_000_000 ether + 300_000 ether + 175_000 ether);
    }

    function test_minOutProtects() public {
        _freePhase();
        (address u, string memory l) = _user(100);
        vm.prank(u); nft.paidMint{value: 0.005 ether}(l, 5, 0);
        uint256[] memory q = IRouter(ROUTER).getAmountsOut(0.0009 ether, _path());
        // a sandwicher buys first
        address mev = address(0xE100000000000000000000000000000000000E10);
        vm.deal(mev, 1 ether);
        vm.prank(mev); IRouter(ROUTER).swapExactETHForTokens{value: 0.002 ether}(0, _path(), mev, block.timestamp);
        vm.prank(u); vm.expectRevert(); nft.paidMint{value: 0.001 ether}(l, 1, q[1] * 97 / 100);
        assertEq(nft.totalSupply(), 10);
    }

    function test_agentLimitAndCap() public {
        _freePhase();
        (address u, string memory l) = _user(100);
        vm.prank(u); vm.expectRevert("agent limit"); nft.paidMint{value: 0.011 ether}(l, 11, 0);
        vm.expectRevert("1..20"); nft.setMaxPaidPerAgent(21);
        nft.lockURI();
        vm.expectRevert("locked"); nft.setBaseURI("x");
        vm.prank(u); vm.expectRevert(); nft.setMintOpen(false);
    }

    function test_vesting() public {
        assertEq(vest.releasable(), 0);
        vm.warp(start + 30 days);
        vest.release();
        assertEq(tok.balanceOf(ADMIN), uint256(100_000_000 ether) / 12);
        vm.warp(start + 400 days);
        vest.release();
        assertEq(tok.balanceOf(ADMIN), 100_000_000 ether);
        vm.expectRevert("nothing vested"); vest.release();
    }

    // ---------- arena ----------
    function _launchAndPlayers(uint256 n) internal returns (address[] memory us, uint256[] memory ids) {
        _freePhase(); // ids 1..5 owned by users 0..4
        (address w, string memory l) = _user(100);
        vm.prank(w); nft.paidMint{value: 0.005 ether}(l, 5, 0); // ids 6..10
        us = new address[](n); ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            us[i] = address(uint160(uint256(keccak256(abi.encode("player", i)))));
            vm.prank(us[i]); reg.register(_pl(i));
            ids[i] = i + 1;
            address owner = nft.ownerOf(i + 1);
            vm.prank(owner); nft.transferFrom(owner, us[i], i + 1);
            deal(address(tok), us[i], 100_000 ether);
            vm.startPrank(us[i]);
            tok.approve(address(arena), type(uint256).max);
            nft.setApprovalForAll(address(arena), true);
            uint256[] memory one = new uint256[](1); one[0] = i + 1;
            arena.stake(one);
            vm.stopPrank();
        }
    }

    function _hash(uint256 roomId) internal {
        (, uint256 tb,,,,,) = arena.getRoom(roomId);
        vm.roll(tb + 2);
        vm.setBlockhash(tb, keccak256(abi.encode("h", tb)));
    }

    function test_roomSettlesAndScores() public {
        (address[] memory us, uint256[] memory ids) = _launchAndPlayers(10);
        uint256 opsBefore = tok.balanceOf(OPS);
        for (uint256 i; i < 10; ++i) { vm.prank(us[i]); arena.join(ids[i], _pl(i)); }
        _hash(0);
        arena.settle(0);
        (,, Arena.Status st, uint8 wi,,,) = arena.getRoom(0);
        assertEq(uint256(st), 2);
        assertEq(tok.balanceOf(us[wi]), 100_000 ether - 10_000 ether + 95_000 ether);
        assertEq(tok.balanceOf(OPS) - opsBefore, 3_000 ether);
        (address[10] memory top, int256[10] memory sc) = arena.topOf(0);
        assertEq(top[0], us[wi]);
        assertEq(sc[0], 85_000 ether);
        assertEq(top[1], address(0)); // losers negative -> not ranked
    }

    function test_selfPlayScoresNegative() public {
        _freePhase();
        (address w, string memory l) = _user(100);
        vm.prank(w); nft.paidMint{value: 0.005 ether}(l, 5, 0);
        // whale collects all 10 NFTs
        for (uint256 i = 1; i <= 5; ++i) { address o = nft.ownerOf(i); vm.prank(o); nft.transferFrom(o, w, i); }
        deal(address(tok), w, 1_000_000 ether);
        vm.startPrank(w);
        tok.approve(address(arena), type(uint256).max);
        nft.setApprovalForAll(address(arena), true);
        uint256[] memory all = new uint256[](10);
        for (uint256 i; i < 10; ++i) all[i] = i + 1;
        arena.stake(all);
        assertEq(arena.multiplierOf(w), 13000);
        for (uint256 i; i < 10; ++i) arena.join(i + 1, l);
        vm.stopPrank();
        _hash(0);
        arena.settle(0);
        assertLt(arena.scoreOf(0, w), 0);
        (address[10] memory top,) = arena.topOf(0);
        assertEq(top[0], address(0));
    }

    function test_claimAndSweep() public {
        (address[] memory us, uint256[] memory ids) = _launchAndPlayers(10);
        for (uint256 i; i < 10; ++i) { vm.prank(us[i]); arena.join(ids[i], _pl(i)); }
        _hash(0);
        arena.settle(0);
        (,,, uint8 wi,,,) = arena.getRoom(0);
        vm.prank(us[wi]); vm.expectRevert("week not over"); arena.claim(0);
        vm.warp(start + 7 days);
        uint256 b = tok.balanceOf(us[wi]);
        vm.prank(us[wi]); arena.claim(0);
        assertEq(tok.balanceOf(us[wi]) - b, 250_000 ether);
        vm.prank(us[wi]); vm.expectRevert("claimed"); arena.claim(0);
        uint256 other = wi == 0 ? 1 : 0;
        vm.prank(us[other]); vm.expectRevert("not in top 10"); arena.claim(0);
        vm.expectRevert("too early"); arena.sweep(0);
        vm.warp(start + 5 * 7 days);
        arena.sweep(0);
        assertEq(arena.bonus(5), 750_000 ether);
        assertEq(arena.weekPool(5), 1_750_000 ether);
        vm.prank(us[wi]); vm.expectRevert("claim expired"); arena.claim(0);
    }

    function test_multiplierSnapshotAndStakeLock() public {
        (address[] memory us,) = _launchAndPlayers(3);
        // move 2 NFTs to us[0]? they are staked; unstake locked for 1 day
        uint256[] memory one = new uint256[](1); one[0] = 2;
        vm.prank(us[1]); vm.expectRevert("stake locked 1 day"); arena.unstake(one);
        vm.warp(block.timestamp + 1 days);
        vm.prank(us[1]); arena.unstake(one);
        assertEq(nft.ownerOf(2), us[1]);
    }

    function test_directTransferCountsAsStake() public {
        (address[] memory us,) = _launchAndPlayers(1);
        address w = nft.ownerOf(6);
        vm.prank(w); nft.safeTransferFrom(w, address(arena), 6);
        assertEq(arena.stakerOf(6), w);
        assertEq(arena.stakedOf(w).length, 1);
        us; 
    }

    function test_leaveRefundAndPause() public {
        (address[] memory us, uint256[] memory ids) = _launchAndPlayers(2);
        vm.prank(us[0]); arena.join(ids[0], _pl(0));
        arena.pause();
        vm.prank(us[1]); vm.expectRevert(); arena.join(ids[1], _pl(1));
        vm.prank(us[0]); arena.leaveRoom(ids[0]);
        assertEq(tok.balanceOf(us[0]), 100_000 ether);
        vm.expectRevert("entry out of range"); arena.setEntry(1);
    }

    function test_staleRoomRerollThenJoin() public {
        (address[] memory us, uint256[] memory ids) = _launchAndPlayers(10);
        for (uint256 i; i < 10; ++i) { vm.prank(us[i]); arena.join(ids[i], _pl(i)); }
        vm.roll(block.number + 300);
        vm.prank(us[0]); arena.join(ids[0], _pl(0)); // deferred, rerolled
        (,, Arena.Status st,,,,) = arena.getRoom(0);
        assertEq(uint256(st), 1);
        _hash(0);
        vm.prank(us[0]); arena.join(ids[0], _pl(0));
        (,, st,,,,) = arena.getRoom(0);
        assertEq(uint256(st), 2);
        assertEq(arena.roomOf(ids[0]), 2); // now in room 1
    }

    function test_onchainTokenURI() public {
        _freePhase();
        string memory u = nft.tokenURI(1);
        assertEq(bytes(u).length > 200, true);
        console.log(u);
    }
}
