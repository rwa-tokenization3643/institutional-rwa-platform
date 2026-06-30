// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title Protocol Access Manager Interface
/// @notice Defines protocol-wide role identifiers and the AccessControl API used by platform modules.
interface IProtocolAccessManager is IAccessControl {
    /// @notice Returns the role identifier for issuer-level operations.
    /// @return role The issuer role identifier.
    function ISSUER_ROLE() external pure returns (bytes32 role);

    /// @notice Returns the role identifier for delegated operational agents.
    /// @return role The agent role identifier.
    function AGENT_ROLE() external pure returns (bytes32 role);

    /// @notice Returns the role identifier for compliance administration.
    /// @return role The compliance role identifier.
    function COMPLIANCE_ROLE() external pure returns (bytes32 role);

    /// @notice Returns the role identifier for pause administration.
    /// @return role The pauser role identifier.
    function PAUSER_ROLE() external pure returns (bytes32 role);

    /// @notice Returns the role identifier for upgrade administration.
    /// @return role The upgrader role identifier.
    function UPGRADER_ROLE() external pure returns (bytes32 role);

    /// @notice Returns the role identifier for bridge administration.
    /// @return role The bridge role identifier.
    function BRIDGE_ROLE() external pure returns (bytes32 role);

    /// @notice Returns the role identifier for identity registry administration.
    /// @return role The identity manager role identifier.
    function IDENTITY_MANAGER_ROLE() external pure returns (bytes32 role);

    /// @notice Returns the role identifier for document registry administration.
    /// @return role The document manager role identifier.
    function DOCUMENT_MANAGER_ROLE() external pure returns (bytes32 role);

    /// @notice Returns the role identifier for partition administration.
    /// @return role The partition manager role identifier.
    function PARTITION_MANAGER_ROLE() external pure returns (bytes32 role);

    /// @notice Returns the role identifier for corporate action administration.
    /// @return role The corporate action role identifier.
    function CORPORATE_ACTION_ROLE() external pure returns (bytes32 role);
}
