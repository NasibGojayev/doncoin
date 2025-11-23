// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
  Simple Quadratic-Funding-style smart contract for Remix demo.
  - Owner can create proposals and top up the matching pool.
  - Anyone can donate to a proposal (payable).
  - Donations are stored on-chain as records (lightweight).
  - Owner can calculate and distribute match funds (example algorithm).
  - Emits events for every on-chain action so off-chain indexers can read logs.

  NOTES:
  - All amounts are in wei.
  - This is an educational/demo contract. Replace matching logic with production-safe math.
*/

contract SimpleQF {
    address public owner;
    uint256 public matchingPool; // total available matching funds (wei)
    uint256 public proposalCount;
    bool public paused;

    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string metadata; // optional (ipfs hash/JSON)
        uint256 totalDonations; // sum of donated wei
        bool funded;
        uint256 payoutAmount; // amount paid out (wei)
    }

    struct Donation {
        address donor;
        uint256 amount;
        uint256 timestamp;
    }

    // proposalId => Proposal
    mapping(uint256 => Proposal) public proposals;
    // proposalId => array of donations (we store limited data via mapping to keep gas reasonable)
    mapping(uint256 => Donation[]) internal donations;

    // per-donor-per-proposal aggregate (for easier off-chain read)
    mapping(uint256 => mapping(address => uint256)) public donatedBy;

    // Events (useful for indexer / frontend)
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string title);
    event Donated(uint256 indexed proposalId, address indexed donor, uint256 amount, uint256 timestamp, bytes32 txRef);
    event MatchingToppedUp(address indexed by, uint256 amount);
    event MatchCalculated(uint256 indexed proposalId, uint256 matchAmount);
    event PayoutSent(uint256 indexed proposalId, address indexed to, uint256 amount);
    event Paused(bool isPaused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "owner only");
        _;
    }

    modifier notPaused() {
        require(!paused, "contract paused");
        _;
    }

    constructor() {
        owner = msg.sender;
        proposalCount = 0;
        matchingPool = 0;
        paused = false;
    }

    // ---------- Owner / Admin ----------
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero addr");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    // Top up matching pool (owner sends ETH when calling)
    function topUpMatchingPool() external payable onlyOwner {
        require(msg.value > 0, "no funds");
        matchingPool += msg.value;
        emit MatchingToppedUp(msg.sender, msg.value);
    }

    // Withdraw contract ETH (owner) - safety to extract leftover funds
    function withdraw(uint256 amount, address payable to) external onlyOwner {
        require(amount <= address(this).balance, "insufficient contract balance");
        require(to != address(0), "zero addr");
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "transfer failed");
    }

    // ---------- Proposals ----------
    function createProposal(string calldata title, string calldata metadata) external notPaused returns (uint256) {
        proposalCount += 1;
        Proposal storage p = proposals[proposalCount];
        p.id = proposalCount;
        p.proposer = msg.sender;
        p.title = title;
        p.metadata = metadata;
        p.totalDonations = 0;
        p.funded = false;
        p.payoutAmount = 0;

        emit ProposalCreated(proposalCount, msg.sender, title);
        return proposalCount;
    }

    // ---------- Donations ----------
    // txRef is an optional bytes32 identifier from off-chain (e.g., tx hash in another chain) — put 0 if none
    function donate(uint256 proposalId, bytes32 txRef) external payable notPaused {
        require(msg.value > 0, "donation must be > 0");
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "proposal not exists");

        // store donation record
        donations[proposalId].push(Donation({
            donor: msg.sender,
            amount: msg.value,
            timestamp: block.timestamp
        }));

        p.totalDonations += msg.value;
        donatedBy[proposalId][msg.sender] += msg.value;

        emit Donated(proposalId, msg.sender, msg.value, block.timestamp, txRef);
    }

    // Read donations count for a proposal
    function getDonationCount(uint256 proposalId) external view returns (uint256) {
        return donations[proposalId].length;
    }

    // Read donation by index (helps frontends)
    function getDonationAt(uint256 proposalId, uint256 index) external view returns (address donor, uint256 amount, uint256 timestamp) {
        Donation storage d = donations[proposalId][index];
        return (d.donor, d.amount, d.timestamp);
    }

    // ---------- Matching & Payout ----------
    // Example simple matching algorithm:
    // - For demo: matchAmount = min(matchingPool, sqrt(totalDonations) * SCALE - totalDonations)
    // This is a toy example. Real-world quadratic funding uses sum(sqrt(each donor's contribution))^2 - sum(contributions).
    // For gas reasons, we do a simplified approach here.
    function calculateMatch(uint256 proposalId) public view returns (uint256) {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "proposal not exists");
        uint256 total = p.totalDonations;
        if (total == 0) return 0;

        // Simple illustrative formula:
        // match = (sqrt(total) * 1e9) - total  [use integer math carefully]
        // We'll compute floor(sqrt(total)) and then derive match
        uint256 s = sqrt(total);
        uint256 pseudoMatch = 0;

        // compute pseudoMatch = s * 1e12 - total (scale factor chosen to avoid underflow)
        // NOTE: choose conservative factors so pseudoMatch doesn't overflow
        if (s > 0) {
            // scale = 1e12
            uint256 scaled = s * 1_000_000_000_000;
            if (scaled > total) {
                pseudoMatch = scaled - total;
            } else {
                pseudoMatch = 0;
            }
        }

        // final match is min(pseudoMatch, matchingPool)
        if (pseudoMatch > matchingPool) {
            return matchingPool;
        }
        return pseudoMatch;
    }

    // Owner triggers match calculation and pays out to proposer (or a chosen recipient)
    function payOutProposal(uint256 proposalId, address payable recipient) external onlyOwner notPaused {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "proposal not exists");
        require(!p.funded, "already funded");

        uint256 matchAmount = calculateMatch(proposalId);
        uint256 totalPayout = p.totalDonations + matchAmount;

        // check contract balance
        require(address(this).balance >= totalPayout, "insufficient contract balance");

        // deduct match funds
        if (matchAmount > 0) {
            require(matchingPool >= matchAmount, "not enough matching pool");
            matchingPool -= matchAmount;
        }

        // mark funded and payout
        p.funded = true;
        p.payoutAmount = totalPayout;

        // transfer donations + match to recipient
        // For simplicity we transfer totalPayout in one tx. In production you may want to transfer only match
        (bool sent, ) = recipient.call{value: totalPayout}("");
        require(sent, "payout failed");

        emit MatchCalculated(proposalId, matchAmount);
        emit PayoutSent(proposalId, recipient, totalPayout);
    }

    // ---------- Utilities ----------
    // integer sqrt (Babylonian method)
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    // receive fallback
    receive() external payable {
        // allow contract to receive ETH (owner -> top up matching pool should be used)
    }
}
