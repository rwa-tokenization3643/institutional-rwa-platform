// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ChainId, ProtocolTypes} from "../common/ProtocolTypes.sol";
import {IProtocolAccessManager} from "../access/IProtocolAccessManager.sol";
import {ISettlementCoordinator} from "../interfaces/ISettlementCoordinator.sol";
import {ITransferIntentManager} from "../interfaces/ITransferIntentManager.sol";
import {ITransportProvider} from "../interfaces/ITransportProvider.sol";
import {ICompliancePolicyProvider} from "../interfaces/ICompliancePolicyProvider.sol";
import {IAssetAdapter} from "../interfaces/IAssetAdapter.sol";

/// @title Settlement Coordinator
/// @notice Orchestrates the two-phase cross-chain settlement protocol.
/// @dev The coordinator owns workflow, NOT persistence. Every business operation
///      is delegated to one of four sub-components:
///
///      | Component              | Responsibility                             |
///      |------------------------|--------------------------------------------|
///      | ITransferIntentManager | Intent lifecycle, persistence, state       |
///      | ICompliancePolicyProvider | Compliance evaluation (view-only)       |
///      | IAssetAdapter          | Token-standard-agnostic asset operations   |
///      | ITransportProvider     | Cross-chain message transport              |
///
///      The coordinator encodes, decodes, interprets, and dispatches messages
///      based on `messageType` and `phase`. The transport provider transports
///      opaque `TransportMessage` envelopes without inspecting their content.
///
///      ── No Vendor Exposure ──
///
///      This contract MUST never interact with ERC-3643, ERC-1400, CCIP, ACE,
///      or ONCHAINID contracts directly. Every interaction is mediated by one
///      of the four sub-component interfaces.
///
///      ── Reservation Strategy ──
///
///      Asset reservation is deferred until Phase 2 (after destination
///      approval). This avoids locking the sender's tokens during the
///      Phase 1 validation window and eliminates wasted reservations
///      when the destination rejects or transport fails. Lock contention
///      is dramatically reduced — the sender retains full use of their
///      tokens until both sides agree.
///
///      ── Audit Trail ──
///
///      Failed transfer attempts are NEVER silently discarded. If compliance
///      or asset reservation fails, the intent is created and marked REJECTED
///      rather than reverting. This preserves an on-chain audit record of
///      every attempted transfer.
///
///      ── Invariants ──
///
///      1. The coordinator NEVER stores TransferIntent records or settlement
///         state locally. All persistence lives in ITransferIntentManager.
///      2. The coordinator NEVER evaluates compliance — it delegates to
///         ICompliancePolicyProvider.
///      3. The coordinator NEVER performs token operations — it delegates to
///         IAssetAdapter.
///      4. The coordinator NEVER communicates with transport providers
///         directly — it delegates to ITransportAdapter.
///      5. Transport callbacks are ONLY accepted from the registered
///         TransportProvider address.
contract SettlementCoordinator is ISettlementCoordinator, ERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // Errors
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Migrate to ProtocolErrors.sol once that shared library exists.

    /// @dev One of the constructor arguments is the zero address.
    error SettlementCoordinator__ZeroAddress(string component);

    /// @dev The caller is not the registered transport provider.
    error SettlementCoordinator__UnauthorizedCaller(address caller);

    /// @dev The caller does not hold the required role.
    error SettlementCoordinator__UnauthorizedRole(address caller, bytes32 role);

    /// @dev `handleTransportMessage` received an unsupported message type.
    error SettlementCoordinator__InvalidMessageType(
        ProtocolTypes.MessageType messageType
    );

    /// @dev `handleTransportMessage` received a valid message type but an
    ///      incorrect phase for the dispatcher.
    error SettlementCoordinator__InvalidPhase(
        ProtocolTypes.SettlementPhase phase
    );

    /// @dev An inbound message's source or destination chain does not match
    ///      the authenticated or local chain.
    error SettlementCoordinator__ChainMismatch(
        ChainId expected,
        ChainId actual
    );

    /// @dev `rollbackSettlement` was called for an intent not in RESERVED
    ///      state.
    error SettlementCoordinator__NotSettling(bytes32 intentId);

    /// @dev Transport dispatch failed for the given intent and chain.
    error SettlementCoordinator__TransportFailed(
        bytes32 intentId,
        ChainId destinationChain
    );

    /// @dev An inbound message references an intent that does not exist
    ///      locally.
    error SettlementCoordinator__IntentNotFound(bytes32 intentId);

    // ═══════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Migrate to ProtocolEvents.sol once that shared library exists.

    /// @dev A transfer intent was submitted for processing.
    event TransferSubmitted(
        bytes32 indexed intentId,
        address indexed sender,
        address indexed recipient
    );

    /// @dev A Phase 1 validation request was dispatched to the destination
    ///      chain.
    event ValidationRequestSent(
        bytes32 indexed intentId,
        ChainId destinationChain
    );

    /// @dev A Phase 1 validation response was sent back to the source chain.
    event ValidationResponseSent(
        bytes32 indexed intentId,
        ProtocolTypes.ComplianceResult result,
        ChainId destinationChain
    );

    /// @dev A Phase 2 settlement instruction was sent to the destination
    ///      chain.
    event SettlementInstructionSent(
        bytes32 indexed intentId,
        ChainId destinationChain
    );

    /// @dev A Phase 2 settlement acknowledgement was sent back to the source
    ///      chain.
    event SettlementAckSent(
        bytes32 indexed intentId,
        ChainId destinationChain
    );

    /// @dev An intent reached a terminal state (SETTLED or ROLLED_BACK).
    event IntentCompleted(
        bytes32 indexed intentId,
        ProtocolTypes.SettlementState finalState
    );

    /// @dev An intent was rejected due to a failed compliance check or asset
    ///      reservation.
    event IntentRejected(
        bytes32 indexed intentId,
        bytes reason
    );

    /// @dev An intent was rolled back after a destination-side mint failure.
    event IntentRolledBack(
        bytes32 indexed intentId,
        address recoveredTo,
        uint256 amount
    );

    // ═══════════════════════════════════════════════════════════════════════
    // Storage
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Tracks processed cross-chain message IDs for replay protection.
    ///      Once a messageId is marked, it can never be processed again.
    ///      This is defense-in-depth — the state machine provides secondary
    ///      protection, but explicit message deduplication prevents double
    ///      settlement even if the state machine is refactored.
    mapping(bytes32 messageId => bool processed) private _processedMessages;

    /// @dev Protocol-wide access manager for role-based access control.
    IProtocolAccessManager private immutable _accessManager;

    /// @dev This chain's identifier within the protocol's chain registry.
    ChainId private immutable _chainId;

    /// @dev The BRIDGE_ROLE identifier, cached at construction.
    bytes32 private immutable _bridgeRole;

    /// @dev Intent lifecycle, persistence, and state machine.
    ITransferIntentManager private immutable _transferIntentManager;

    /// @dev View-only compliance evaluation provider.
    ICompliancePolicyProvider private immutable _compliancePolicyProvider;

    /// @dev Token-standard-agnostic asset operations.
    IAssetAdapter private immutable _assetAdapter;

    /// @dev Transport-agnostic cross-chain message provider.
    ITransportProvider private immutable _transportProvider;

    // ═══════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Deploys the SettlementCoordinator and stores immutable
    ///         references to all sub-components.
    /// @dev All component addresses MUST be non-zero. The caller MUST ensure
    ///      this contract is granted BRIDGE_ROLE in ProtocolAccessManager
    ///      after deployment so that `transitionState` calls succeed.
    /// @param accessManager_ Protocol-wide access manager.
    /// @param chainId_ This chain's protocol-level identifier.
    /// @param transferIntentManager_ Intent lifecycle manager.
    /// @param compliancePolicyProvider_ Compliance evaluation provider.
    /// @param assetAdapter_ Token-standard-agnostic asset adapter.
    /// @param transportProvider_ Cross-chain message transport provider.
    constructor(
        IProtocolAccessManager accessManager_,
        ChainId chainId_,
        ITransferIntentManager transferIntentManager_,
        ICompliancePolicyProvider compliancePolicyProvider_,
        IAssetAdapter assetAdapter_,
        ITransportProvider transportProvider_
    ) {
        if (address(accessManager_) == address(0)) {
            revert SettlementCoordinator__ZeroAddress("accessManager");
        }
        if (address(transferIntentManager_) == address(0)) {
            revert SettlementCoordinator__ZeroAddress("transferIntentManager");
        }
        if (address(compliancePolicyProvider_) == address(0)) {
            revert SettlementCoordinator__ZeroAddress("compliancePolicyProvider");
        }
        if (address(assetAdapter_) == address(0)) {
            revert SettlementCoordinator__ZeroAddress("assetAdapter");
        }
        if (address(transportProvider_) == address(0)) {
            revert SettlementCoordinator__ZeroAddress("transportProvider");
        }

        _accessManager = accessManager_;
        _chainId = chainId_;
        _bridgeRole = accessManager_.BRIDGE_ROLE();
        _transferIntentManager = transferIntentManager_;
        _compliancePolicyProvider = compliancePolicyProvider_;
        _assetAdapter = assetAdapter_;
        _transportProvider = transportProvider_;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC-165
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(ISettlementCoordinator).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Modifiers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Reverts if the caller is not the registered transport provider.
    modifier onlyTransportProvider() {
        if (msg.sender != address(_transportProvider)) {
            revert SettlementCoordinator__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /// @dev Reverts if the caller does not hold the required role.
    modifier onlyRole(bytes32 role) {
        if (!_accessManager.hasRole(role, msg.sender)) {
            revert SettlementCoordinator__UnauthorizedRole(msg.sender, role);
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // User Entry
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ISettlementCoordinator
    function submitTransfer(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bytes32 intentId) {
        intentId = _transferIntentManager.createTransferIntent(intent);

        emit TransferSubmitted(intentId, intent.sender, intent.recipient);

        ProtocolTypes.TransferIntent memory intentMem = intent;

        if (!_evaluateCompliance(intentMem)) {
            _transferIntentManager.transitionState(
                intentId,
                ProtocolTypes.SettlementState.REJECTED
            );
            emit IntentRejected(intentId, bytes("Compliance check failed"));
            return intentId;
        }

        bytes memory payload = abi.encode(intentMem);

        _dispatchTransportMessage(
            intentMem.destinationChainId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
            intentId,
            payload,
            intentMem.expiresAt
        );

        emit ValidationRequestSent(intentId, intentMem.destinationChainId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Transport Callback
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ISettlementCoordinator
    function handleTransportMessage(
        ChainId sourceChain,
        bytes32 messageId,
        ProtocolTypes.TransportMessage calldata message
    ) external onlyTransportProvider {
        if (
            ChainId.unwrap(sourceChain)
                != ChainId.unwrap(message.sourceChainId)
        ) {
            revert SettlementCoordinator__ChainMismatch(
                sourceChain, message.sourceChainId
            );
        }
        if (
            ChainId.unwrap(message.destinationChainId)
                != ChainId.unwrap(_chainId)
        ) {
            revert SettlementCoordinator__ChainMismatch(
                _chainId, message.destinationChainId
            );
        }

        if (_processedMessages[messageId]) {
            return;
        }

        ProtocolTypes.MessageType mt = message.messageType;
        ProtocolTypes.SettlementPhase ph = message.phase;

        if (mt == ProtocolTypes.MessageType.TRANSFER_INTENT) {
            if (ph == ProtocolTypes.SettlementPhase.VALIDATION_REQUEST) {
                _handleValidationRequest(sourceChain, messageId, message);
                _processedMessages[messageId] = true;
            } else if (
                ph == ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION
            ) {
                _handleSettlementInstruction(sourceChain, messageId, message);
                _processedMessages[messageId] = true;
            } else {
                revert SettlementCoordinator__InvalidPhase(ph);
            }
        } else if (mt == ProtocolTypes.MessageType.VALIDATION_RESPONSE) {
            if (ph != ProtocolTypes.SettlementPhase.VALIDATION_RESPONSE) {
                revert SettlementCoordinator__InvalidPhase(ph);
            }
            _handleValidationResponse(sourceChain, messageId, message);
            _processedMessages[messageId] = true;
        } else if (mt == ProtocolTypes.MessageType.SETTLEMENT_CONFIRMATION) {
            if (ph != ProtocolTypes.SettlementPhase.SETTLEMENT_ACK) {
                revert SettlementCoordinator__InvalidPhase(ph);
            }
            _handleSettlementAcknowledgement(sourceChain, messageId, message);
            _processedMessages[messageId] = true;
        } else {
            revert SettlementCoordinator__InvalidMessageType(mt);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Recovery
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ISettlementCoordinator
    function rollbackSettlement(
        bytes32 intentId
    ) external onlyRole(_bridgeRole) {
        ProtocolTypes.SettlementState currentState
            = _transferIntentManager.getSettlementState(intentId);

        if (currentState != ProtocolTypes.SettlementState.RESERVED) {
            revert SettlementCoordinator__NotSettling(intentId);
        }

        ProtocolTypes.TransferIntent memory intent
            = _transferIntentManager.getTransferIntent(intentId);

        _assetAdapter.releaseReservation(intent);

        _transferIntentManager.transitionState(
            intentId,
            ProtocolTypes.SettlementState.ROLLED_BACK
        );

        emit IntentRolledBack(intentId, intent.sender, intent.amount);
        emit IntentCompleted(intentId, ProtocolTypes.SettlementState.ROLLED_BACK);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Queries
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ISettlementCoordinator
    function getSettlementStatus(
        bytes32 intentId
    ) external view returns (ProtocolTypes.SettlementState state) {
        return _transferIntentManager.getSettlementState(intentId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ISettlementCoordinator
    function getTransferIntentManager()
        external view returns (ITransferIntentManager manager)
    {
        return _transferIntentManager;
    }

    /// @inheritdoc ISettlementCoordinator
    function getComplianceProvider()
        external view returns (ICompliancePolicyProvider provider)
    {
        return _compliancePolicyProvider;
    }

    /// @inheritdoc ISettlementCoordinator
    function getAssetAdapter()
        external view returns (IAssetAdapter adapter)
    {
        return _assetAdapter;
    }

    /// @inheritdoc ISettlementCoordinator
    function getTransportProvider()
        external view returns (ITransportProvider provider)
    {
        return _transportProvider;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Validation Request Handler (Destination Chain)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Processes an incoming Phase 1 validation request from a source
    ///         chain.
    /// @dev Decodes the TransferIntent from the message payload, creates a
    ///      local intent record, evaluates compliance, and sends a
    ///      VALIDATION_RESPONSE back to the source. No assets are reserved
    ///      on the destination during Phase 1 — reservation happens on the
    ///      source only after both sides agree (during Phase 2 settlement).
    ///      Failures produce a REJECTED local record and a rejection response.
    /// @param sourceChain The authenticated source chain (verified by
    ///        transport provider).
    /// @param messageId Provider-assigned message identifier.
    /// @param message The decoded TransportMessage envelope.
    function _handleValidationRequest(
        ChainId sourceChain,
        bytes32 messageId,
        ProtocolTypes.TransportMessage calldata message
    ) internal {
        ProtocolTypes.TransferIntent memory intent
            = abi.decode(message.payload, (ProtocolTypes.TransferIntent));

        if (_transferIntentManager.exists(intent.intentId)) {
            return;
        }

        bytes32 intentId = _transferIntentManager.createTransferIntent(intent);

        if (!_evaluateCompliance(intent)) {
            _transferIntentManager.transitionState(
                intentId,
                ProtocolTypes.SettlementState.REJECTED
            );
            emit IntentRejected(
                intentId, bytes("Destination compliance check failed")
            );
            _sendValidationResponse(
                intentId,
                message.sourceChainId,
                ProtocolTypes.ComplianceResult.DENIED
            );
            return;
        }

        _transferIntentManager.transitionState(
            intentId,
            ProtocolTypes.SettlementState.VALIDATED
        );

        _sendValidationResponse(
            intentId,
            message.sourceChainId,
            ProtocolTypes.ComplianceResult.APPROVED
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Validation Response Handler (Source Chain)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Processes an incoming Phase 1 validation response from the
    ///         destination chain.
    /// @dev Decodes the ComplianceResult from the message payload. If
    ///      approved, transitions to VALIDATED, reserves assets (locking
    ///      sender's tokens), transitions to RESERVED, and dispatches a
    ///      SETTLEMENT_INSTRUCTION. The reserved tokens are NOT burned
    ///      here — burning happens only after the destination confirms
    ///      mint via SETTLEMENT_ACK. This ensures tokens are never
    ///      destroyed unless delivery is confirmed. If reservation fails
    ///      (sender spent tokens between submit and response), the intent
    ///      transitions to REJECTED. If rejected by destination, simply
    ///      transitions to REJECTED.
    /// @param sourceChain The authenticated source chain (verified by
    ///        transport provider).
    /// @param messageId Provider-assigned message identifier.
    /// @param message The decoded TransportMessage envelope.
    function _handleValidationResponse(
        ChainId sourceChain,
        bytes32 messageId,
        ProtocolTypes.TransportMessage calldata message
    ) internal {
        ProtocolTypes.ComplianceResult result
            = abi.decode(message.payload, (ProtocolTypes.ComplianceResult));

        bytes32 intentId = message.intentId;
        ProtocolTypes.TransferIntent memory intent
            = _transferIntentManager.getTransferIntent(intentId);

        if (_transferIntentManager.getSettlementState(intentId) != ProtocolTypes.SettlementState.PENDING_VALIDATION) {
            return;
        }

        if (result != ProtocolTypes.ComplianceResult.APPROVED) {
            _transferIntentManager.transitionState(
                intentId,
                ProtocolTypes.SettlementState.REJECTED
            );
            emit IntentRejected(
                intentId, bytes("Destination rejected validation")
            );
            return;
        }

        _transferIntentManager.transitionState(
            intentId,
            ProtocolTypes.SettlementState.VALIDATED
        );

        if (!_reserveAssets(intent)) {
            _transferIntentManager.transitionState(
                intentId,
                ProtocolTypes.SettlementState.REJECTED
            );
            emit IntentRejected(
                intentId, bytes("Asset reservation failed after destination approval")
            );
            return;
        }

        _transferIntentManager.transitionState(
            intentId,
            ProtocolTypes.SettlementState.RESERVED
        );

        _dispatchTransportMessage(
            intent.destinationChainId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION,
            intentId,
            bytes(""),
            intent.expiresAt
        );

        emit SettlementInstructionSent(intentId, intent.destinationChainId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Settlement Instruction Handler (Destination Chain)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Processes an incoming Phase 2 settlement instruction from the
    ///         source chain.
    /// @dev Mints assets to the recipient, transitions the intent to SETTLED,
    ///      and sends a SETTLEMENT_ACK back to the source.
    /// @param sourceChain The authenticated source chain (verified by
    ///        transport provider).
    /// @param messageId Provider-assigned message identifier.
    /// @param message The decoded TransportMessage envelope.
    function _handleSettlementInstruction(
        ChainId sourceChain,
        bytes32 messageId,
        ProtocolTypes.TransportMessage calldata message
    ) internal {
        bytes32 intentId = message.intentId;
        ProtocolTypes.TransferIntent memory intent
            = _transferIntentManager.getTransferIntent(intentId);

        if (_transferIntentManager.getSettlementState(intentId) == ProtocolTypes.SettlementState.SETTLED) {
            return;
        }

        _assetAdapter.mintAssets(intent);

        _transferIntentManager.transitionState(
            intentId,
            ProtocolTypes.SettlementState.SETTLED
        );

        _dispatchTransportMessage(
            sourceChain,
            ProtocolTypes.MessageType.SETTLEMENT_CONFIRMATION,
            ProtocolTypes.SettlementPhase.SETTLEMENT_ACK,
            intentId,
            bytes(""),
            intent.expiresAt
        );

        emit SettlementAckSent(intentId, sourceChain);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Settlement Acknowledgement Handler (Source Chain)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Processes an incoming SETTLEMENT_ACK confirming the
    ///         destination mint completed.
    /// @dev Burns the reserved tokens (which were locked in RESERVED
    ///      state), then transitions to SETTLED. Burning on ack ensures
    ///      tokens are never destroyed unless the destination has
    ///      confirmed successful mint. If the burn fails (reverts), the
    ///      entire handler reverts and the messageId is NOT marked as
    ///      processed — allowing retry.
    /// @param sourceChain The authenticated source chain (verified by
    ///        transport provider).
    /// @param messageId Provider-assigned message identifier.
    /// @param message The decoded TransportMessage envelope.
    function _handleSettlementAcknowledgement(
        ChainId sourceChain,
        bytes32 messageId,
        ProtocolTypes.TransportMessage calldata message
    ) internal {
        bytes32 intentId = message.intentId;
        ProtocolTypes.TransferIntent memory intent
            = _transferIntentManager.getTransferIntent(intentId);

        if (_transferIntentManager.getSettlementState(intentId) == ProtocolTypes.SettlementState.SETTLED) {
            return;
        }

        _assetAdapter.burnReservedAssets(intent);

        _transferIntentManager.transitionState(
            intentId,
            ProtocolTypes.SettlementState.SETTLED
        );

        emit IntentCompleted(intentId, ProtocolTypes.SettlementState.SETTLED);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Compliance & Reservation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Evaluates a transfer intent against the compliance provider.
    /// @dev Wraps the external view call in try/catch so that provider
    ///      reverts produce a `false` result rather than propagating the
    ///      revert. This preserves the audit trail: callers can transition
    ///      the intent to REJECTED instead of reverting the entire
    ///      transaction.
    /// @param intent The transfer intent to evaluate.
    /// @return passed True if the compliance provider returned APPROVED.
    function _evaluateCompliance(
        ProtocolTypes.TransferIntent memory intent
    ) internal returns (bool passed) {
        try _compliancePolicyProvider.evaluateTransferIntent(intent) returns (
            ProtocolTypes.ComplianceDecision memory decision
        ) {
            return decision.result == ProtocolTypes.ComplianceResult.APPROVED;
        } catch {
            return false;
        }
    }

    /// @notice Reserves assets for a transfer intent through the asset
    ///         adapter.
    /// @dev Wraps the external call in try/catch so that adapter reverts
    ///      produce a `false` result. This preserves the audit trail:
    ///      callers can transition the intent to REJECTED instead of
    ///      reverting the entire transaction.
    /// @param intent The transfer intent requiring a reservation.
    /// @return reserved True if the asset adapter confirmed the reservation.
    function _reserveAssets(
        ProtocolTypes.TransferIntent memory intent
    ) internal returns (bool reserved) {
        try _assetAdapter.reserveAssets(intent) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Transport
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Sends a VALIDATION_RESPONSE message back to the source chain.
    /// @param intentId The intent being responded to.
    /// @param destinationChain The chain to send the response to (the source
    ///        chain of the original validation request).
    /// @param result The compliance result (APPROVED or DENIED).
    function _sendValidationResponse(
        bytes32 intentId,
        ChainId destinationChain,
        ProtocolTypes.ComplianceResult result
    ) internal {
        bytes memory payload = abi.encode(result);

        ProtocolTypes.TransferIntent memory intent
            = _transferIntentManager.getTransferIntent(intentId);

        _dispatchTransportMessage(
            destinationChain,
            ProtocolTypes.MessageType.VALIDATION_RESPONSE,
            ProtocolTypes.SettlementPhase.VALIDATION_RESPONSE,
            intentId,
            payload,
            intent.expiresAt
        );

        emit ValidationResponseSent(intentId, result, destinationChain);
    }

    /// @notice Encodes a TransportMessage and dispatches it through the
    ///         transport provider.
    /// @dev Reverts if the transport provider rejects the message (e.g.
    ///      unsupported destination chain, insufficient fees). The caller
    ///      should let this revert propagate — previous state changes are
    ///      rolled back atomically.
    /// @param destinationChain Target chain for the message.
    /// @param messageType High-level message category.
    /// @param phase Settlement phase.
    /// @param intentId Intent this message references.
    /// @param payload ABI-encoded message payload.
    /// @param expiresAt Block timestamp after which the message is stale.
    function _dispatchTransportMessage(
        ChainId destinationChain,
        ProtocolTypes.MessageType messageType,
        ProtocolTypes.SettlementPhase phase,
        bytes32 intentId,
        bytes memory payload,
        uint64 expiresAt
    ) internal {
        ProtocolTypes.TransportMessage memory msg_ = ProtocolTypes
            .TransportMessage({
            messageVersion: 1,
            transportId: _transportProvider.getTransportId(),
            messageType: messageType,
            phase: phase,
            messageId: bytes32(0),
            intentId: intentId,
            sourceChainId: _chainId,
            destinationChainId: destinationChain,
            expiresAt: expiresAt,
            sender: address(this),
            recipient: address(0),
            payloadHash: keccak256(payload),
            payload: payload
        });

        _transportProvider.sendMessage(destinationChain, msg_);
    }
}
