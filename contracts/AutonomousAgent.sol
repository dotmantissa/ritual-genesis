// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

// ─────────────────────────────────────────────────────────────────────────────
//  AutonomousAgent — Self-Scheduling Sovereign Agent (Genesis 1000)
// ─────────────────────────────────────────────────────────────────────────────
//
//  This contract IS the agent. It uses the Ritual Scheduler system contract to
//  wake itself up every ~WAKE_INTERVAL_BLOCKS blocks, then calls the Sovereign
//  Agent precompile (0x080C) to run a Claude Code harness inside a TEE.
//
//  Deploying this contract on Ritual testnet qualifies the deployer for the
//  Genesis 1000 registry (run /genesis_claim in the Ritual Discord).
//
//  LIFECYCLE
//  ─────────
//  1. Deploy this contract on Ritual testnet (chain 1979).
//  2. Fund the contract's RitualWallet: call depositToRitualWallet{value: ...}().
//  3. Call start(executor, agentInput, initialDelay) — begins the wakeup loop.
//  4. The Scheduler fires wakeUp() every WAKE_INTERVAL_BLOCKS blocks.
//  5. wakeUp() calls the Sovereign Agent precompile with your prompt.
//  6. onSovereignAgentResult() receives the TEE result (two-phase callback).
//  7. The agent re-schedules itself — running forever while funded.
//
// ─────────────────────────────────────────────────────────────────────────────

interface IScheduler {
    function schedule(
        address target,
        bytes   calldata callData,
        uint256 gas,
        uint64  startBlock,
        uint8   retrySlots,
        uint8   frequency,
        uint32  ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external returns (uint256 callId);

    function cancel(uint256 callId) external;
}

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;
    function depositFor(address user, uint256 lockDuration) external payable;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

contract AutonomousAgent is PrecompileConsumer {

    // ── Constants ─────────────────────────────────────────────────────────────
    uint32  public constant WAKE_INTERVAL_BLOCKS = 100;
    uint256 public constant SCHEDULE_GAS         = 1_500_000;
    uint32  public constant SCHEDULE_TTL         = 50;   // blocks
    uint8   public constant SCHEDULE_RETRIES     = 3;

    IScheduler    private constant SCHED =
        IScheduler(0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B);
    IRitualWallet private constant RITUAL_WALLET =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    // ── State ─────────────────────────────────────────────────────────────────
    address public owner;
    address public executor;        // TEE executor from TEEServiceRegistry
    bytes   public agentInput;      // Encoded sovereign agent payload
    uint256 public scheduleCallId;
    uint256 public wakeCount;
    bytes32 public lastJobId;
    bytes   public lastResult;
    bool    public isRunning;

    // ── Events ────────────────────────────────────────────────────────────────
    event AgentStarted(address indexed executor, uint256 scheduleCallId);
    event AgentWokeUp(uint256 indexed wakeCount, uint256 blockNumber);
    event AgentResult(bytes32 indexed jobId, bytes result);
    event AgentStopped(uint256 wakeCount);
    event RitualWalletFunded(uint256 amount, uint256 lockBlocks);

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Setup — Fund RitualWallet
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Fund THIS CONTRACT's RitualWallet (for the agent's own scheduled wakeup fees).
    ///         Call this before start() so the agent can pay for its precompile calls.
    function depositToRitualWallet(uint256 lockBlocks) external payable onlyOwner {
        require(msg.value > 0, "send RITUAL");
        RITUAL_WALLET.deposit{value: msg.value}(lockBlocks);
        emit RitualWalletFunded(msg.value, lockBlocks);
    }

    /// @notice Fund YOUR EOA's RitualWallet (needed before calling judgeAll on AIJudgeV2).
    ///         Uses depositFor so the credit goes to msg.sender (your wallet address),
    ///         NOT to this contract. The LLM precompile checks the EOA's balance.
    ///         Call with VALUE = amount to deposit (e.g. 0.5 RITUAL), lockBlocks = 900.
    function depositForEOA(uint256 lockBlocks) external payable onlyOwner {
        require(msg.value > 0, "send RITUAL");
        RITUAL_WALLET.depositFor{value: msg.value}(msg.sender, lockBlocks);
        emit RitualWalletFunded(msg.value, lockBlocks);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 1 — Start the agent loop
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Start the autonomous agent loop.
    /// @param  _executor      Live TEE executor address from TEEServiceRegistry.
    /// @param  _agentInput    ABI-encoded 23-field Sovereign Agent payload
    ///                        (encode off-chain, see REMIX_DEPLOY.md).
    /// @param  initialDelay   Blocks to wait before the first wakeup.
    function start(
        address _executor,
        bytes calldata _agentInput,
        uint32 initialDelay
    ) external onlyOwner {
        require(!isRunning, "already running");
        require(_executor != address(0), "executor required");
        require(_agentInput.length > 0, "agentInput required");

        executor  = _executor;
        agentInput = _agentInput;
        isRunning = true;

        scheduleCallId = _scheduleNext(initialDelay);
        emit AgentStarted(_executor, scheduleCallId);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 2 — Wakeup (called by Scheduler)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The Scheduler calls this function at the scheduled block.
    ///         Only the Scheduler system contract can call this.
    function wakeUp() external {
        require(msg.sender == address(SCHED), "only scheduler");
        if (!isRunning) return;

        wakeCount++;
        emit AgentWokeUp(wakeCount, block.number);

        // ── Invoke the Sovereign Agent precompile (0x080C, two-phase) ───────
        _executePrecompile(SOVEREIGN_AGENT_PRECOMPILE, agentInput);

        // ── Schedule next wakeup ─────────────────────────────────────────────
        scheduleCallId = _scheduleNext(WAKE_INTERVAL_BLOCKS);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Phase 3 — Callback from AsyncDelivery (two-phase result)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice AsyncDelivery calls this after the TEE completes the agent run.
    ///         MUST check msg.sender == ASYNC_DELIVERY to prevent spoofing.
    function onSovereignAgentResult(
        bytes32 jobId,
        bytes calldata result
    ) external {
        require(msg.sender == ASYNC_DELIVERY, "only AsyncDelivery");
        lastJobId = jobId;
        lastResult = result;
        emit AgentResult(jobId, result);
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Control
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Stop the agent loop. The next scheduled wakeup will no-op.
    function stop() external onlyOwner {
        isRunning = false;
        SCHED.cancel(scheduleCallId);
        emit AgentStopped(wakeCount);
    }

    /// @notice Update the agent input (e.g. new prompt). Takes effect on next wakeup.
    function setAgentInput(bytes calldata _agentInput) external onlyOwner {
        agentInput = _agentInput;
    }

    /// @notice Update the TEE executor address.
    function setExecutor(address _executor) external onlyOwner {
        require(_executor != address(0), "executor required");
        executor = _executor;
    }

    /// @notice Emergency ETH rescue.
    function rescue(uint256 amount) external onlyOwner {
        (bool ok, ) = payable(owner).call{value: amount}("");
        require(ok, "rescue failed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Internal
    // ─────────────────────────────────────────────────────────────────────────

    function _scheduleNext(uint32 delay) internal returns (uint256) {
        return SCHED.schedule(
            address(this),                                  // target
            abi.encodeWithSelector(this.wakeUp.selector),  // callData
            SCHEDULE_GAS,                                   // gas
            uint64(block.number) + delay,                   // startBlock
            SCHEDULE_RETRIES,                               // retrySlots
            1,                                              // frequency (once)
            SCHEDULE_TTL,                                   // ttl (blocks)
            0,                                              // maxFeePerGas (0 = auto)
            0,                                              // maxPriorityFeePerGas (0 = auto)
            0,                                              // value
            address(this)                                   // payer = self
        );
    }

    receive() external payable {}
}
