# ProtocolAccessManager Specification

## Purpose

`ProtocolAccessManager` is the central role registry for protocol modules.

It defines protocol-wide role identifiers and uses OpenZeppelin `AccessControl` to manage which accounts hold those roles.

The module does not implement pausing, upgrade authorization, token behavior, compliance logic, bridge logic, partition logic, or any other business logic.

## Roles

- `DEFAULT_ADMIN_ROLE`: Admin role from OpenZeppelin `AccessControl`. This role administers all protocol roles.
- `ISSUER_ROLE`: Accounts allowed to perform issuer-level operations in modules that require issuer authority.
- `AGENT_ROLE`: Accounts allowed to perform delegated operational actions.
- `COMPLIANCE_ROLE`: Accounts allowed to manage compliance-related configuration in compliance modules.
- `PAUSER_ROLE`: Accounts allowed to use pause controls in modules that implement pausing.
- `UPGRADER_ROLE`: Accounts allowed to authorize upgrades in upgradeable modules.
- `BRIDGE_ROLE`: Accounts allowed to perform bridge-related operations in bridge modules.
- `IDENTITY_MANAGER_ROLE`: Accounts allowed to manage identity registry workflows.
- `DOCUMENT_MANAGER_ROLE`: Accounts allowed to manage document registry workflows.
- `PARTITION_MANAGER_ROLE`: Accounts allowed to manage partition workflows.
- `CORPORATE_ACTION_ROLE`: Accounts allowed to manage corporate action workflows.

All non-default roles are administered by `DEFAULT_ADMIN_ROLE`.

## Public API

- `constructor(address admin)`: Grants `DEFAULT_ADMIN_ROLE` to `admin`.
- `ISSUER_ROLE()`: Returns the issuer role identifier.
- `AGENT_ROLE()`: Returns the agent role identifier.
- `COMPLIANCE_ROLE()`: Returns the compliance role identifier.
- `PAUSER_ROLE()`: Returns the pauser role identifier.
- `UPGRADER_ROLE()`: Returns the upgrader role identifier.
- `BRIDGE_ROLE()`: Returns the bridge role identifier.
- `IDENTITY_MANAGER_ROLE()`: Returns the identity manager role identifier.
- `DOCUMENT_MANAGER_ROLE()`: Returns the document manager role identifier.
- `PARTITION_MANAGER_ROLE()`: Returns the partition manager role identifier.
- `CORPORATE_ACTION_ROLE()`: Returns the corporate action role identifier.
- `hasRole(bytes32 role, address account)`: Inherited from OpenZeppelin `AccessControl`.
- `getRoleAdmin(bytes32 role)`: Inherited from OpenZeppelin `AccessControl`.
- `grantRole(bytes32 role, address account)`: Inherited from OpenZeppelin `AccessControl`.
- `revokeRole(bytes32 role, address account)`: Inherited from OpenZeppelin `AccessControl`.
- `renounceRole(bytes32 role, address callerConfirmation)`: Inherited from OpenZeppelin `AccessControl`.
- `supportsInterface(bytes4 interfaceId)`: Inherited from OpenZeppelin `AccessControl`.

## Security Assumptions

- The admin address provided at deployment is trusted and secured.
- The admin address must not be the zero address.
- Holders of `DEFAULT_ADMIN_ROLE` can grant and revoke every protocol role.
- Module contracts must check the relevant role before allowing privileged actions.
- This module only manages roles; it does not enforce permissions for other modules unless those modules call it or inherit compatible role checks.

## Expected Behavior

- Deployment grants `DEFAULT_ADMIN_ROLE` to the configured admin.
- Deployment reverts if the configured admin is the zero address.
- No protocol role is granted by default except `DEFAULT_ADMIN_ROLE`.
- All protocol role constants are stable `bytes32` identifiers derived from their role names.
- Admin accounts can grant and revoke protocol roles using OpenZeppelin `AccessControl`.
- Non-admin accounts cannot grant or revoke protocol roles.
- Role holders can renounce their own roles using OpenZeppelin `AccessControl`.
