// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

interface IBattle is IERC20 {
    function pair() external view returns (address);
    function openTrading() external;
    function burn(uint256 amount) external;
}
interface IWBNB {
    function deposit() external payable;
    function transfer(address to, uint256 v) external returns (bool);
}
interface IPancakePair { function mint(address to) external returns (uint256); }
interface IPancakeRouter {
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external payable returns (uint256[] memory amounts);
}

/// @title AgentBattle NFT — Agent ID (.ai) gated mint with BATTLE rewards and automatic launch.
///
/// Phase A  #1 .. FREE_SUPPLY          free, 1 per Agent ID, 10,000 BATTLE each
/// Phase B  .. LAUNCH_AT               0.001 BNB, 50,000 BATTLE each; 70% BNB kept for the pool, 30% to admin
/// Launch   when #LAUNCH_AT is minted  pool = all phase-B pool BNB + 35,000 BATTLE per phase-B mint
///                                     (same price as the mint reward), LP sent to 0xdead,
///                                     all remaining BATTLE in this contract burned, trading opened
/// Phase C  .. MAX_SUPPLY              0.001 BNB: 90% swapped to BATTLE for the minter (minOut), 10% to admin
///
/// Mainnet: FREE_SUPPLY 5,000, LAUNCH_AT 8,000, MAX_SUPPLY 20,000. Testnet uses smaller numbers.
contract BattleNFT is ERC721, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE = 0.001 ether;
    uint256 public constant FREE_REWARD = 10_000 ether;
    uint256 public constant PAID_REWARD = 50_000 ether;
    uint256 public constant POOL_TOKENS_PER_MINT = 35_000 ether; // 70% of 50,000 -> pool price = mint price
    uint256 public constant POOL_BNB_PER_MINT = 0.0007 ether;     // 70% of PRICE
    uint256 public constant SWAP_BNB_PER_MINT = 0.0009 ether;     // 90% of PRICE after launch
    uint256 public constant MAX_PAID_CAP = 20;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public immutable FREE_SUPPLY;
    uint256 public immutable LAUNCH_AT;
    uint256 public immutable MAX_SUPPLY;

    IERC721 public immutable agentRegistry; // .ai Agent ID NFT (tokenId = uint256(keccak256(label)))
    IBattle public immutable battle;
    IPancakeRouter public immutable router;
    address public immutable wbnb;

    address public admin;
    uint256 public adminOwed;       // BNB owed to admin (pull)
    uint256 public poolBNB;         // BNB reserved for launch
    bool public launched;

    uint256 public totalSupply;
    uint256 public maxPaidPerAgent = 6;
    bool public mintOpen;
    bool public uriLocked;
    string private baseURI;

    mapping(uint256 => bool) public freeClaimed;     // agentTokenId => used free mint
    mapping(uint256 => uint256) public paidMinted;   // agentTokenId => paid count

    event Minted(address indexed to, uint256 indexed agentId, uint256 firstTokenId, uint256 qty, bool free, uint256 battleOut);
    event Launched(address pair, uint256 bnb, uint256 tokens, uint256 burned, uint256 lp);
    event AdminPaid(address to, uint256 amount);

    constructor(
        address registry, address battle_, address router_, address wbnb_, address admin_,
        uint256 freeSupply, uint256 launchAt, uint256 maxSupply, string memory uri
    ) ERC721("AgentBattle", "AGB") Ownable(msg.sender) {
        require(freeSupply < launchAt && launchAt <= maxSupply, "bad phases");
        require(admin_ != address(0), "zero admin");
        agentRegistry = IERC721(registry);
        battle = IBattle(battle_);
        router = IPancakeRouter(router_);
        wbnb = wbnb_;
        admin = admin_;
        FREE_SUPPLY = freeSupply;
        LAUNCH_AT = launchAt;
        MAX_SUPPLY = maxSupply;
        baseURI = uri;
    }

    /// BATTLE this contract must hold before minting opens.
    function requiredBattle() public view returns (uint256) {
        uint256 paidB = LAUNCH_AT - FREE_SUPPLY;
        return FREE_SUPPLY * FREE_REWARD + paidB * (PAID_REWARD + POOL_TOKENS_PER_MINT);
    }

    // ---------- admin ----------
    function setMintOpen(bool open) external onlyOwner {
        if (open) require(battle.balanceOf(address(this)) >= requiredBattle() || launched, "fund BATTLE first");
        mintOpen = open;
    }
    function setMaxPaidPerAgent(uint256 n) external onlyOwner {
        require(n > 0 && n <= MAX_PAID_CAP, "1..20");
        maxPaidPerAgent = n;
    }
    function setBaseURI(string calldata uri) external onlyOwner { require(!uriLocked, "locked"); baseURI = uri; }
    function lockURI() external onlyOwner { uriLocked = true; }
    function setAdmin(address a) external onlyOwner { require(a != address(0)); admin = a; }

    /// Anyone can push the admin's BNB share to the admin wallet.
    function withdrawAdmin() external nonReentrant {
        uint256 amt = adminOwed;
        require(amt > 0, "nothing");
        adminOwed = 0;
        (bool ok,) = admin.call{value: amt}("");
        require(ok, "send failed");
        emit AdminPaid(admin, amt);
    }

    // ---------- mint ----------
    function agentIdOf(string calldata label) public pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    function _checkAgent(string calldata label) internal view returns (uint256 agentId) {
        agentId = agentIdOf(label);
        require(agentRegistry.ownerOf(agentId) == msg.sender, "not Agent ID owner");
    }

    /// Free mint: 1 per Agent ID while the free supply lasts.
    function freeMint(string calldata label) external nonReentrant {
        require(mintOpen, "mint closed");
        require(totalSupply < FREE_SUPPLY, "free sold out");
        uint256 agentId = _checkAgent(label);
        require(!freeClaimed[agentId], "free already claimed");
        freeClaimed[agentId] = true;
        _mintNFTs(1);
        IERC20(address(battle)).safeTransfer(msg.sender, FREE_REWARD);
        emit Minted(msg.sender, agentId, totalSupply, 1, true, FREE_REWARD);
    }

    /// Paid mint. minOut = minimum BATTLE you accept from the post-launch swap (ignored for
    /// pre-launch NFTs, which pay a fixed 50,000 each). If the swap would give less, the whole tx reverts.
    function paidMint(string calldata label, uint256 qty, uint256 minOut) external payable nonReentrant {
        require(mintOpen, "mint closed");
        require(totalSupply >= FREE_SUPPLY, "free phase");
        require(qty > 0 && totalSupply + qty <= MAX_SUPPLY, "bad qty");
        require(msg.value == PRICE * qty, "wrong value");
        uint256 agentId = _checkAgent(label);
        require(paidMinted[agentId] + qty <= maxPaidPerAgent, "agent limit");
        paidMinted[agentId] += qty;

        uint256 first = totalSupply + 1;
        uint256 nB = totalSupply < LAUNCH_AT ? _min(qty, LAUNCH_AT - totalSupply) : 0;
        uint256 nC = qty - nB;
        uint256 out;

        _mintNFTs(qty);

        if (nB > 0) {
            poolBNB += POOL_BNB_PER_MINT * nB;
            adminOwed += (PRICE - POOL_BNB_PER_MINT) * nB;
            out += PAID_REWARD * nB;
            IERC20(address(battle)).safeTransfer(msg.sender, PAID_REWARD * nB);
            if (totalSupply >= LAUNCH_AT) _launch();
        }
        if (nC > 0) {
            uint256 swapIn = SWAP_BNB_PER_MINT * nC;
            adminOwed += (PRICE - SWAP_BNB_PER_MINT) * nC;
            address[] memory path = new address[](2);
            path[0] = wbnb;
            path[1] = address(battle);
            uint256[] memory amounts =
                router.swapExactETHForTokens{value: swapIn}(minOut, path, msg.sender, block.timestamp);
            out += amounts[1];
        }
        emit Minted(msg.sender, agentId, first, qty, false, out);
    }

    function _mintNFTs(uint256 qty) internal {
        uint256 first = totalSupply + 1;
        totalSupply += qty;
        for (uint256 i; i < qty; ++i) _safeMint(msg.sender, first + i);
    }

    function _launch() internal {
        require(!launched, "launched");
        launched = true;
        address pair = battle.pair();
        uint256 bnb = poolBNB;
        poolBNB = 0;
        uint256 tokens = (LAUNCH_AT - FREE_SUPPLY) * POOL_TOKENS_PER_MINT;

        IWBNB(wbnb).deposit{value: bnb}();
        require(IWBNB(wbnb).transfer(pair, bnb), "wbnb");
        IERC20(address(battle)).safeTransfer(pair, tokens);
        uint256 lp = IPancakePair(pair).mint(DEAD); // LP burned forever

        uint256 rest = battle.balanceOf(address(this));
        if (rest > 0) battle.burn(rest);
        battle.openTrading();
        emit Launched(pair, bnb, tokens, rest, lp);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) { return a < b ? a : b; }
    function _baseURI() internal view override returns (string memory) { return baseURI; }

    /// Fully on-chain art: every token is the same emblem, only the number differs.
    /// If the owner sets a non-empty baseURI, that is used instead.
    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        if (bytes(baseURI).length != 0) return super.tokenURI(id);
        string memory n = Strings.toString(id);
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600">',
            '<defs><radialGradient id="g" cx="50%" cy="38%" r="70%"><stop offset="0" stop-color="#3a0d18"/><stop offset="1" stop-color="#07080c"/></radialGradient></defs>',
            '<rect width="600" height="600" fill="url(#g)"/>',
            '<rect x="18" y="18" width="564" height="564" rx="28" fill="none" stroke="#ff3b5c" stroke-opacity=".5" stroke-width="3"/>',
            '<g transform="translate(300 245)" fill="none" stroke="#ff3b5c" stroke-width="10"><circle r="110"/><circle r="62" stroke="#ffb020"/>',
            '<path d="M0-150V-80M0 80V150M-150 0H-80M80 0H150"/></g><circle cx="300" cy="245" r="14" fill="#ffb020"/>',
            '<text x="300" y="455" text-anchor="middle" font-family="Arial,Helvetica,sans-serif" font-weight="900" font-size="64" fill="#e7eaf2">#', n, '</text>',
            '<text x="300" y="525" text-anchor="middle" font-family="Arial,Helvetica,sans-serif" font-weight="700" font-size="28" letter-spacing="10" fill="#8a93a8">AGENT BATTLE</text></svg>'
        );
        string memory json = string.concat(
            '{"name":"AgentBattle #', n,
            '","description":"10 agents enter, 1 survives. AgentBattle NFT for .ai Agent IDs on BNB Chain.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)), '","attributes":[{"trait_type":"Number","display_type":"number","value":', n, '}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
