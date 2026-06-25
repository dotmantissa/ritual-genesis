# Remix Deployment Guide — Ritual Testnet

## Prerequisites

- MetaMask installed in your browser
- Your wallet private key imported into MetaMask
- ~2 RITUAL testnet tokens (claim from faucet below)

---

## Step 1 — Add Ritual Testnet to MetaMask

In MetaMask → Settings → Networks → Add a network manually:

| Field | Value |
|---|---|
| Network Name | Ritual Testnet |
| RPC URL | `https://rpc.ritualfoundation.org` |
| Chain ID | `1979` |
| Currency Symbol | `RITUAL` |
| Block Explorer | `https://explorer.ritualfoundation.org` |

---

## Step 2 — Fund Your Wallet from the Faucet

```bash
curl -X POST https://faucet.ritualfoundation.org/api/claim \
  -H 'Content-Type: application/json' \
  -d '{"address": "0xYOUR_ADDRESS"}'
```

Aim for at least **1.5 RITUAL** total:
- ~0.05 for gas on deploy transactions
- ~0.5 for RitualWallet deposit (needed before `judgeAll`)
- ~0.5+ for bounty reward (goes to winner)

---

## Step 3 — Discover a Live TEE Executor

Before deploying, find a live executor (replace `cast` with any eth call tool):

```bash
# Using cast (Foundry):
cast call 0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F \
  'getServicesByCapability(uint8,bool)(address[])' 1 true \
  --rpc-url https://rpc.ritualfoundation.org
```

**Save the first address returned** — you'll need it as `executor` in all LLM/agent calls.

> Re-run if calls start failing after a few days — executors rotate.

---

## Step 4 — Open Remix and Load Files

1. Go to **https://remix.ethereum.org**
2. In the File Explorer (left sidebar), create this folder structure:

```
contracts/
  utils/
    PrecompileConsumer.sol   <- paste from contracts/utils/PrecompileConsumer.sol
  AIJudgeV2.sol             <- paste from contracts/AIJudgeV2.sol
  AutonomousAgent.sol       <- paste from contracts/AutonomousAgent.sol
```

---

## Step 5 — Compiler Settings

Go to the **Solidity Compiler** tab:
- Compiler version: **0.8.24**
- Enable optimization: **Yes**, runs: **200**

Compile each file — you should see green checkmarks.

---

## Step 6 — Deploy AIJudgeV2

1. Go to **Deploy & Run Transactions** tab
2. Environment: **Injected Provider – MetaMask** (Ritual Testnet 1979)
3. Select contract: `AIJudgeV2`
4. Click **Deploy** (no constructor args needed)
5. Confirm in MetaMask → **Copy the deployed address**

---

## Step 7 — Deploy AutonomousAgent (Genesis 1000 qualifier)

1. Select contract: `AutonomousAgent`
2. Click **Deploy** (no constructor args)
3. Confirm in MetaMask → **Copy the deployed address**

> **This deployment qualifies you for Genesis 1000.**
> After this, go to Ritual Discord and run `/genesis_claim`.

---

## Step 8 — Fund RitualWallet (CRITICAL before judgeAll)

The LLM precompile checks your **EOA's** RitualWallet balance before it will run.
**No new contract deployment needed** — use Remix's "At Address" feature to talk to the already-deployed RitualWallet system contract.

### Steps

1. **Create** `contracts/IRitualWallet.sol` in Remix and paste this:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function lockUntil(address account) external view returns (uint256);
}
```

2. **Compile** it (0.8.24, any settings — it's just an interface).

3. Go to **Deploy & Run Transactions**.

4. In the **CONTRACT** dropdown, select `IRitualWallet`.

5. In the **"At Address"** field (NOT the Deploy button), paste:
   ```
   0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948
   ```

6. Click the **"At Address"** button (orange/blue button next to the field).
   A panel appears under "Deployed Contracts" — this is the live RitualWallet.

7. In that panel, find the `deposit` function. Set:
   - `lockDuration`: `900`
   - **VALUE field** (top of the Deploy panel): `500000000000000000` (= 0.5 RITUAL in wei)
     or switch the unit dropdown to **ether** and type `0.5`

8. Click **deposit** → confirm in MetaMask.

9. Verify it worked: call `balanceOf` with your wallet address — should show `500000000000000000`.
   Call `lockUntil` — should show a block number far in the future.

> **Why this works:** You're calling `deposit()` directly from your EOA (MetaMask), so `msg.sender` is your EOA address. The RitualWallet credits your EOA — exactly what the LLM precompile checks.



---

## Step 9 — Run the Commit-Reveal Lifecycle

### 9a — Create a Bounty

> ⚠️ **Ritual uses millisecond timestamps.** `block.timestamp` on Ritual is in ms (e.g. `1782416215707`), not seconds. Your deadline must also be in ms.

Get your deadline by running this in the **Remix console** (not the browser console):

```javascript
Date.now() + 3600000
```

It prints a **13-digit** number like `1782420000000`. Copy it.

Then in Remix → AIJudgeV2 → `createBounty`:
- `title`: `What is the most promising use of on-chain AI?`
- `rubric`: `Judge on clarity, originality, and feasibility. Pick the single best answer.`
- `deadline`: paste the 13-digit ms number (e.g. `1782420000000`)
- **VALUE:** `0.1` ether

Note the `bountyId` from the tx logs (usually `1`).

### 9b — Compute Your Commitment Off-chain

```javascript
// Paste in Remix console — ethers v5 syntax
const answer  = "AI agents that autonomously manage DeFi portfolios";
// Generate a random salt (32 bytes)
const saltBytes = ethers.utils.randomBytes(32);
const salt      = ethers.utils.hexlify(saltBytes); // SAVE THIS — needed for reveal
const bountyId  = 1;
const provider  = new ethers.providers.Web3Provider(window.ethereum);
await provider.send("eth_requestAccounts", []);
const myAddress = await provider.getSigner().getAddress();

// Compute commitment = keccak256(abi.encodePacked(answer, salt, address, bountyId))
const packed = ethers.utils.solidityPack(
  ["string", "bytes32", "address", "uint256"],
  [answer, salt, myAddress, bountyId]
);
const commitment = ethers.utils.keccak256(packed);
console.log("commitment:", commitment);
console.log("salt (SAVE THIS):", salt);
```

Call `submitCommitment(bountyId=1, commitment=<output>)`.

### 9c — After Deadline: Reveal

Call `revealAnswer(bountyId=1, answer="AI agents...", salt=<salt hex from 9b>)`.

### 9d — Build LLM Input for judgeAll

```javascript
// Paste in Remix console — ethers v5 ABI encoder (no external imports needed)
// Fill in your executor address from Step 3:
const executor  = "0xEXECUTOR_ADDRESS_FROM_STEP_3";
const bountyId  = 1;

// Build the messagesJson — update [0] with actual revealed answers from getRevealedAnswers()
const messagesJson = JSON.stringify([
  { role: "system", content: "You are a fair bounty judge. Rubric: Judge on clarity, originality, and feasibility. Pick the single best answer." },
  { role: "user",   content: 'Submissions for bounty 1:\n[0] "AI agents that autonomously manage DeFi portfolios"\n\nRespond with JSON: {"winner_index": 0, "reason": "one sentence"}' }
]);

// ABI-encode the 30-field LLM precompile input using ethers v5
const abiCoder = new ethers.utils.AbiCoder();
const llmInput = abiCoder.encode(
  [
    "address",   // 0  executor
    "bytes[]",   // 1  encryptedSecrets
    "uint256",   // 2  ttl
    "bytes[]",   // 3  secretSignatures
    "bytes",     // 4  userPublicKey
    "string",    // 5  messagesJson
    "string",    // 6  model
    "int256",    // 7  frequencyPenalty
    "string",    // 8  logitBiasJson
    "bool",      // 9  logprobs
    "int256",    // 10 maxCompletionTokens
    "string",    // 11 metadataJson
    "string",    // 12 modalitiesJson
    "uint256",   // 13 n
    "bool",      // 14 parallelToolCalls
    "int256",    // 15 presencePenalty
    "string",    // 16 reasoningEffort
    "bytes",     // 17 responseFormatData
    "int256",    // 18 seed
    "string",    // 19 serviceTier
    "string",    // 20 stopJson
    "bool",      // 21 stream
    "int256",    // 22 temperature
    "bytes",     // 23 toolChoiceData
    "bytes",     // 24 toolsData
    "int256",    // 25 topLogprobs
    "int256",    // 26 topP
    "string",    // 27 user
    "bool",      // 28 piiEnabled
    "tuple(string,string,string)"  // 29 convoHistory
  ],
  [
    executor,
    [],
    300,
    [],
    "0x",
    messagesJson,
    "zai-org/GLM-4.7-FP8",
    0,
    "",
    false,
    4096,
    "",
    "",
    1,
    false,
    0,
    "low",
    "0x",
    -1,
    "",
    "",
    false,
    200,
    "0x",
    "0x",
    -1,
    1000,
    "",
    false,
    ["", "", ""]
  ]
);
console.log("llmInput:", llmInput);
```

### 9e — Call judgeAll

In Remix → AIJudgeV2 → `judgeAll`:
- `bountyId`: `1`
- `llmInput`: paste hex from 9d
- **Set Gas to 5000000 in Remix** (required; do NOT set custom fee prices)

Wait 15-60 seconds, poll `getBounty(1)` until `judged = true`.

### 9f — Finalize Winner

```javascript
// Decode aiReview to see LLM's choice:
const review = new TextDecoder().decode(ethers.getBytes("0x<AIREVIEW_HEX>"));
console.log(review); // {"winner_index": 0, "reason": "..."}
```

Then call `finalizeWinner(bountyId=1, winnerIndex=0)`.

---

## Step 10 — Start Autonomous Agent Loop

### 10a — Build Agent Input

```javascript
const { encodeAbiParameters, parseAbiParameters } = await import("https://esm.sh/viem@2");
const executor     = "0xEXECUTOR_ADDRESS";
const agentAddress = "0xYOUR_AUTONOMOUS_AGENT_ADDRESS";

// Callback selector for onSovereignAgentResult(bytes32,bytes)
const cbSelector = ethers.id("onSovereignAgentResult(bytes32,bytes)").slice(0, 10);

const agentInput = encodeAbiParameters(
  parseAbiParameters("address,uint256,bytes,uint64,uint64,string,address,bytes4,uint256,uint256,uint256,uint16,string,bytes,(string,string,string),(string,string,string),(string,string,string)[],(string,string,string),string,string[],uint16,uint32,string"),
  [
    executor, 300n, "0x",
    10n, 200n, "",
    agentAddress, cbSelector,
    500000n, 0n, 0n,
    0,   // cliType: 0 = Claude Code
    "Print 'AGENT_OK' and today's UTC date.",
    "0x",
    ["", "", ""], ["", "", ""], [], ["", "", ""],
    "zai-org/GLM-4.7-FP8",
    [], 3, 512,
    "https://rpc.ritualfoundation.org",
  ]
);
console.log("agentInput:", agentInput);
```

### 10b — Fund the Agent's RitualWallet

In Remix → AutonomousAgent → `depositToRitualWallet`:
- Value: `0.1` ETH
- `lockBlocks`: `900`

### 10c — Start the Loop

In Remix → AutonomousAgent → `start`:
- `_executor`: your executor address
- `_agentInput`: hex from 10a
- `initialDelay`: `10`

After ~20 seconds, check `wakeCount()` — it should be `>= 1`.

---

## Verification Commands

```bash
# Bounty judged?
cast call 0xYOUR_AIJUDGE_V2 \
  'getBounty(uint256)(address,string,string,uint256,uint256,bool,bool,uint256,uint256,bytes)' \
  1 --rpc-url https://rpc.ritualfoundation.org

# Agent awake?
cast call 0xYOUR_AGENT 'wakeCount()(uint256)' \
  --rpc-url https://rpc.ritualfoundation.org
```

Explorer: `https://explorer.ritualfoundation.org/address/0xYOUR_CONTRACT`

---

## Claiming Genesis 1000

1. Go to the Ritual Discord
2. Run `/genesis_claim`
3. When asked to describe your agent in one line, use:
   > *"A self-scheduling on-chain bounty reminder agent that wakes itself up every 100 blocks on Ritual testnet using the Scheduler and Sovereign Agent precompile."*
4. Your collectible card is generated instantly
5. Hit **Share on X** 🚀
