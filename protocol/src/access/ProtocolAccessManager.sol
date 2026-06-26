// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IProtocolAccessManager} from "./IProtocolAccessManager.sol";

/// @title Protocol Access Manager
/// @notice Central registry of protocol-wide roles for the Institutional RWA Platform.
/// @dev This contract only defines and administers roles. It intentionally contains no token,
/// compliance, bridge, pause, upgrade, partition, document, or business workflow logic.
contract ProtocolAccessManager is IProtocolAccessManager, AccessControl {
    /// @notice Reverts when the initial admin is the zero address.
    error ProtocolAccessManagerInvalidAdmin();

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override ISSUER_ROLE = keccak256("ISSUER_ROLE");

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override AGENT_ROLE = keccak256("AGENT_ROLE");

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override IDENTITY_MANAGER_ROLE = keccak256("IDENTITY_MANAGER_ROLE");

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override DOCUMENT_MANAGER_ROLE = keccak256("DOCUMENT_MANAGER_ROLE");

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override PARTITION_MANAGER_ROLE = keccak256("PARTITION_MANAGER_ROLE");

    /// @inheritdoc IProtocolAccessManager
    bytes32 public constant override CORPORATE_ACTION_ROLE = keccak256("CORPORATE_ACTION_ROLE");

    /// @notice Deploys the access manager and grants the default admin role.
    /// @param admin Address that receives `DEFAULT_ADMIN_ROLE`.
    constructor(address admin) {
        if (admin == address(0)) {
            revert ProtocolAccessManagerInvalidAdmin();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Reports whether this contract implements an interface.
    /// @param interfaceId Interface identifier to check.
    /// @return supported True if the interface is supported.
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool supported) {
        return interfaceId == type(IProtocolAccessManager).interfaceId || super.supportsInterface(interfaceId);
    }
}
