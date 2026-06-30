// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IProtocolAccessManager} from "../access/IProtocolAccessManager.sol";
import {ITransferIntentManager} from "../interfaces/ITransferIntentManager.sol";
import {ProtocolTypes} from "../common/ProtocolTypes.sol";

/// @title Transfer Intent Manager
/// @notice Authoritative state manager for all TransferIntent records.
contract TransferIntentManager is ITransferIntentManager, ERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // Errors
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Migrate to ProtocolErrors.sol once that shared library exists.

    error TransferIntentManager__ZeroIntentId();
    error TransferIntentManager__IntentAlreadyExists(bytes32 intentId);
    error TransferIntentManager__IntentNotFound(bytes32 intentId);
    error TransferIntentManager__InvalidStateTransition(
        ProtocolTypes.SettlementState current,
        ProtocolTypes.SettlementState next
    );
    error TransferIntentManager__IntentExpired(bytes32 intentId);
    error TransferIntentManager__IntentNotExpired(bytes32 intentId);
    error TransferIntentManager__InvalidTimestamp();
    error TransferIntentManager__ZeroAccessManager();
    error TransferIntentManager__ZeroSender();
    error TransferIntentManager__ZeroRecipient();
    error TransferIntentManager__ZeroAmount();
    error TransferIntentManager__ZeroAssetId();
    error TransferIntentManager__Unauthorized(address caller, bytes32 role);

    // ═══════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Migrate to ProtocolEvents.sol once that shared library exists.

    event IntentCreated(
        bytes32 indexed intentId,
        address indexed sender,
        address indexed recipient,
        ProtocolTypes.IntentAction action,
        uint64 createdAt,
        uint64 expiresAt
    );

    event IntentStateTransitioned(
        bytes32 indexed intentId,
        ProtocolTypes.SettlementState from,
        ProtocolTypes.SettlementState to
    );

    event IntentCancelled(bytes32 indexed intentId);

    event IntentExpired(bytes32 indexed intentId);

    // ═══════════════════════════════════════════════════════════════════════
    // Storage
    // ═══════════════════════════════════════════════════════════════════════

    IProtocolAccessManager private immutable _accessManager;

    mapping(bytes32 => ProtocolTypes.TransferRecord) private _records;

    // ═══════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════

    constructor(IProtocolAccessManager accessManager_) {
        if (address(accessManager_) == address(0)) {
            revert TransferIntentManager__ZeroAccessManager();
        }
        _accessManager = accessManager_;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ERC-165
    // ═══════════════════════════════════════════════════════════════════════

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(ITransferIntentManager).interfaceId || super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Modifiers
    // ═══════════════════════════════════════════════════════════════════════

    modifier onlyRole(bytes32 role) {
        if (!_accessManager.hasRole(role, msg.sender)) {
            revert TransferIntentManager__Unauthorized(msg.sender, role);
        }
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Creation
    // ═══════════════════════════════════════════════════════════════════════

    function createTransferIntent(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bytes32 intentId) {
        if (intent.intentId == bytes32(0)) {
            revert TransferIntentManager__ZeroIntentId();
        }
        if (_records[intent.intentId].createdAt != 0) {
            revert TransferIntentManager__IntentAlreadyExists(intent.intentId);
        }
        if (intent.sender == address(0)) {
            revert TransferIntentManager__ZeroSender();
        }
        if (intent.recipient == address(0)) {
            revert TransferIntentManager__ZeroRecipient();
        }
        if (intent.amount == 0) {
            revert TransferIntentManager__ZeroAmount();
        }
        if (intent.assetId == bytes32(0)) {
            revert TransferIntentManager__ZeroAssetId();
        }
        if (intent.expiresAt == 0) {
            revert TransferIntentManager__InvalidTimestamp();
        }
        if (intent.expiresAt <= block.timestamp) {
            revert TransferIntentManager__IntentExpired(intent.intentId);
        }

        uint64 timestamp = uint64(block.timestamp);

        ProtocolTypes.TransferRecord storage record = _records[intent.intentId];
        record.intent = intent;
        record.state = ProtocolTypes.SettlementState.PENDING_VALIDATION;
        record.createdAt = timestamp;
        record.updatedAt = timestamp;
        record.pendingRecovery = ProtocolTypes.RecoveryAction.NONE;

        emit IntentCreated(
            intent.intentId,
            intent.sender,
            intent.recipient,
            intent.action,
            timestamp,
            intent.expiresAt
        );

        return intent.intentId;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Retrieval
    // ═══════════════════════════════════════════════════════════════════════

    function getTransferIntent(bytes32 intentId) external view returns (ProtocolTypes.TransferIntent memory intent) {
        if (_records[intentId].createdAt == 0) {
            revert TransferIntentManager__IntentNotFound(intentId);
        }
        return _records[intentId].intent;
    }

    function getTransferRecord(bytes32 intentId) external view returns (ProtocolTypes.TransferRecord memory record) {
        if (_records[intentId].createdAt == 0) {
            revert TransferIntentManager__IntentNotFound(intentId);
        }
        return _records[intentId];
    }

    function exists(bytes32 intentId) external view returns (bool) {
        return _records[intentId].createdAt != 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // State Queries
    // ═══════════════════════════════════════════════════════════════════════

    function getSettlementState(bytes32 intentId) external view returns (ProtocolTypes.SettlementState state) {
        if (_records[intentId].createdAt == 0) {
            revert TransferIntentManager__IntentNotFound(intentId);
        }
        return _records[intentId].state;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // State Transitions
    // ═══════════════════════════════════════════════════════════════════════

    function transitionState(
        bytes32 intentId,
        ProtocolTypes.SettlementState newState
    ) external onlyRole(_accessManager.BRIDGE_ROLE()) {
        _transitionState(intentId, newState);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Semantic State Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function cancelTransferIntent(
        bytes32 intentId
    ) external onlyRole(_accessManager.COMPLIANCE_ROLE()) {
        _transitionState(intentId, ProtocolTypes.SettlementState.REJECTED);
        emit IntentCancelled(intentId);
    }

    function expireTransferIntent(
        bytes32 intentId
    ) external onlyRole(_accessManager.BRIDGE_ROLE()) {
        if (_records[intentId].createdAt == 0) {
            revert TransferIntentManager__IntentNotFound(intentId);
        }
        if (block.timestamp < _records[intentId].intent.expiresAt) {
            revert TransferIntentManager__IntentNotExpired(intentId);
        }
        _transitionState(intentId, ProtocolTypes.SettlementState.EXPIRED);
        emit IntentExpired(intentId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal
    // ═══════════════════════════════════════════════════════════════════════

    function _transitionState(bytes32 intentId, ProtocolTypes.SettlementState newState) private {
        ProtocolTypes.TransferRecord storage record = _records[intentId];
        if (record.createdAt == 0) {
            revert TransferIntentManager__IntentNotFound(intentId);
        }

        ProtocolTypes.SettlementState oldState = record.state;
        _validateTransition(oldState, newState);

        record.state = newState;
        record.updatedAt = uint64(block.timestamp);

        emit IntentStateTransitioned(intentId, oldState, newState);
    }

    function _validateTransition(
        ProtocolTypes.SettlementState current,
        ProtocolTypes.SettlementState next
    ) private pure {
        if (current == ProtocolTypes.SettlementState.SETTLED) {
            revert TransferIntentManager__InvalidStateTransition(current, next);
        }
        if (current == ProtocolTypes.SettlementState.REJECTED) {
            revert TransferIntentManager__InvalidStateTransition(current, next);
        }
        if (current == ProtocolTypes.SettlementState.EXPIRED) {
            revert TransferIntentManager__InvalidStateTransition(current, next);
        }
        if (current == ProtocolTypes.SettlementState.ROLLED_BACK) {
            revert TransferIntentManager__InvalidStateTransition(current, next);
        }

        if (current == ProtocolTypes.SettlementState.PENDING_VALIDATION) {
            if (
                next == ProtocolTypes.SettlementState.VALIDATED
                    || next == ProtocolTypes.SettlementState.REJECTED
                    || next == ProtocolTypes.SettlementState.EXPIRED
            ) {
                return;
            }
            revert TransferIntentManager__InvalidStateTransition(current, next);
        }

        if (current == ProtocolTypes.SettlementState.VALIDATED) {
            if (
                next == ProtocolTypes.SettlementState.SETTLING
                    || next == ProtocolTypes.SettlementState.EXPIRED
                    || next == ProtocolTypes.SettlementState.REJECTED
            ) {
                return;
            }
            revert TransferIntentManager__InvalidStateTransition(current, next);
        }

        if (current == ProtocolTypes.SettlementState.SETTLING) {
            if (
                next == ProtocolTypes.SettlementState.SETTLED
                    || next == ProtocolTypes.SettlementState.ROLLED_BACK
            ) {
                return;
            }
            revert TransferIntentManager__InvalidStateTransition(current, next);
        }

        revert TransferIntentManager__InvalidStateTransition(current, next);
    }
}
