// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ChainId, ProtocolTypes} from "../common/ProtocolTypes.sol";
import {ITransferIntentManager} from "./ITransferIntentManager.sol";
import {ITransportProvider} from "./ITransportProvider.sol";
import {ICompliancePolicyProvider} from "./ICompliancePolicyProvider.sol";
import {IAssetAdapter} from "./IAssetAdapter.sol";

/// @title Settlement Coordinator Interface
/// @notice Workflow engine for the two-phase cross-chain settlement protocol.
/// @dev The SettlementCoordinator orchestrates every step of a cross-chain
///      transfer by delegating to four sub-components:
///
///      | Component              | Role                                    |
///      |------------------------|-----------------------------------------|
///      | ITransferIntentManager | Intent lifecycle, persistence, state    |
///      | ICompliancePolicyProvider | Compliance evaluation (view-only)    |
///      | IAssetAdapter          | Token-standard-agnostic asset operations |
///      | ITransportProvider     | Cross-chain message transport           |
///
///      The coordinator owns workflow, NOT persistence. All settlement state
///      (TransferRecords, lifecycle metadata) lives inside
///      ITransferIntentManager. The coordinator reads and transitions that
///      state through the manager's interface but never stores it locally.
///
///      ── Audit Trail ──
///
///      Failed transfer attempts are NEVER silently discarded. If compliance
///      or asset reservation fails, the intent is created and marked REJECTED
///      rather than reverting. This preserves an on-chain audit record of
///      every attempted transfer, including failures — a requirement for
///      institutional financial systems.
///
///      ── Orchestration Flow ──
///
///      Reservation only happens after both sides agree, reducing lock
///      contention during Phase 1. Burning happens only after the
///      destination confirms mint, ensuring tokens are never destroyed
///      unless delivery is confirmed.
///
///      ```
///      SOURCE CHAIN                              DESTINATION CHAIN
///      ─────────────                              ─────────────────
///
///      1. submitTransfer(intent)
///         ├── createTransferIntent → PENDING_VALIDATION
///         ├── evaluateTransferIntent
///         │   └── if fail → transitionState → REJECTED
///         └── sendMessage → VALIDATION_REQUEST ──►
///                                                  5. handleTransportMessage
///                                                     ├── createTransferIntent
///                                                     ├── evaluateTransferIntent
///                                                     │   └── if fail → REJECTED, send back
///                                                     ├── transitionState → VALIDATED
///                                                     └── sendMessage ← VALIDATION_RESPONSE
///      2. handleTransportMessage ◄──────────────────
///         ├── if rejected:
///         │   └── transitionState → REJECTED
///         └── if approved:
///             ├── transitionState → VALIDATED
///             ├── reserveAssets (lock tokens, don't burn)
///             │   └── if fail → transitionState → REJECTED
///             ├── transitionState → RESERVED
///             └── sendMessage → SETTLEMENT_INSTRUCTION ──►
///                                                          6. handleTransportMessage
///                                                             ├── mintAssets
///                                                             ├── transitionState → SETTLED
///                                                             └── sendMessage ← SETTLEMENT_ACK
///      3. handleTransportMessage ◄──────────────────
///         ├── burnReservedAssets (burn the locked tokens)
///         └── transitionState → SETTLED
///
///      RECOVERY (if SETTLEMENT_ACK never arrives):
///      4. rollbackSettlement(intentId)
///         ├── getTransferIntent (manager)
///         ├── releaseReservation (unlock tokens — no re-mint needed)
///         └── transitionState → ROLLED_BACK
///      ```
///
///      All cross-chain communication flows through ITransportProvider as
///      opaque TransportMessage envelopes. The coordinator encodes and
///      decodes the payload; the provider only transports it.
///
///      ── No Vendor Exposure ──
///
///      The SettlementCoordinator MUST never interact with ERC-3643,
///      ERC-1400, CCIP, ACE, or ONCHAINID contracts directly. Every
///      interaction is mediated by one of the four sub-component interfaces.
///
///      ── Events & Errors ──
///
///      Settlement lifecycle events belong in ProtocolEvents.sol.
///      Settlement errors belong in ProtocolErrors.sol.
///      Both are intentionally absent from this interface.
///
///      Implementations MUST support ERC-165 for interface detection.
interface ISettlementCoordinator is IERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // User Entry
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initiates a cross-chain transfer by submitting a
    ///         TransferIntent.
    /// @dev    The coordinator:
    ///         1. Creates the TransferIntent record (state = PENDING_VALIDATION)
    ///            via ITransferIntentManager. This step always succeeds for
    ///            valid inputs, establishing an audit record.
    ///         2. Evaluates compliance via ICompliancePolicyProvider.
    ///            If this fails, the intent is transitioned to REJECTED and
    ///            the function returns — it does NOT revert. The caller
    ///            receives the intentId of the failed attempt.
    ///         3. Dispatches a Phase 1 validation request to the destination
    ///            chain via ITransportProvider.
    ///
    ///         Asset reservation is deliberately deferred until Phase 2,
    ///         after the destination chain approves. This avoids locking
    ///         the sender's tokens during the validation window and
    ///         eliminates wasted reservations when the destination rejects.
    ///
    ///         The function MUST NOT revert for compliance failures. The
    ///         intent is created first, then evaluated; failures produce
    ///         a REJECTED record rather than losing the audit trail in
    ///         a revert.
    ///
    ///         The only revert cases are:
    ///         - Invalid intent structure (zero intentId, zero addresses,
    ///           zero amount, expired deadline, invalid timestamps).
    ///         - Duplicate intentId.
    ///         - Transport dispatch failure (e.g. invalid destination chain,
    ///           provider misconfiguration).
    ///
    ///         After this function returns the intentId, the caller monitors
    ///         the intent lifecycle. If the intent is REJECTED immediately,
    ///         the transfer failed local compliance and will not proceed.
    ///         If PENDING_VALIDATION, the destination chain's response
    ///         arrives asynchronously through `handleTransportMessage`.
    /// @param  intent   The fully populated transfer intent describing
    ///                  the asset, sender, recipient, amount, partition,
    ///                  chains, and deadline.
    /// @return intentId The unique identifier assigned to this transfer
    ///                  (matches `intent.intentId`). Returned for BOTH
    ///                  successful (VALIDATED) and failed (REJECTED)
    ///                  attempts so callers can inspect the audit record.
    function submitTransfer(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bytes32 intentId);

    // ═══════════════════════════════════════════════════════════════════════
    // Transport Callback
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Handles an inbound cross-chain message delivered by the
    ///         TransportProvider.
    /// @dev    The provider authenticates the source chain and sender before
    ///         calling this function. The coordinator dispatches based on
    ///         `message.messageType` and `message.phase`:
    ///
    ///         | messageType              | phase                    | Action                                              |
    ///         |--------------------------|--------------------------|-----------------------------------------------------|
    ///         | TRANSFER_INTENT          | VALIDATION_REQUEST       | Create intent, evaluate locally,                     |
    ///         |                          |                          | respond with VALIDATION_RESPONSE (approved/rejected) |
    ///         |                          |                          | No assets reserved during Phase 1                    |
    ///         | VALIDATION_RESPONSE      | VALIDATION_RESPONSE      | If approved → transition VALIDATED, reserve (lock),  |
    ///         |                          |                          | transition RESERVED, send SETTLEMENT_INSTRUCTION;    |
    ///         |                          |                          | If rejected → transition REJECTED                    |
    ///         | TRANSFER_INTENT          | SETTLEMENT_INSTRUCTION   | Mint assets to recipient, transition SETTLED,        |
    ///         |                          |                          | respond with SETTLEMENT_ACK                          |
    ///         | SETTLEMENT_CONFIRMATION  | SETTLEMENT_ACK           | Burn reserved tokens, transition to SETTLED          |
    ///
    ///         ── Idempotency & Replay Protection ──
    ///
    ///         Two layers of defense prevent double processing:
    ///
    ///         1. Per-messageId deduplication: Every processed `messageId`
    ///         is tracked in an internal mapping. If the transport provider
    ///         delivers the same `messageId` twice, the second call is
    ///         silently ignored (no-op return). The mark is written only
    ///         after the handler completes — if the handler reverts the
    ///         message can be retried.
    ///
    ///         2. Per-intent state guards: Each handler checks the current
    ///         intent state before acting. A duplicate VALIDATION_RESPONSE
    ///         for an intent already past `VALIDATED` is ignored. A
    ///         duplicate SETTLEMENT_INSTRUCTION or SETTLEMENT_ACK for an
    ///         already-`SETTLED` intent is ignored. This covers the case
    ///         where the transport retries with a new `messageId`.
    ///
    ///         Together these ensure handlers are idempotent regardless of
    ///         transport behavior.
    ///
    ///         ── Timeouts (Not Yet Automated) ──
    ///
    ///         The state machine allows `PENDING_VALIDATION → EXPIRED`,
    ///         `VALIDATED → EXPIRED`, and `RESERVED → EXPIRED` transitions,
    ///         but no component currently owns triggering them. The
    ///         `TransferIntentManager.expireTransferIntent()` function exists
    ///         (gated to `BRIDGE_ROLE`) for manual operator use, but there is
    ///         no automated scheduler, keeper network integration, or
    ///         `SettlementCoordinator` wrapper that enforces deadlines.
    ///
    ///         Stale intents accumulate until a scheduler or operator flow is
    ///         added in a future iteration.
    ///
    ///         On the destination chain, the same audit-trail pattern
    ///         applies: the intent is created first, then evaluated.
    ///         Failures produce a REJECTED record and a rejection
    ///         response back to the source.
    ///
    ///         The coordinator MUST verify `message.intentId` matches an
    ///         existing local intent where applicable.
    ///
    ///         This function is permissionless with respect to callers
    ///         because the TransportProvider authenticates the source.
    ///         Implementations MAY add a guard restricting callers to the
    ///         registered TransportProvider.
    /// @param  sourceChain  The chain that sent the message (authenticated
    ///                      by the TransportProvider).
    /// @param  messageId    Provider-assigned unique message identifier.
    /// @param  message      The decoded TransportMessage envelope.
    function handleTransportMessage(
        ChainId sourceChain,
        bytes32 messageId,
        ProtocolTypes.TransportMessage calldata message
    ) external;

    // ═══════════════════════════════════════════════════════════════════════
    // Recovery
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Rolls back a settlement whose SETTLEMENT_ACK never arrived.
    /// @dev    Recovery path for the case where the settlement instruction
    ///         was dispatched but the destination never confirmed mint
    ///         (e.g. transport failure, timeout). The coordinator:
    ///         1. Reads the TransferIntent from ITransferIntentManager.
    ///         2. Releases the reserved tokens back to the sender via
    ///            IAssetAdapter.releaseReservation(). No re-mint is
    ///            needed because tokens were only reserved, not burned.
    ///         3. Transitions the intent to ROLLED_BACK via
    ///            ITransferIntentManager.
    ///
    ///         This recovery is simpler than the old model (which required
    ///         re-minting after a failed burn) because tokens are never
    ///         destroyed until the destination confirms mint.
    ///
    ///         Access control is implementation-defined (expected role:
    ///         BRIDGE_ROLE or COMPLIANCE_ROLE).
    ///
    ///         Reverts if:
    ///         - Intent is not in RESERVED state.
    ///         - Asset release fails.
    ///         - State transition fails.
    /// @param  intentId  The identifier of the stuck settlement.
    function rollbackSettlement(
        bytes32 intentId
    ) external;

    // ═══════════════════════════════════════════════════════════════════════
    // Queries
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the current settlement state of a transfer intent.
    /// @dev    Delegates to ITransferIntentManager.getSettlementState().
    /// @param  intentId Unique intent identifier.
    /// @return state    Current SettlementState.
    function getSettlementStatus(
        bytes32 intentId
    ) external view returns (ProtocolTypes.SettlementState state);

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the configured TransferIntentManager address.
    /// @return manager The ITransferIntentManager instance.
    function getTransferIntentManager() external view returns (ITransferIntentManager manager);

    /// @notice Returns the configured CompliancePolicyProvider address.
    /// @return provider The ICompliancePolicyProvider instance.
    function getComplianceProvider() external view returns (ICompliancePolicyProvider provider);

    /// @notice Returns the configured AssetAdapter address.
    /// @return adapter The IAssetAdapter instance.
    function getAssetAdapter() external view returns (IAssetAdapter adapter);

    /// @notice Returns the configured TransportProvider address.
    /// @return provider The ITransportProvider instance.
    function getTransportProvider() external view returns (ITransportProvider provider);
}
