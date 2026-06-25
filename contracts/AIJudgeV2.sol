// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  AIJudgeV2 — Privacy-Preserving Bounty Judge with Commit-Reveal
// ─────────────────────────────────────────────────────────────────────────────
//
//  LIFECYCLE
//  ─────────
//  1. Bounty owner calls createBounty(title, rubric, deadline) { value: reward }
//  2. Participants call submitCommitment(bountyId, keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)))
//     ↳ Only the hash is stored on-chain. Plaintext is invisible until reveal.
//  3. After block.timestamp >= deadline, participants call revealAnswer(bountyId, answer, salt)
//     ↳ Contract verifies the hash matches, then stores the plaintext answer.
//  4. Bounty owner calls judgeAll(bountyId, llmInput) — one LLM precompile call
//     judges all revealed answers in a single transaction.
//  5. Bounty owner calls finalizeWinner(bountyId, winnerIndex) → pays the winner.
//
// ─────────────────────────────────────────────────────────────────────────────

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

contract AIJudgeV2 is PrecompileConsumer {

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 public constant MAX_SUBMISSIONS  = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    IRitualWallet private constant RITUAL_WALLET =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    // ── State ─────────────────────────────────────────────────────────────────
    uint256 public nextBountyId = 1;

    /// Stores the commitment hash for each (bountyId, participant) pair.
    /// keccak256(abi.encodePacked(answer, salt, participant, bountyId))
    mapping(uint256 => mapping(address => bytes32)) public commitments;

    /// Whether a participant has successfully revealed their answer.
    mapping(uint256 => mapping(address => bool)) public revealed;

    /// Ordered list of submitters per bounty (insertion order = submission order).
    mapping(uint256 => address[]) private submitters;

    struct Submission {
        address submitter;
        string  answer;       // Empty until reveal phase
        bool    hasRevealed;
    }

    struct Bounty {
        address   owner;
        string    title;
        string    rubric;
        uint256   reward;
        uint256   deadline;      // UNIX timestamp after which reveals open
        bool      judged;
        bool      finalized;
        bytes     aiReview;      // Raw LLM completion bytes
        uint256   winnerIndex;   // index into submitters[]
        Submission[] submissions;
    }

    /// @dev Mirrors the (string, string, string) tuple the LLM precompile
    ///      returns for `convoHistory` in its response.
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    mapping(uint256 => Bounty) public bounties;

    // ── Events ────────────────────────────────────────────────────────────────
    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string  title,
        uint256 reward,
        uint256 deadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed participant
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // ── Modifiers ─────────────────────────────────────────────────────────────
    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 0 — Create Bounty
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Create a new bounty. The ETH sent becomes the prize.
    /// @param title    Short title shown to participants.
    /// @param rubric   Judging criteria passed verbatim to the LLM.
    /// @param deadline UNIX timestamp in MILLISECONDS (Ritual uses ms, not seconds).
    ///                 In JS: Date.now() + 3_600_000  (= 1 hour from now)
    ///                 Must be greater than block.timestamp (which is also in ms on Ritual).
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 deadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(deadline > block.timestamp, "deadline must be in the future");

        bountyId = nextBountyId++;

        Bounty storage b = bounties[bountyId];
        b.owner       = msg.sender;
        b.title       = title;
        b.rubric      = rubric;
        b.reward      = msg.value;
        b.deadline    = deadline;
        b.winnerIndex = type(uint256).max; // sentinel: not set

        emit BountyCreated(bountyId, msg.sender, title, msg.value, deadline);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 1 — Submit Commitment (before deadline)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Submit a commitment hash during the submission phase.
    /// @dev    The commitment MUST equal:
    ///         keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
    ///         Compute this off-chain and pass only the hash here.
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(!b.judged,    "already judged");
        require(!b.finalized, "already finalized");
        require(block.timestamp < b.deadline, "submission phase closed");
        require(commitment != bytes32(0),     "empty commitment");
        require(
            commitments[bountyId][msg.sender] == bytes32(0),
            "already committed"
        );
        require(
            submitters[bountyId].length < MAX_SUBMISSIONS,
            "too many submissions"
        );

        commitments[bountyId][msg.sender] = commitment;
        submitters[bountyId].push(msg.sender);

        // Reserve a slot in the submissions array (answer filled on reveal)
        b.submissions.push(Submission({
            submitter:   msg.sender,
            answer:      "",
            hasRevealed: false
        }));

        emit CommitmentSubmitted(bountyId, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 2 — Reveal Answer (after deadline)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Reveal your plaintext answer and salt after the deadline.
    /// @dev    Verifies keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
    ///         against the stored commitment. Reverts if it does not match.
    function revealAnswer(
        uint256        bountyId,
        string calldata answer,
        bytes32        salt
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(block.timestamp >= b.deadline, "reveal phase not open yet");
        require(!b.judged,    "already judged");
        require(!b.finalized, "already finalized");
        require(!revealed[bountyId][msg.sender], "already revealed");
        require(bytes(answer).length > 0,              "answer empty");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        // ── Verify commitment ──────────────────────────────────────────────
        bytes32 expected = commitments[bountyId][msg.sender];
        require(expected != bytes32(0), "no commitment found");

        bytes32 actual = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(actual == expected, "commitment mismatch");

        // ── Store revealed answer ──────────────────────────────────────────
        revealed[bountyId][msg.sender] = true;

        // Find this submitter's slot and fill in the answer
        address[] storage subs = submitters[bountyId];
        for (uint256 i = 0; i < subs.length; i++) {
            if (subs[i] == msg.sender) {
                b.submissions[i].answer      = answer;
                b.submissions[i].hasRevealed = true;
                emit AnswerRevealed(bountyId, i, msg.sender);
                break;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 3 — Judge All Revealed Answers (LLM precompile, SPC)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Judge all revealed answers using the Ritual LLM precompile.
    /// @param  llmInput  ABI-encoded 30-field LLM request (encode off-chain,
    ///                   see README for TypeScript encoder). The `messagesJson`
    ///                   field should contain all revealed answers + rubric.
    /// @dev    One SPC call per transaction. RitualWallet must be funded and
    ///         lock must still be active when this tx is mined. Let viem
    ///         auto-derive fees — do NOT hard-code maxFeePerGas.
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(!b.judged,    "already judged");
        require(!b.finalized, "already finalized");
        require(block.timestamp >= b.deadline, "reveal phase not open yet");

        // Count revealed answers
        uint256 revealedCount = 0;
        for (uint256 i = 0; i < b.submissions.length; i++) {
            if (b.submissions[i].hasRevealed) revealedCount++;
        }
        require(revealedCount > 0, "no revealed answers to judge");

        // ── Call LLM precompile (0x0802, SPC) ─────────────────────────────
        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,
        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        b.judged   = true;
        b.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 4 — Finalize Winner
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Pick the winner (by index into submissions[]) and pay them.
    /// @param  winnerIndex  Must correspond to a revealed submission.
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage b = bounties[bountyId];

        require(b.judged,     "not judged yet");
        require(!b.finalized, "already finalized");
        require(winnerIndex < b.submissions.length, "invalid index");
        require(b.submissions[winnerIndex].hasRevealed, "winner did not reveal");

        b.finalized   = true;
        b.winnerIndex = winnerIndex;

        address winner = b.submissions[winnerIndex].submitter;
        uint256 reward = b.reward;
        b.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  View Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function getBounty(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 deadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage b = bounties[bountyId];
        return (
            b.owner,
            b.title,
            b.rubric,
            b.reward,
            b.deadline,
            b.judged,
            b.finalized,
            b.submissions.length,
            b.winnerIndex,
            b.aiReview
        );
    }

    function getSubmission(uint256 bountyId, uint256 index)
        external
        view
        bountyExists(bountyId)
        returns (
            address submitter,
            string memory answer,
            bool hasRevealed
        )
    {
        Bounty storage b = bounties[bountyId];
        require(index < b.submissions.length, "invalid index");
        Submission storage s = b.submissions[index];
        return (s.submitter, s.answer, s.hasRevealed);
    }

    function getRevealedAnswers(uint256 bountyId)
        external
        view
        bountyExists(bountyId)
        returns (address[] memory addrs, string[] memory answers)
    {
        Bounty storage b = bounties[bountyId];
        uint256 n = b.submissions.length;
        addrs   = new address[](n);
        answers = new string[](n);
        for (uint256 i = 0; i < n; i++) {
            addrs[i]   = b.submissions[i].submitter;
            answers[i] = b.submissions[i].answer;
        }
    }

    /// @notice Helper — compute a commitment hash to verify off-chain calculation.
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address participant,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, participant, bountyId));
    }
}
