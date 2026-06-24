# Test Plan — Commit-Reveal Bounty Judge

All tests target `AIJudgeV2.sol`. Test cases are grouped by phase.

---

## Phase 0 — createBounty

| # | Test | Expected Result |
|---|---|---|
| T-01 | `createBounty` with no ETH value | Revert: `"reward required"` |
| T-02 | `createBounty` with `deadline <= block.timestamp` | Revert: `"deadline must be in the future"` |
| T-03 | Valid `createBounty` | Returns `bountyId = 1`, emits `BountyCreated`, stores owner/title/rubric/reward/deadline |
| T-04 | Second `createBounty` | Returns `bountyId = 2` (auto-increment) |

---

## Phase 1 — submitCommitment

| # | Test | Expected Result |
|---|---|---|
| T-05 | Valid commitment submission before deadline | Emits `CommitmentSubmitted`, stores hash, `bounty.submissions.length == 1` |
| T-06 | Submit commitment **after** deadline | Revert: `"submission phase closed"` |
| T-07 | Submit `bytes32(0)` as commitment | Revert: `"empty commitment"` |
| T-08 | Same address submits commitment twice | Revert: `"already committed"` |
| T-09 | 11th submission (> MAX_SUBMISSIONS=10) | Revert: `"too many submissions"` |
| T-10 | Submit to non-existent bountyId | Revert: `"bounty not found"` |

---

## Phase 2 — revealAnswer

| # | Test | Expected Result |
|---|---|---|
| T-11 | Valid reveal (correct answer + salt) before deadline | Revert: `"reveal phase not open yet"` |
| T-12 | Valid reveal after deadline | Succeeds, stores answer, marks `hasRevealed = true`, emits `AnswerRevealed` |
| T-13 | Reveal with **wrong salt** (correct answer) | Revert: `"commitment mismatch"` |
| T-14 | Reveal with **wrong answer** (correct salt) | Revert: `"commitment mismatch"` |
| T-15 | Reveal from **different address** than committer | Revert: `"commitment mismatch"` (sender encoded in hash) |
| T-16 | Double reveal (same address reveals twice) | Revert: `"already revealed"` |
| T-17 | Reveal with no prior commitment | Revert: `"no commitment found"` |
| T-18 | Reveal empty string answer | Revert: `"answer empty"` |
| T-19 | Reveal answer > 2000 chars | Revert: `"answer too long"` |
| T-20 | Reveal after `judged = true` | Revert: `"already judged"` |

---

## Phase 3 — judgeAll

| # | Test | Expected Result |
|---|---|---|
| T-21 | `judgeAll` before deadline | Revert: `"reveal phase not open yet"` |
| T-22 | `judgeAll` with zero revealed answers | Revert: `"no revealed answers to judge"` |
| T-23 | `judgeAll` called by non-owner | Revert: `"not bounty owner"` |
| T-24 | `judgeAll` with valid llmInput after reveals | Succeeds, sets `judged = true`, stores `aiReview`, emits `AllAnswersJudged` |
| T-25 | `judgeAll` called twice (already judged) | Revert: `"already judged"` |
| T-26 | `judgeAll` with expired RitualWallet lock | Silent precompile revert (caught by `require(!hasError, ...)`) |

---

## Phase 4 — finalizeWinner

| # | Test | Expected Result |
|---|---|---|
| T-27 | `finalizeWinner` before `judged = true` | Revert: `"not judged yet"` |
| T-28 | `finalizeWinner` with out-of-range index | Revert: `"invalid index"` |
| T-29 | `finalizeWinner` where winner never revealed | Revert: `"winner did not reveal"` |
| T-30 | `finalizeWinner` called by non-owner | Revert: `"not bounty owner"` |
| T-31 | Valid `finalizeWinner` | Winner receives full reward, sets `finalized = true`, emits `WinnerFinalized` |
| T-32 | `finalizeWinner` called twice | Revert: `"already finalized"` |

---

## View Helpers

| # | Test | Expected Result |
|---|---|---|
| T-33 | `computeCommitment(answer, salt, addr, bountyId)` | Returns same hash as off-chain `keccak256(abi.encodePacked(...))` |
| T-34 | `getSubmission(bountyId, index)` before reveal | Returns empty `answer`, `hasRevealed = false` |
| T-35 | `getSubmission(bountyId, index)` after reveal | Returns correct answer, `hasRevealed = true` |
| T-36 | `getRevealedAnswers(bountyId)` with mixed reveals | Returns all slots; unrevealed have empty answer strings |

---

## Integration — Full Lifecycle (Happy Path)

```
T-37: Full happy path
  1. createBounty(title, rubric, deadline=now+10s) {value: 0.1 ether}
  2. [Alice] compute commitment offline → submitCommitment(1, hash_a)
  3. [Bob]   compute commitment offline → submitCommitment(1, hash_b)
  4. warp time past deadline
  5. [Alice] revealAnswer(1, answerA, saltA)  → T-12
  6. [Bob]   revealAnswer(1, answerB, saltB)  → T-12
  7. [Owner] judgeAll(1, llmInput)             → T-24, poll judged==true
  8. [Owner] finalizeWinner(1, 0)              → T-31, Alice receives 0.1 ETH
```

---

## How to Run These Tests

These test cases map directly to Hardhat Mocha tests. To run manually in Remix:

1. For revert tests: call the function with bad args and confirm Remix shows a red error with the expected revert message.
2. For success tests: check the tx logs panel in Remix for the expected events.
3. For T-37 (full lifecycle): use the `judgeAll` llmInput builder from REMIX_DEPLOY.md Step 9d — set a very short deadline (`Date.now()/1000 + 30`).

> **Note on T-26:** The RitualWallet lock expiry revert happens inside the TEE replay, not in simulation. If `judgeAll` simulates fine but `judged` never becomes true, check your RitualWallet lock with:
> ```javascript
> const rw = new ethers.Contract("0x532F...", [...], signer);
> const lockBlock = await rw.lockUntil(yourAddress);
> console.log("lock expires at block:", lockBlock.toString());
> ```
