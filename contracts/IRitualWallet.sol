// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Paste this into Remix, compile it, then use "At Address" with the
///         RitualWallet address to interact with the existing system contract.
///         Do NOT click Deploy — click "At Address" instead.
interface IRitualWallet {
    /// @dev Credits msg.sender's RitualWallet. Call this directly from your EOA.
    function deposit(uint256 lockDuration) external payable;

    /// @dev Credits another address's RitualWallet.
    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function lockUntil(address account) external view returns (uint256);
}
