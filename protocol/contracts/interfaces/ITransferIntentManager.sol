// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProtocolTypes} from "../common/ProtocolTypes.sol";

/// @title Transfer Intent Manager Interface
/// @notice Authoritative state manager for all TransferIntent records.
/// @dev This interface owns the lifecycle and persistence of every
///      TransferIntent. The SettlementCoordinator orchestrates settlement
///      but MUST never directly modify TransferRecord storage — all state
///      changes go through this interface.
///
///      A TransferIntentManager is responsible ONLY for state management.
///      It MUST NOT perform compliance evaluation, transport, minting,
///      burning, identity management, or bridge communication.
///
///      ── Valid State Transitions ──
///
///      | From                    | To                  | Trigger                              |
///      |-------------------------|---------------------|--------------------------------------|
///      | PENDING_VALIDATION      | VALIDATED           | Destination approves                 |
///      | PENDING_VALIDATION      | REJECTED            | Destination rejects                  |
///      | PENDING_VALIDATION      | EXPIRED             | Deadline reached                     |
///      | VALIDATED               | SETTLING            | Settlement initiated (burn starts)   |
///      | VALIDATED               | EXPIRED             | Deadline reached before settlement   |
///      | VALIDATED               | REJECTED            | Compliance officer or operator force-cancels |
///      | SETTLING                | SETTLED             | Destination confirms mint            |
///      | SETTLING                | ROLLED_BACK         | Operator invokes rollback after failure      |
///
///      All other transitions MUST revert. Terminal states (SETTLED,
///      REJECTED, EXPIRED, ROLLED_BACK) cannot transition further.
///
///      Lifecycle events should be defined in ProtocolEvents.sol once
///      that shared library exists.
///
///      State management errors should be defined in ProtocolErrors.sol
///      once that shared library exists.
///
///      Implementations MUST support ERC-165 for interface detection.
interface ITransferIntentManager is IERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // Creation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Creates a new transfer intent record with state
    ///         `PENDING_VALIDATION`.
    /// @dev Reverts if an intent with the same `intentId` already exists.
    ///      The `createdAt` timestamp is set to `block.timestamp`.
    /// @param intent The transfer business object to persist.
    /// @return intentId The unique identifier of the created intent
    ///                  (matches `intent.intentId`).
    function createTransferIntent(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bytes32 intentId);

    // ═══════════════════════════════════════════════════════════════════════
    // Retrieval
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the transfer business object for a given intent.
    /// @param intentId Unique intent identifier.
    /// @return intent  The transfer business object.
    function getTransferIntent(bytes32 intentId) external view returns (ProtocolTypes.TransferIntent memory intent);

    /// @notice Returns the full transfer record, including lifecycle metadata.
    /// @param intentId Unique intent identifier.
    /// @return record  The full transfer record.
    function getTransferRecord(bytes32 intentId) external view returns (ProtocolTypes.TransferRecord memory record);

    /// @notice Returns whether a transfer intent exists.
    /// @param intentId Unique intent identifier.
    /// @return exists  True if the intent has been created and not deleted.
    function exists(bytes32 intentId) external view returns (bool exists);

    // ═══════════════════════════════════════════════════════════════════════
    // State Queries
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the current settlement state of an intent.
    /// @param intentId Unique intent identifier.
    /// @return state   Current SettlementState.
    function getSettlementState(bytes32 intentId) external view returns (ProtocolTypes.SettlementState state);

    // ═══════════════════════════════════════════════════════════════════════
    // State Transitions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Transitions an intent to a new state.
    /// @dev Reverts if the transition is not valid according to the state
    ///      machine defined in this interface's documentation. The
    ///      `updatedAt` timestamp is set to `block.timestamp`.
    /// @param intentId Unique intent identifier.
    /// @param newState The target state to transition to.
    function transitionState(
        bytes32 intentId,
        ProtocolTypes.SettlementState newState
    ) external;

    // ═══════════════════════════════════════════════════════════════════════
    // Semantic State Helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Cancels a validated or pending intent, moving it to REJECTED.
    /// @dev Intended for use by compliance officers or bridge operators.
    ///      Reverts if the intent is already in a terminal state.
    /// @param intentId Unique intent identifier.
    function cancelTransferIntent(bytes32 intentId) external;

    /// @notice Marks an intent as expired.
    /// @dev Reverts if the intent is already in a terminal state or if the
    ///      deadline has not yet passed (implementation-dependent).
    /// @param intentId Unique intent identifier.
    function expireTransferIntent(bytes32 intentId) external;
}
