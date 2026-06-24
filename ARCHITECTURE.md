# Architecture Note — Ritual-Native Hidden Submissions (Advanced Track)

## Problem Statement

The commit-reveal pattern in `AIJudgeV2` still exposes plaintext answers on-chain during the reveal phase, *before* judging is complete. A sophisticated attacker watching the mempool could:
- See a high-quality reveal transaction in the pending pool
- Front-run with a near-identical answer using a different salt

The Ritual-native design eliminates this by keeping answers encrypted until the moment of AI judging — and the AI runs inside a TEE so it never exposes plaintext to the chain.

---

## Design: TEE-Hidden Submissions

### Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  1. SUBMISSION PHASE                                                │
│     Participant encrypts answer with Ritual ECIES public key (TEE)  │
│     → sends encrypted blob on-chain: submitEncrypted(bountyId, ct)  │
│     → ct = ECIES_encrypt(answer, TEE_pubkey)                        │
│     No plaintext ever touches L1.                                   │
│                                                                     │
│  2. JUDGING PHASE                                                   │
│     Owner calls judgeAll(bountyId, llmInput)                        │
│     → llmInput contains: executor, convoHistory, systemPrompt       │
│     → llmInput does NOT contain the ciphertexts directly            │
│     → Instead, ciphertexts are passed via encryptedSecrets[]        │
│        field of the LLM precompile ABI                              │
│                                                                     │
│  3. INSIDE TEE (0x0802 execution)                                   │
│     TEE executor holds the ECIES private key (in DKMS escrow)       │
│     → Decrypts all ciphertexts in encryptedSecrets[]                │
│     → Passes plaintext answers to GLM-4.7-FP8 as context           │
│     → LLM produces verdict                                          │
│     → Verdict (NOT the plaintexts) is written to chain              │
│                                                                     │
│  4. RESULT                                                          │
│     completionData (verdict) stored in bounty.aiReview              │
│     Plaintext answers NEVER appeared on-chain                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## What Is Stored Where

| Item | On-chain | Inside TEE | Off-chain (submitter) |
|---|---|---|---|
| Encrypted ciphertext (ECIES blob) | ✅ `submitEncrypted` stores it | ✅ decrypted at judging | ❌ |
| Plaintext answer | ❌ never | ✅ during LLM call only, ephemeral | Submitter holds it |
| TEE private key | ❌ | ✅ in DKMS escrow, never leaves | ❌ |
| LLM verdict | ✅ `aiReview` bytes | ✅ produced here | ❌ |
| ECIES public key | ✅ (for submitter to encrypt to) | ✅ paired with priv key | ❌ |

---

## How the LLM Receives Batch Submissions

The Ritual LLM precompile (0x0802) has an `encryptedSecrets[]` field (field 1) that accepts ECIES-encrypted blobs. The TEE:

1. Uses DKMS (`0x081B`) to derive the private key for the job
2. Decrypts each blob in `encryptedSecrets[]` using the TEE-held key
3. Substitutes the decrypted value into the `messagesJson` prompt via a `{SECRET_0}`, `{SECRET_1}` template

The bounty owner's `judgeAll` call would look like:

```typescript
const llmInput = encodeAbiParameters([...], [
  executor,
  [ctAlice, ctBob, ctCarol],  // encryptedSecrets[] — all answers, encrypted
  300n,
  [sigAlice, sigBob, sigCarol], // secretSignatures (ECDSA over each blob)
  "0x",
  JSON.stringify([{
    role: "user",
    content: `Rubric: pick the best answer.\n[0]: {SECRET_0}\n[1]: {SECRET_1}\n[2]: {SECRET_2}`
  }]),
  "zai-org/GLM-4.7-FP8",
  // ...rest of 30 fields
]);
```

The TEE replaces `{SECRET_0}` with the decrypted Alice answer, etc., before sending to the model. The model sees plaintext; the chain never does.

---

## One LLM Call for All Answers (Batch Judging)

This architecture satisfies the "batch judging" requirement:
- All answers are passed in a single `judgeAll` transaction
- The LLM precompile makes **one inference call** with all answers in the prompt
- The model returns a single verdict JSON: `{"winner_index": N, "reason": "..."}`
- Gas cost: one SPC call regardless of number of submissions

Contrast with naive approach: N separate `judgeAnswer(bountyId, i)` calls = N SPC calls = N tx fees + N × latency.

---

## TEE Trust Model

- The ECIES private key exists only inside the TEE enclave (registered via `TEEServiceRegistry`)
- The enclave produces hardware-signed attestation that the decryption happened inside a legitimate TEE
- The block builder only accepts results from executors with valid attestations
- If the TEE leaks, DKMS key derivation means no historical answers are retroactively exposed (each job uses a fresh derived key)

---

## Limitations of the Advanced Track vs. Commit-Reveal

| | Commit-Reveal (Required) | TEE-Hidden (Advanced) |
|---|---|---|
| Plaintext on-chain | Yes (after reveal) | Never |
| Reveal frontrunning risk | Yes (mempool) | None |
| Complexity | Low | Medium-High |
| Works on any EVM | ✅ | ❌ Ritual-only |
| Trust assumption | Cryptographic | TEE attestation + cryptographic |
| Answers visible after judging | ✅ (from chain) | ❌ (only verdict stored) |

The commit-reveal track is **sufficient for the assignment** and works on any EVM chain. The advanced track offers stronger privacy at the cost of Ritual lock-in.
