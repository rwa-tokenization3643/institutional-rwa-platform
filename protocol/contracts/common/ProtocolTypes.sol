// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Protocol Chain Identifier
/// @notice Bridge-agnostic chain identifier used across all protocol types.
/// @dev Wraps a uint64, leaving resolution to a specific bridge provider's
///      chain selector to the adapter layer.
type ChainId is uint64;

/// @title Protocol Types
/// @notice Single source of truth for all shared protocol enums and structs
///         used across the Institutional RWA Platform.
/// @dev Pure types only — no storage, no functions, no inheritance, no imports.
///      New enum values MUST be appended after the last value.
///      New struct fields MUST be appended after the last existing field.
///      Never remove, reorder, or insert values/fields in existing positions.
library ProtocolTypes {

    // =========================================================================
    // Enums
    // =========================================================================

    /// @notice High-level operation that a transfer intent represents.
    enum IntentAction {
        /// @dev Standard cross-chain transfer between two parties.
        TRANSFER,
        /// @dev Redemption — tokens returned to the issuer.
        REDEEM,
        /// @dev Issuance — new tokens minted to a recipient.
        ISSUE,
        /// @dev Transfer initiated by an authorized role (e.g. compliance or
        ///      bridge operator) rather than the token holder.
        FORCED_TRANSFER,
        /// @dev Intent to cancel an existing active intent.
        CANCEL
    }

    /// @notice Lifecycle states of a cross-chain transfer intent in the
    ///         two-phase settlement protocol.
    /// @dev Values are ordered to match the canonical state machine progression.
    ///      Bounds validation should use `uint256(type(SettlementState).max)`.
    enum SettlementState {
        /// @dev Intent created; awaiting Phase 1 validation by the destination chain.
        PENDING_VALIDATION,
        /// @dev Phase 1 passed; destination chain has approved the intent.
        VALIDATED,
        /// @dev Source chain has reserved (locked) the sender's tokens and
        ///      dispatched the settlement instruction. Awaiting destination
        ///      mint confirmation before burning.
        RESERVED,
        /// @dev Transfer completed; destination chain has minted tokens and
        ///      source chain has burned the reserved tokens.
        SETTLED,
        /// @dev Phase 1 rejected by the destination chain or force-cancelled
        ///      by an authorized role.
        REJECTED,
        /// @dev Deadline reached before the intent could be settled.
        EXPIRED,
        /// @dev Settlement failed and has been rolled back; reserved tokens
        ///      released on the source chain (no re-mint needed since burn
        ///      had not yet executed).
        ROLLED_BACK
    }

    /// @notice Identifies which phase of the two-phase settlement protocol a
    ///         cross-chain message belongs to.
    enum SettlementPhase {
        /// @dev Phase 1 validation request sent from source to destination.
        VALIDATION_REQUEST,
        /// @dev Phase 1 response; destination returns approval or rejection.
        VALIDATION_RESPONSE,
        /// @dev Phase 2 settlement instruction sent after source-chain burn.
        SETTLEMENT_INSTRUCTION,
        /// @dev Phase 2 confirmation; destination confirms successful mint.
        SETTLEMENT_ACK
    }

    /// @notice High-level categories for routing and processing cross-chain
    ///         protocol messages.
    enum MessageType {
        /// @dev Default value; not a valid message type.
        UNDEFINED,
        /// @dev Transfer intent payload (Phase 1 validation or Phase 2 settlement).
        TRANSFER_INTENT,
        /// @dev Response to a validation request from the destination chain.
        VALIDATION_RESPONSE,
        /// @dev Confirmation that settlement completed on the destination chain.
        SETTLEMENT_CONFIRMATION,
        /// @dev Identity proof relay for cross-chain identity synchronization.
        IDENTITY_PROOF,
        /// @dev Compliance configuration or policy update.
        COMPLIANCE_UPDATE,
        /// @dev Generic protocol governance message.
        GOVERNANCE
    }

    /// @notice Outcome of a settlement step.
    /// @dev Returned by bridge message handlers and recovery operations.
    enum SettlementResult {
        /// @dev Operation completed successfully.
        SUCCESS,
        /// @dev Operation failed.
        FAILED,
        /// @dev Operation is still pending.
        PENDING,
        /// @dev Operation was explicitly rejected.
        REJECTED,
        /// @dev Operation timed out before completion.
        TIMED_OUT
    }

    /// @notice Outcome of a compliance evaluation for a transfer or identity
    ///         check.
    /// @dev Returned by compliance providers and referenced during settlement
    ///      decisions.
    enum ComplianceResult {
        /// @dev Transfer or identity passed compliance checks.
        APPROVED,
        /// @dev Transfer or identity failed compliance checks.
        DENIED,
        /// @dev Compliance evaluation is in progress.
        PENDING,
        /// @dev Transfer flagged for manual review by a compliance officer.
        MANUAL_REVIEW,
        /// @dev Compliance evaluation encountered an error.
        ERROR
    }

    /// @notice Recovery actions the protocol can take for a failed or stuck
    ///         transfer intent.
    /// @dev Used by RecoveryManager to signal the intended remediation path.
    enum RecoveryAction {
        /// @dev Default value; no recovery action.
        NONE,
        /// @dev Roll back a stuck intent — re-mint tokens on the source chain.
        ROLLBACK,
        /// @dev Retry delivery of a cross-chain message.
        RETRY,
        /// @dev Force-cancel a validated intent without settlement.
        CANCEL,
        /// @dev Mark an unresponsive intent as expired.
        TIMEOUT
    }

    /// @notice Delivery status of a cross-chain transport message.
    /// @dev Used by ITransportProvider.getMessageStatus() to report transport
    ///      layer outcomes without conflating them with settlement results.
    enum TransportStatus {
        /// @dev Message has been submitted but delivery is not yet confirmed.
        PENDING,
        /// @dev Message was successfully delivered to the destination chain.
        DELIVERED,
        /// @dev Message delivery failed permanently.
        FAILED,
        /// @dev Message delivery timed out before confirmation.
        TIMED_OUT,
        /// @dev Message was cancelled before delivery completed.
        CANCELLED
    }

    /// @notice Flags that describe compliance policy provider capabilities.
    /// @dev Values correspond to bit positions in the uint256 bitmask
    ///      returned by `ICompliancePolicyProvider.getCapabilities()`.
    enum ComplianceCapability {
        /// @dev Provider can evaluate a full TransferIntent.
        TRANSFER_EVALUATION,
        /// @dev Provider supports multiple policy versions.
        POLICY_VERSIONING,
        /// @dev Provider supports batch evaluation of multiple intents.
        BATCH_EVALUATION,
        /// @dev Provider supports off-chain oracle-backed policies.
        ORACLE_POLICY
    }

    /// @notice Flags that describe transport provider capabilities.
    /// @dev Values correspond to bit positions in the uint256 bitmask
    ///      returned by `ITransportProvider.getCapabilities()`.
    enum TransportCapability {
        /// @dev Provider supports fee estimation.
        FEE_ESTIMATION,
        /// @dev Provider supports per-message delivery status queries.
        MESSAGE_STATUS,
        /// @dev Provider supports payload verification (e.g. signature checks).
        PAYLOAD_VERIFICATION,
        /// @dev Provider supports manual retry of failed messages.
        MANUAL_RETRY,
        /// @dev Provider supports batching multiple messages in a single transport.
        MESSAGE_BATCHING,
        /// @dev Provider supports fallback delivery via an alternative route.
        FALLBACK_DELIVERY
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Pure business fields describing a proposed cross-chain transfer.
    /// @dev Contains only the who / what / where / amount / proof aspects.
    ///      Lifecycle tracking belongs in `TransferRecord`.
    struct TransferIntent {
        /// @dev Unique intent identifier computed as
        ///      `keccak256(sourceChainId, nonce, sender, recipient, amount)`.
        bytes32 intentId;
        /// @dev The type of operation this intent represents.
        IntentAction action;

        // ── who ────────────────────────────────────────────────────────────
        /// @dev Sender wallet address on the source chain.
        address sender;
        /// @dev Recipient wallet address on the destination chain.
        address recipient;
        /// @dev Identity hash of the sender on the source chain.
        bytes32 senderIdentityHash;
        /// @dev Identity hash of the recipient on the destination chain.
        bytes32 recipientIdentityHash;

        // ── what ───────────────────────────────────────────────────────────
        /// @dev Unique identifier of the asset (token) being transferred.
        bytes32 assetId;
        /// @dev Partition or tranche identifier (`bytes32(0)` if unused).
        bytes32 partitionId;

        // ── where ──────────────────────────────────────────────────────────
        /// @dev Source chain identifier within the protocol's chain registry.
        ChainId sourceChainId;
        /// @dev Destination chain identifier within the protocol's chain registry.
        ChainId destinationChainId;

        // ── amount ─────────────────────────────────────────────────────────
        /// @dev Token amount in the asset's base units.
        uint256 amount;

        // ── proof ──────────────────────────────────────────────────────────
        /// @dev Hash of the compliance policy decision that validated this
        ///      intent.
        bytes32 policyDecisionHash;
        /// @dev Hash of the signed cross-chain message payload.
        bytes32 messageHash;

        // ── metadata ───────────────────────────────────────────────────────
        /// @dev Per-sender nonce ensuring globally unique intent IDs and
        ///      replay protection.
        uint64 nonce;
        /// @dev Block timestamp after which the intent expires and cannot be
        ///      settled. Part of the business object — the sender defines the
        ///      validity window.
        uint64 expiresAt;
    }

    /// @notice Encloses a `TransferIntent` with its lifecycle metadata.
    /// @dev The record is the on-chain storage unit; the intent is the pure
    ///      business payload.
    struct TransferRecord {
        /// @dev The embedded transfer business object.
        TransferIntent intent;
        /// @dev Current lifecycle state.
        SettlementState state;
        /// @dev Block timestamp when the record was created.
        uint64 createdAt;
        /// @dev Block timestamp of the most recent state transition.
        uint64 updatedAt;
        /// @dev Recovery action currently pending for this record, or `NONE`
        ///      if no recovery is in progress. Set and cleared by RecoveryManager.
        RecoveryAction pendingRecovery;
    }

    /// @notice Records the result of a compliance evaluation.
    /// @dev Created by compliance providers and referenced by settlement and
    ///      transfer validation decisions.
    struct ComplianceDecision {
        /// @dev Outcome of the compliance evaluation.
        ComplianceResult result;
        /// @dev Unique hash representing the decision and its evaluation inputs.
        bytes32 decisionHash;
        /// @dev Block timestamp when the evaluation was performed.
        uint64 evaluatedAt;
        /// @dev Block timestamp after which this decision is no longer valid.
        uint64 expiresAt;
        /// @dev Version identifier of the compliance policy used.
        bytes32 policyVersion;
    }

    /// @notice Minimum information required to verify a participant identity
    ///         during cross-chain settlement.
    /// @dev Intentionally avoids embedding ONCHAINID-specific implementation
    ///      details. Identities are referenced by opaque `bytes32` hashes
    ///      rather than contract addresses or interface types.
    struct IdentityProof {
        /// @dev Unique identifier of the participant identity (e.g., hash of
        ///      the ONCHAINID identity contract address).
        bytes32 identityId;
        /// @dev Hash of the identity claims submitted as proof.
        bytes32 claimHash;
        /// @dev Identity hash of the claim issuer that issued this proof.
        bytes32 issuerHash;
        /// @dev Timestamp when this proof was generated.
        uint64 timestamp;
        /// @dev Timestamp after which this proof expires.
        uint64 expiresAt;
        /// @dev Protocol version used to generate this proof.
        uint16 protocolVersion;
    }

    /// @notice Canonical cross-chain transport envelope.
    /// @dev This payload MUST be transport-agnostic — it must work equally
    ///      well with Chainlink CCIP, LayerZero, Hyperlane, and Axelar.
    ///      No provider-specific fields (e.g., gas limits, fees, transport
    ///      nonces) are included. The transport protocol is identified by
    ///      `transportId` so downstream code (e.g. RecoveryManager) can
    ///      distinguish the origin bridge without coupling to its API.
    struct TransportMessage {
        /// @dev Message envelope schema version (currently `1`). Independent
        ///      of `protocolVersion` — messages and protocol schemas evolve
        ///      on separate cadences.
        uint16 messageVersion;
        /// @dev Logical identifier of the bridge transport that generated this
        ///      message (e.g. `keccak256("CCIP")`, `keccak256("LayerZero")`).
        bytes32 transportId;
        /// @dev High-level message category used for routing.
        MessageType messageType;
        /// @dev Settlement phase for transfer-related messages.
        SettlementPhase phase;
        /// @dev Globally unique message identifier assigned by the transport
        ///      provider.
        bytes32 messageId;
        /// @dev Intent this message references (`bytes32(0)` for non-transfer
        ///      messages).
        bytes32 intentId;
        /// @dev Source chain identifier within the protocol's chain registry.
        ChainId sourceChainId;
        /// @dev Destination chain identifier within the protocol's chain registry.
        ChainId destinationChainId;
        /// @dev Block timestamp after which the message is stale and should
        ///      be discarded.
        uint64 expiresAt;
        /// @dev Sender wallet address on the source chain.
        address sender;
        /// @dev Recipient wallet address on the destination chain
        ///      (`address(0)` for non-transfer messages).
        address recipient;
        /// @dev Hash of the payload bytes. Enables signature verification
        ///      without decoding the full payload.
        bytes32 payloadHash;
        /// @dev ABI-encoded payload. Structure is determined by `messageType`
        ///      and `phase`.
        bytes payload;
    }
}
