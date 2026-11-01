// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAgentGate { function agentRegistry() external view returns (IERC721); }

/// @title AgentBattle Arena (v4) + weekly leaderboard
/// Game (same as v3):
/// - Stake an NFT (stake() or a direct safeTransferFrom). One staked NFT = one seat at a time.
/// - 10 players per room, each pays the room's entry in BATTLE.
/// - When the 10th joins at block N the room locks; result = keccak(blockhash(N + 3), roomId) % 10.
///   If >256 blocks pass before anyone settles, the target block is re-rolled.
/// - Winner 95%, ops wallet 3%, 2% burned. Rooms settle automatically inside later join() calls.
/// Leaderboard:
/// - Weeks start at START (a Monday 00:00 UTC+8) and last 7 days; the week of a room is the week it settles.
/// - Score per seat = net result (winner: prize - entry, others: -entry) x multiplier, where the
///   multiplier is fixed at join time from how many NFTs the player has staked:
///   1-2 => 1.0, 3-4 => 1.1, 5-9 => 1.2, 10+ => 1.3. Self-play always scores negative.
/// - The contract keeps the week's top 10 on-chain. After the week ends each top-10 address claims
///   its share of that week's pool (1,000,000 BATTLE for weeks 0-49, plus any rolled-over amount):
///   25/18/13/10/8/7/6/5/4/4 %. Unclaimed shares can be swept 4 weeks later into the current week.
/// - Staked NFTs can be unstaked only 1 day after staking (stops shuttling NFTs for the multiplier).
contract Arena is Ownable, Pausable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    uint256 public constant PLAYERS = 10;
    uint256 public constant DELAY = 3;
    uint256 public constant WIN_BPS = 9500;
    uint256 public constant OPS_BPS = 300;
    uint256 public constant MIN_ENTRY = 1_000 ether;
    uint256 public constant MAX_ENTRY = 1_000_000 ether;
    uint256 public constant STAKE_LOCK = 1 days;

    uint256 public constant WEEK = 7 days;
    uint256 public constant LB_WEEKS = 50;
    uint256 public constant LB_WEEKLY = 1_000_000 ether;
    uint256 public constant LB_TOTAL = 50_000_000 ether;
    uint256 public constant TOP = 10;
    uint256 public constant CLAIM_WEEKS = 4;

    IERC721 public immutable nft;
    IERC721 public immutable agentRegistry; // .ai Agent ID (tokenId = uint256(keccak256(label))), read from the NFT contract
    IERC20 public immutable battle;
    uint256 public immutable START;
    address public opsWallet;
    uint256 public entry = 10_000 ether;

    enum Status { Open, Locked, Settled }
    struct Room {
        uint256 entry;
        uint64 targetBlock;
        Status status;
        uint8 winnerIndex;
        address[] players;
        uint256[] tokenIds;
        uint16[] mults;      // bps, fixed at join
    }

    uint256 public currentRoom;
    uint256 public nextToSettle;
    mapping(uint256 => Room) internal rooms;
    mapping(uint256 => address) public stakerOf;
    mapping(uint256 => uint256) public stakedAt;
    mapping(uint256 => uint256) public roomOf;   // tokenId => room id + 1 (0 = idle)
    mapping(uint256 => uint256) public wins;
    mapping(address => uint256[]) internal staked;

    // leaderboard
    mapping(uint256 => mapping(address => int256)) public scoreOf;  // week => player => score
    mapping(uint256 => address[TOP]) internal tops;                 // week => sorted top 10
    mapping(uint256 => uint256) public bonus;                       // week => rolled-over BATTLE
    mapping(uint256 => mapping(uint256 => bool)) public claimed;    // week => rank => claimed
    mapping(uint256 => bool) public swept;
    uint256 public lbPaid;

    event Staked(address indexed user, uint256 indexed tokenId);
    event Unstaked(address indexed user, uint256 indexed tokenId);
    event Joined(uint256 indexed roomId, address indexed user, uint256 indexed tokenId, uint256 seat, uint256 multBps);
    event Left(uint256 indexed roomId, address indexed user, uint256 indexed tokenId);
    event Locked(uint256 indexed roomId, uint256 targetBlock);
    event Rerolled(uint256 indexed roomId, uint256 newTargetBlock);
    event JoinDeferred(uint256 indexed roomId, address indexed user, uint256 indexed tokenId);
    event Settled(uint256 indexed roomId, address indexed winner, uint256 indexed tokenId, uint256 prize, bytes32 hash, uint256 week);
    event Claimed(uint256 indexed week, uint256 rank, address indexed user, uint256 amount);
    event Swept(uint256 indexed week, uint256 amount, uint256 toWeek);

    constructor(address nft_, address battle_, address ops, uint256 start_) Ownable(msg.sender) {
        require(ops != address(0), "zero ops");
        nft = IERC721(nft_);
        agentRegistry = IAgentGate(nft_).agentRegistry();
        battle = IERC20(battle_);
        opsWallet = ops;
        START = start_;
        rooms[0].entry = entry;
    }

    // ---------- admin ----------
    function setOpsWallet(address ops) external onlyOwner { require(ops != address(0)); opsWallet = ops; }
    function setEntry(uint256 e) external onlyOwner {
        require(e >= MIN_ENTRY && e <= MAX_ENTRY, "entry out of range");
        entry = e;
        if (rooms[currentRoom].players.length == 0) rooms[currentRoom].entry = e;
    }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ---------- staking ----------
    function stake(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; ++i) {
            nft.transferFrom(msg.sender, address(this), ids[i]);
            _recordStake(msg.sender, ids[i]);
        }
    }

    function _recordStake(address user, uint256 id) internal {
        stakerOf[id] = user;
        stakedAt[id] = block.timestamp;
        staked[user].push(id);
        emit Staked(user, id);
    }

    function unstake(uint256[] calldata ids) external nonReentrant {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            require(stakerOf[id] == msg.sender, "not staker");
            require(roomOf[id] == 0, "in a room");
            require(block.timestamp >= stakedAt[id] + STAKE_LOCK, "stake locked 1 day");
            delete stakerOf[id];
            delete stakedAt[id];
            _removeStaked(msg.sender, id);
            nft.transferFrom(address(this), msg.sender, id);
            emit Unstaked(msg.sender, id);
        }
    }

    function _removeStaked(address user, uint256 id) internal {
        uint256[] storage arr = staked[user];
        for (uint256 i; i < arr.length; ++i) {
            if (arr[i] == id) { arr[i] = arr[arr.length - 1]; arr.pop(); return; }
        }
    }

    function multiplierOf(address user) public view returns (uint256) {
        uint256 n = staked[user].length;
        if (n >= 10) return 13000;
        if (n >= 5) return 12000;
        if (n >= 3) return 11000;
        return 10000;
    }

    // ---------- game ----------
    /// @param label the caller's Agent ID label without ".ai" (e.g. "xxx" for xxx.ai); must be owned by the caller now.
    function join(uint256 tokenId, string calldata label) external nonReentrant whenNotPaused {
        require(stakerOf[tokenId] == msg.sender, "stake NFT first");
        require(agentRegistry.ownerOf(uint256(keccak256(bytes(label)))) == msg.sender, "not Agent ID owner");
        uint256 rid = roomOf[tokenId];
        if (rid != 0) {
            Room storage prev = rooms[rid - 1];
            require(prev.status == Status.Locked, "already in a room");
            require(block.number > prev.targetBlock, "room not settled yet, retry later");
            if (!_settle(rid - 1)) {
                emit JoinDeferred(rid - 1, msg.sender, tokenId);
                return;
            }
        }
        _autoSettle();
        Room storage r = rooms[currentRoom];
        battle.safeTransferFrom(msg.sender, address(this), r.entry);
        uint256 m = multiplierOf(msg.sender);
        r.players.push(msg.sender);
        r.tokenIds.push(tokenId);
        r.mults.push(uint16(m));
        roomOf[tokenId] = currentRoom + 1;
        emit Joined(currentRoom, msg.sender, tokenId, r.players.length - 1, m);

        if (r.players.length == PLAYERS) {
            r.status = Status.Locked;
            r.targetBlock = uint64(block.number + DELAY);
            emit Locked(currentRoom, r.targetBlock);
            currentRoom += 1;
            rooms[currentRoom].entry = entry;
        }
    }

    function leaveRoom(uint256 tokenId) external nonReentrant {
        require(stakerOf[tokenId] == msg.sender, "not staker");
        require(roomOf[tokenId] == currentRoom + 1, "not in open room");
        Room storage r = rooms[currentRoom];
        uint256 n = r.tokenIds.length;
        for (uint256 i; i < n; ++i) {
            if (r.tokenIds[i] == tokenId) {
                r.tokenIds[i] = r.tokenIds[n - 1];
                r.players[i] = r.players[n - 1];
                r.mults[i] = r.mults[n - 1];
                r.tokenIds.pop();
                r.players.pop();
                r.mults.pop();
                break;
            }
        }
        roomOf[tokenId] = 0;
        battle.safeTransfer(msg.sender, r.entry);
        emit Left(currentRoom, msg.sender, tokenId);
    }

    function settle(uint256 roomId) external nonReentrant {
        Room storage r = rooms[roomId];
        require(r.status == Status.Locked, "not locked");
        require(block.number > r.targetBlock, "too early");
        _settle(roomId);
    }

    function _autoSettle() internal {
        uint256 i = nextToSettle;
        uint256 done;
        while (i < currentRoom && done < 2) {
            Room storage r = rooms[i];
            if (r.status == Status.Settled) { ++i; continue; }
            if (block.number <= r.targetBlock) break;
            if (!_settle(i)) break;
            ++i; ++done;
        }
        nextToSettle = i;
    }

    function _settle(uint256 roomId) internal returns (bool) {
        Room storage r = rooms[roomId];
        bytes32 h = blockhash(r.targetBlock);
        if (h == bytes32(0)) {
            r.targetBlock = uint64(block.number + DELAY);
            emit Rerolled(roomId, r.targetBlock);
            return false;
        }
        uint256 idx = uint256(keccak256(abi.encodePacked(h, roomId))) % PLAYERS;
        r.status = Status.Settled;
        r.winnerIndex = uint8(idx);

        uint256 pot = r.entry * PLAYERS;
        uint256 prize = (pot * WIN_BPS) / 10_000;
        uint256 ops = (pot * OPS_BPS) / 10_000;
        uint256 burnAmt = pot - prize - ops;
        address winner = r.players[idx];
        wins[r.tokenIds[idx]] += 1;

        uint256 w = currentWeek();
        for (uint256 i; i < PLAYERS; ++i) {
            roomOf[r.tokenIds[i]] = 0;
            int256 net = i == idx ? int256(prize) - int256(r.entry) : -int256(r.entry);
            _addScore(w, r.players[i], (net * int256(uint256(r.mults[i]))) / 10_000);
        }

        battle.safeTransfer(winner, prize);
        battle.safeTransfer(opsWallet, ops);
        ERC20Burnable(address(battle)).burn(burnAmt);
        emit Settled(roomId, winner, r.tokenIds[idx], prize, h, w);
        return true;
    }

    // ---------- leaderboard ----------
    function currentWeek() public view returns (uint256) {
        return block.timestamp < START ? 0 : (block.timestamp - START) / WEEK;
    }

    function weekPool(uint256 w) public view returns (uint256) {
        return (w < LB_WEEKS ? LB_WEEKLY : 0) + bonus[w];
    }

    function shareBps(uint256 rank) public pure returns (uint256) {
        uint16[10] memory s = [uint16(2500), 1800, 1300, 1000, 800, 700, 600, 500, 400, 400];
        return s[rank];
    }

    function _addScore(uint256 w, address user, int256 delta) internal {
        int256 s = scoreOf[w][user] + delta;
        scoreOf[w][user] = s;
        address[TOP] storage t = tops[w];

        // remove user if present (shift the rest up)
        uint256 i;
        for (; i < TOP; ++i) if (t[i] == user) break;
        if (i < TOP) {
            for (uint256 j = i; j + 1 < TOP; ++j) t[j] = t[j + 1];
            t[TOP - 1] = address(0);
        }
        if (s <= 0) return;

        // insert at sorted position (ties: earlier entrant stays ahead)
        uint256 pos;
        for (; pos < TOP; ++pos) {
            address a = t[pos];
            if (a == address(0) || scoreOf[w][a] < s) break;
        }
        if (pos == TOP) return;
        for (uint256 j = TOP - 1; j > pos; --j) t[j] = t[j - 1];
        t[pos] = user;
    }

    function topOf(uint256 w) external view returns (address[TOP] memory players, int256[TOP] memory scores) {
        players = tops[w];
        for (uint256 i; i < TOP; ++i) if (players[i] != address(0)) scores[i] = scoreOf[w][players[i]];
    }

    function claim(uint256 w) external nonReentrant {
        require(w < currentWeek(), "week not over");
        require(currentWeek() <= w + CLAIM_WEEKS && !swept[w], "claim expired");
        address[TOP] storage t = tops[w];
        uint256 rank = TOP;
        for (uint256 i; i < TOP; ++i) if (t[i] == msg.sender) { rank = i; break; }
        require(rank < TOP, "not in top 10");
        require(!claimed[w][rank], "claimed");
        claimed[w][rank] = true;
        uint256 amt = (weekPool(w) * shareBps(rank)) / 10_000;
        require(lbPaid + amt <= LB_TOTAL, "budget");
        lbPaid += amt;
        battle.safeTransfer(msg.sender, amt);
        emit Claimed(w, rank, msg.sender, amt);
    }

    /// After the claim window, move a week's unclaimed shares into the current week's pool.
    function sweep(uint256 w) external {
        uint256 cw = currentWeek();
        require(cw > w + CLAIM_WEEKS, "too early");
        require(!swept[w], "swept");
        swept[w] = true;
        uint256 pool = weekPool(w);
        uint256 amt;
        for (uint256 i; i < TOP; ++i) if (!claimed[w][i]) amt += (pool * shareBps(i)) / 10_000;
        bonus[cw] += amt;
        emit Swept(w, amt, cw);
    }

    // ---------- views ----------
    function getRoom(uint256 roomId) external view returns (
        uint256 entry_, uint256 targetBlock, Status status, uint8 winnerIndex,
        address[] memory players, uint256[] memory tokenIds, uint16[] memory mults
    ) {
        Room storage r = rooms[roomId];
        return (r.entry, r.targetBlock, r.status, r.winnerIndex, r.players, r.tokenIds, r.mults);
    }
    function stakedOf(address user) external view returns (uint256[] memory) { return staked[user]; }

    /// A direct safeTransferFrom of an AgentBattle NFT counts as staking it for the sender.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(nft), "only AgentBattle NFT");
        _recordStake(from, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }
}
