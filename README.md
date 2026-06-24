# Privacy-Preserving AI Bounty Judge

A commit-reveal bounty system with on-chain AI judging via Ritual Chain's LLM precompile.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Ritual Chain (1979)                     │
│                                                             │
│  ┌──────────────────────────────────────────┐               │
│  │              AIJudgeV2.sol               │               │
│  │                                          │               │
│  │  Phase 1: submitCommitment()             │               │
│  │    → stores keccak256(answer||salt||     │               │
│  │      sender||bountyId) ONLY              │               │
│  │                                          │               │
│  │  Phase 2: revealAnswer()                 │               │
│  │    → verifies hash, stores plaintext     │               │
│  │                                          │               │
│  │  Phase 3: judgeAll() ──────────────────► │─► LLM 0x0802 │
│  │    ← receives AI verdict                 │   (TEE)       │
│  │                                          │               │
│  │  Phase 4: finalizeWinner() → pays ETH    │               │
│  └──────────────────────────────────────────┘               │
│                                                             │
│  ┌──────────────────────────────────────────┐               │
│  │           AutonomousAgent.sol            │               │
│  │                                          │               │
│  │  Scheduler (0x56e7...) fires wakeUp()    │               │
│  │    every 100 blocks                      │               │
│  │  wakeUp() → SovereignAgent 0x080C ─────► │─► TEE Claude  │
│  │  onSovereignAgentResult() ← callback     │               │
│  └──────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────┘
```

---

## Lifecycle

### 1. Bounty Creation

```
owner.createBounty(title, rubric, deadline) { value: prize }
```

- `deadline` is a UNIX timestamp; the submission window is `now → deadline`
- Prize is held in the contract until `finalizeWinner`

### 2. Commit Phase (before deadline)

```
participant.submitCommitment(
  bountyId,
  keccak256(abi.encodePacked(answer, salt, participant, bountyId))
)
```

- Only a 32-byte hash is stored on-chain
- Plaintext answer is invisible to all parties (including the bounty owner)
- No frontrunning possible: changing the answer invalidates the hash

### 3. Reveal Phase (after deadline)

```
participant.revealAnswer(bountyId, answer, salt)
```

- Contract verifies: `keccak256(answer || salt || msg.sender || bountyId) == stored_commitment`
- On match, stores the plaintext answer and marks the submission as revealed
- Reverts on mismatch (wrong answer, wrong salt, wrong sender, or wrong bountyId)

### 4. AI Judging (SPC single-phase)

```
owner.judgeAll(bountyId, llmInput)
```

- Calls LLM precompile `0x0802` with all revealed answers packed into one prompt
- The TEE re-executes the tx with the model output after 10-40 seconds
- Sets `bounty.judged = true` and stores raw completion bytes

### 5. Winner Payout

```
owner.finalizeWinner(bountyId, winnerIndex)
```

- Owner reads the AI's verdict from `aiReview` bytes, picks the winner index
- Prize is paid to `submissions[winnerIndex].submitter`

---

## What is stored on-chain vs off-chain

| Item | On-chain | Off-chain |
|---|---|---|
| Commitment hash | ✅ always | never |
| Plaintext answer | ✅ after reveal only | ❌ |
| Salt | ❌ (used to verify, not stored) | Submitter must keep it |
| LLM completion | ✅ as raw bytes after judgeAll | ❌ |
| Winner address | ✅ after finalize | ❌ |
| Bounty prize | ✅ held in contract | ❌ |

---

## Advanced Track — Ritual-Native Hidden Submissions

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the full design where answers remain hidden even *after* the reveal deadline until judging completes.

---

## Contracts

| Contract | Purpose |
|---|---|
| `AIJudgeV2.sol` | Commit-reveal bounty judge with on-chain LLM judging |
| `AutonomousAgent.sol` | Self-scheduling sovereign agent (Genesis 1000 qualifier) |
| `contracts/utils/PrecompileConsumer.sol` | Ritual precompile base contract |

---

## Deployment (Remix)

See [REMIX_DEPLOY.md](./REMIX_DEPLOY.md) for the full step-by-step guide.

Quick summary:
1. Add Ritual testnet to MetaMask (Chain ID 1979)
2. Get RITUAL from faucet
3. Discover live executor from `TEEServiceRegistry`
4. Deploy `AIJudgeV2` and `AutonomousAgent` in Remix
5. Fund RitualWallet before calling `judgeAll`

---

## Reflection Question

> *"What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?"*

In a fair bounty system, the **bounty prompt, rubric, and prize amount** should be fully public so participants can make informed decisions about competing. The **identity of who submitted what answer** should be temporarily hidden during the submission phase to prevent copying, which is exactly what the commit-reveal pattern achieves — only the cryptographic hash goes on-chain, and the plaintext stays unknown until the deadline passes. The **judging criteria and scoring rationale** should be public after judging so participants can verify fairness. **AI should handle the objective, rubric-based scoring** of content quality — it is consistent, cannot be bribed, and can process many answers simultaneously in a single on-chain call without introducing human bias or delays. However, **a human should make the final call on edge cases** such as disputes over whether a commitment hash matches a revealed answer in spirit (gaming the commit phase), disqualifying plagiarism, or handling ties. The division of labor is: AI for efficiency and consistency at scale; humans for judgment calls requiring context, ethics, or community norms that a language model might misread.

---

## Key Constants

| What | Value |
|---|---|
| Chain ID | `1979` |
| RPC | `https://rpc.ritualfoundation.org` |
| LLM Precompile | `0x0000000000000000000000000000000000000802` |
| Sovereign Agent Precompile | `0x000000000000000000000000000000000000080C` |
| RitualWallet | `0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948` |
| TEEServiceRegistry | `0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F` |
| Scheduler | `0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B` |
| AsyncDelivery | `0x5A16214fF555848411544b005f7Ac063742f39F6` |
