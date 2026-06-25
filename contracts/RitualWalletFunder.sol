// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRitualWallet {
    function depositFor(address user, uint256 lockDuration) external payable;
    function balanceOf(address) external view returns (uint256);
    function lockUntil(address) external view returns (uint256);
}

/// @title RitualWalletFunder
/// @notice One-off helper: funds YOUR EOA's RitualWallet from Remix without
///         touching the JS console. Deploy once, call fundMyEOA(), discard.
///
/// WHY THIS EXISTS
/// ───────────────
/// The LLM precompile (0x0802) checks the calling EOA's RitualWallet balance,
/// not a contract's balance. You must deposit FOR the EOA address.
/// Calling `deposit()` directly credits msg.sender (the contract), which is
/// wrong. `depositFor(eoa, lockBlocks)` credits the EOA correctly.
contract RitualWalletFunder {
    IRitualWallet constant RW =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    /// @notice Fund your EOA's RitualWallet.
    /// @param  lockBlocks  Number of blocks to lock. 900 ≈ 30 min at ~2s blocks.
    ///                     Deposit 0.5 RITUAL with VALUE field in Remix.
    function fundMyEOA(uint256 lockBlocks) external payable {
        require(msg.value > 0, "send RITUAL");
        RW.depositFor{value: msg.value}(msg.sender, lockBlocks);
    }

    /// @notice Check your EOA's current RitualWallet balance.
    function checkBalance(address eoa) external view returns (uint256 balance, uint256 lockedUntilBlock) {
        return (RW.balanceOf(eoa), RW.lockUntil(eoa));
    }
}
