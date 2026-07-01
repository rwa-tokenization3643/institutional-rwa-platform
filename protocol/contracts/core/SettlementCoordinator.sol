// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ChainId, ProtocolTypes} from "../common/ProtocolTypes.sol";
import {ISettlementCoordinator} from "../interfaces/ISettlementCoordinator.sol";
import {ITransferIntentManager} from "../interfaces/ITransferIntentManager.sol";
import {ITransportProvider} from "../interfaces/ITransportProvider.sol";
import {ICompliancePolicyProvider} from "../interfaces/ICompliancePolicyProvider.sol";
import {IAssetAdapter} from "../interfaces/IAssetAdapter.sol";

/// @title Settlement Coordinator
/// @notice Workflow engine orchestrating cross-chain transfers through four
///         sub-components.
/// @dev Conforms to ISettlementCoordinator. All settlement state lives in
///      ITransferIntentManager — the coordinator owns workflow, not persistence.
contract SettlementCoordinator is ISettlementCoordinator, ERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // Errors
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Migrate to ProtocolErrors.sol once that shared library exists.

    error SettlementCoordinator__ZeroAddress(string component);
    error SettlementCoordinator__InvalidMessageType(ProtocolTypes.MessageType messageType);
    error SettlementCoordinator__InvalidPhase(ProtocolTypes.SettlementPhase phase);
    error SettlementCoordinator__IntentNotFound(bytes32 intentId);
    error SettlementCoordinator__InvalidState(
        bytes32 intentId,
        ProtocolTypes.SettlementState expected,
        ProtocolTypes.SettlementState actual
    );
    error SettlementCoordinator__MismatchedChain(ChainId expected, ChainId actual);
    error SettlementCoordinator__NotSettling(bytes32 intentId);
    error SettlementCoordinator__TransportFailed(bytes32 intentId, ChainId destinationChain);

    // ═══════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Migrate to ProtocolEvents.sol once that shared library exists.

    event TransferSubmitted(bytes32 indexed intentId, address indexed sender, address indexed recipient);
    event ValidationRequestSent(bytes32 indexed intentId, ChainId destinationChain);
    event ValidationResponseSent(
        bytes32 indexed intentId,
        ProtocolTypes.ComplianceResult result,
        ChainId responseChain
    );
    event SettlementInstructionSent(bytes32 indexed intentId, ChainId destinationChain);
    event SettlementAckSent(bytes32 indexed intentId, ChainId destinationChain);
    event IntentCompleted(bytes32 indexed intentId, ProtocolTypes.SettlementState finalState);
    event IntentRejected(bytes32 indexed intentId, bytes reason);

    // ═══════════════════════════════════════════════════════════════════════
    // Storage
    // ═══════════════════════════════════════════════════════════════════════

    ChainId private immutable _chainId;
    ITransferIntentManager private immutable _transferIntentManager;
    ICompliancePolicyProvider private immutable _compliancePolicyProvider;
    IAssetAdapter private immutable _assetAdapter;
    ITransportProvider private immutable _transportProvider;

    // ═══════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════

    constructor(
        ChainId chainId_,
        ITransferIntentManager transferIntentManager_,
        ICompliancePolicyProvider compliancePolicyProvider_,
        IAssetAdapter assetAdapter_,
        ITransportProvider transportProvider_
    ) {
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

        _chainId = chainId_;
        _transferIntentManager = transferIntentManager_;
        _compliancePolicyProvider = compliancePolicyProvider_;
        _assetAdapter = assetAdapter_;
        _transportProvider = transportProvider_;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC-165
    // ═══════════════════════════════════════════════════════════════════════

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(ISettlementCoordinator).interfaceId || super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // User Entry
    // ═══════════════════════════════════════════════════════════════════════

    function submitTransfer(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bytes32 intentId) {
        intentId = _transferIntentManager.createTransferIntent(intent);

        emit TransferSubmitted(intentId, intent.sender, intent.recipient);

        ProtocolTypes.TransferIntent memory intentMem = intent;

        if (!_evaluateCompliance(intentMem)) {
            _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.REJECTED);
            emit IntentRejected(intentId, bytes("Compliance check failed"));
            return intentId;
        }

        if (!_reserveAssets(intentMem)) {
            _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.REJECTED);
            emit IntentRejected(intentId, bytes("Asset reservation failed"));
            return intentId;
        }

        _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.VALIDATED);

        bytes memory payload = abi.encode(intentMem);
        _sendMessage(
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

    function handleTransportMessage(
        ChainId sourceChain,
        bytes32 messageId,
        ProtocolTypes.TransportMessage calldata message
    ) external {
        if (ChainId.unwrap(sourceChain) != ChainId.unwrap(message.sourceChainId)) {
            revert SettlementCoordinator__MismatchedChain(sourceChain, message.sourceChainId);
        }
        if (ChainId.unwrap(message.destinationChainId) != ChainId.unwrap(_chainId)) {
            revert SettlementCoordinator__MismatchedChain(_chainId, message.destinationChainId);
        }

        if (message.messageType == ProtocolTypes.MessageType.TRANSFER_INTENT) {
            if (message.phase == ProtocolTypes.SettlementPhase.VALIDATION_REQUEST) {
                _handleValidationRequest(sourceChain, messageId, message);
            } else if (message.phase == ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION) {
                _handleSettlementInstruction(sourceChain, messageId, message);
            } else {
                revert SettlementCoordinator__InvalidPhase(message.phase);
            }
        } else if (message.messageType == ProtocolTypes.MessageType.VALIDATION_RESPONSE) {
            if (message.phase != ProtocolTypes.SettlementPhase.VALIDATION_RESPONSE) {
                revert SettlementCoordinator__InvalidPhase(message.phase);
            }
            _handleValidationResponse(sourceChain, messageId, message);
        } else if (message.messageType == ProtocolTypes.MessageType.SETTLEMENT_CONFIRMATION) {
            if (message.phase != ProtocolTypes.SettlementPhase.SETTLEMENT_ACK) {
                revert SettlementCoordinator__InvalidPhase(message.phase);
            }
            _handleSettlementAck(sourceChain, messageId, message);
        } else {
            revert SettlementCoordinator__InvalidMessageType(message.messageType);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Recovery
    // ═══════════════════════════════════════════════════════════════════════

    function rollbackSettlement(bytes32 intentId) external {
        ProtocolTypes.SettlementState currentState = _transferIntentManager.getSettlementState(intentId);
        if (currentState != ProtocolTypes.SettlementState.SETTLING) {
            revert SettlementCoordinator__NotSettling(intentId);
        }

        ProtocolTypes.TransferIntent memory intent = _transferIntentManager.getTransferIntent(intentId);

        _assetAdapter.rollbackReservation(intent);

        _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.ROLLED_BACK);

        emit IntentCompleted(intentId, ProtocolTypes.SettlementState.ROLLED_BACK);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Queries
    // ═══════════════════════════════════════════════════════════════════════

    function getSettlementStatus(bytes32 intentId) external view returns (ProtocolTypes.SettlementState state) {
        return _transferIntentManager.getSettlementState(intentId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration
    // ═══════════════════════════════════════════════════════════════════════

    function getTransferIntentManager() external view returns (ITransferIntentManager manager) {
        return _transferIntentManager;
    }

    function getComplianceProvider() external view returns (ICompliancePolicyProvider provider) {
        return _compliancePolicyProvider;
    }

    function getAssetAdapter() external view returns (IAssetAdapter adapter) {
        return _assetAdapter;
    }

    function getTransportProvider() external view returns (ITransportProvider provider) {
        return _transportProvider;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Message Handlers
    // ═══════════════════════════════════════════════════════════════════════

    function _handleValidationRequest(
        ChainId,
        bytes32,
        ProtocolTypes.TransportMessage calldata message
    ) internal {
        ProtocolTypes.TransferIntent memory intent = abi.decode(message.payload, (ProtocolTypes.TransferIntent));

        bytes32 intentId = _transferIntentManager.createTransferIntent(intent);

        if (!_evaluateCompliance(intent)) {
            _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.REJECTED);
            emit IntentRejected(intentId, bytes("Destination compliance check failed"));
            _sendValidationResponse(intentId, message.sourceChainId, ProtocolTypes.ComplianceResult.DENIED);
            return;
        }

        if (!_reserveAssets(intent)) {
            _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.REJECTED);
            emit IntentRejected(intentId, bytes("Destination asset reservation failed"));
            _sendValidationResponse(intentId, message.sourceChainId, ProtocolTypes.ComplianceResult.DENIED);
            return;
        }

        _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.VALIDATED);

        _sendValidationResponse(intentId, message.sourceChainId, ProtocolTypes.ComplianceResult.APPROVED);
    }

    function _handleValidationResponse(
        ChainId,
        bytes32,
        ProtocolTypes.TransportMessage calldata message
    ) internal {
        (ProtocolTypes.ComplianceResult result) = abi.decode(message.payload, (ProtocolTypes.ComplianceResult));

        bytes32 intentId = message.intentId;
        ProtocolTypes.TransferIntent memory intent = _transferIntentManager.getTransferIntent(intentId);

        if (result != ProtocolTypes.ComplianceResult.APPROVED) {
            _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.REJECTED);
            emit IntentRejected(intentId, bytes("Destination rejected validation"));

            try _assetAdapter.releaseReservation(intent) {} catch { }
            return;
        }

        try _assetAdapter.burnReservedAssets(intent) returns (bool burned) {
            if (!burned) {
                revert SettlementCoordinator__InvalidState(intentId, ProtocolTypes.SettlementState.SETTLING, ProtocolTypes.SettlementState.VALIDATED);
            }
        } catch {
            revert SettlementCoordinator__InvalidState(intentId, ProtocolTypes.SettlementState.SETTLING, ProtocolTypes.SettlementState.VALIDATED);
        }

        _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.SETTLING);

        _sendMessage(
            intent.destinationChainId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION,
            intentId,
            bytes(""),
            intent.expiresAt
        );

        emit SettlementInstructionSent(intentId, intent.destinationChainId);
    }

    function _handleSettlementInstruction(
        ChainId sourceChain,
        bytes32,
        ProtocolTypes.TransportMessage calldata message
    ) internal {
        bytes32 intentId = message.intentId;
        ProtocolTypes.TransferIntent memory intent = _transferIntentManager.getTransferIntent(intentId);

        _assetAdapter.mintAssets(intent);

        _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.SETTLED);

        _sendMessage(
            sourceChain,
            ProtocolTypes.MessageType.SETTLEMENT_CONFIRMATION,
            ProtocolTypes.SettlementPhase.SETTLEMENT_ACK,
            intentId,
            bytes(""),
            intent.expiresAt
        );

        emit SettlementAckSent(intentId, sourceChain);
    }

    function _handleSettlementAck(
        ChainId,
        bytes32,
        ProtocolTypes.TransportMessage calldata message
    ) internal {
        bytes32 intentId = message.intentId;
        _transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.SETTLED);

        emit IntentCompleted(intentId, ProtocolTypes.SettlementState.SETTLED);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Compliance & Reservation
    // ═══════════════════════════════════════════════════════════════════════

    function _evaluateCompliance(
        ProtocolTypes.TransferIntent memory intent
    ) internal returns (bool) {
        try _compliancePolicyProvider.evaluateTransferIntent(intent) returns (
            ProtocolTypes.ComplianceDecision memory decision
        ) {
            return decision.result == ProtocolTypes.ComplianceResult.APPROVED;
        } catch {
            return false;
        }
    }

    function _reserveAssets(
        ProtocolTypes.TransferIntent memory intent
    ) internal returns (bool) {
        try _assetAdapter.reserveAssets(intent) returns (bool reserved) {
            return reserved;
        } catch {
            return false;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Transport
    // ═══════════════════════════════════════════════════════════════════════

    function _sendValidationResponse(
        bytes32 intentId,
        ChainId destinationChain,
        ProtocolTypes.ComplianceResult result
    ) internal {
        bytes memory payload = abi.encode(result);

        ProtocolTypes.TransferIntent memory intent = _transferIntentManager.getTransferIntent(intentId);

        _sendMessage(
            destinationChain,
            ProtocolTypes.MessageType.VALIDATION_RESPONSE,
            ProtocolTypes.SettlementPhase.VALIDATION_RESPONSE,
            intentId,
            payload,
            intent.expiresAt
        );

        emit ValidationResponseSent(intentId, result, destinationChain);
    }

    function _sendMessage(
        ChainId destinationChain,
        ProtocolTypes.MessageType messageType,
        ProtocolTypes.SettlementPhase phase,
        bytes32 intentId,
        bytes memory payload,
        uint64 expiresAt
    ) internal {
        ProtocolTypes.TransportMessage memory message = ProtocolTypes.TransportMessage({
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

        try _transportProvider.sendMessage(destinationChain, message) returns (bytes32) { } catch {
            revert SettlementCoordinator__TransportFailed(intentId, destinationChain);
        }
    }
}
