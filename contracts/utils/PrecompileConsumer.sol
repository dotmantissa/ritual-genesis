// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PrecompileConsumer
/// @notice Base contract providing typed helpers for all 16 Ritual precompiles.
abstract contract PrecompileConsumer {
    // ── Synchronous precompiles ──────────────────────────────────────────────
    address internal constant ONNX_PRECOMPILE      = address(0x0800);
    address internal constant JQ_PRECOMPILE        = address(0x0803);
    address internal constant ED25519_PRECOMPILE   = address(0x0009);
    address internal constant SECP256R1_PRECOMPILE = address(0x0100);
    address internal constant TX_HASH_PRECOMPILE   = address(0x0830);

    // ── Short-running async precompiles (SPC / single-phase) ────────────────
    address internal constant HTTP_CALL_PRECOMPILE  = address(0x0801);
    address internal constant LLM_INFERENCE_PRECOMPILE = address(0x0802);
    address internal constant DKMS_PRECOMPILE       = address(0x081B);

    // ── Long-running async precompiles (two-phase / callback) ───────────────
    address internal constant LONG_HTTP_PRECOMPILE    = address(0x0805);
    address internal constant ZK_TWO_PHASE_PRECOMPILE = address(0x0806);
    address internal constant FHE_PRECOMPILE          = address(0x0807);
    address internal constant SOVEREIGN_AGENT_PRECOMPILE = address(0x080C);
    address internal constant IMAGE_CALL_PRECOMPILE  = address(0x0818);
    address internal constant AUDIO_CALL_PRECOMPILE  = address(0x0819);
    address internal constant VIDEO_CALL_PRECOMPILE  = address(0x081A);
    address internal constant PERSISTENT_AGENT_PRECOMPILE = address(0x0820);

    // ── System contracts ─────────────────────────────────────────────────────
    /// @dev AsyncDelivery — the ONLY address allowed to call two-phase callbacks.
    address internal constant ASYNC_DELIVERY =
        0x5A16214fF555848411544b005f7Ac063742f39F6;

    // ── Scheduler system contract ────────────────────────────────────────────
    address internal constant SCHEDULER =
        0x56e776BAE2DD60664b69Bd5F865F1180ffB7D58B;

    /// @notice Calls a precompile and returns the decoded result.
    ///         Short-running async precompiles (HTTP, LLM, DKMS) wrap their
    ///         output in an extra ABI envelope — this helper unwraps it.
    function _executePrecompile(
        address precompile,
        bytes memory input
    ) internal returns (bytes memory) {
        (bool success, bytes memory rawOutput) = precompile.call(input);

        if (!success) {
            assembly {
                revert(add(rawOutput, 32), mload(rawOutput))
            }
        }

        // Short-running async: abi.encode(bytes simmedInput, bytes actualOutput)
        if (
            precompile == HTTP_CALL_PRECOMPILE ||
            precompile == LLM_INFERENCE_PRECOMPILE ||
            precompile == DKMS_PRECOMPILE
        ) {
            (, bytes memory actualOutput) = abi.decode(rawOutput, (bytes, bytes));
            return actualOutput;
        }

        return rawOutput;
    }
}
