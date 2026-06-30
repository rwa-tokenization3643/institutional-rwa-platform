// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Test} from "forge-std/Test.sol";
import {IProtocolAccessManager} from "../../contracts/access/IProtocolAccessManager.sol";
import {ProtocolAccessManager} from "../../contracts/access/ProtocolAccessManager.sol";

contract ProtocolAccessManagerTest is Test {
    ProtocolAccessManager private accessManager;

    address private admin = address(0xA11CE);
    address private operator = address(0xB0B);
    address private unauthorized = address(0xE4E);

    bytes32[] private protocolRoles;

    function setUp() public {
        accessManager = new ProtocolAccessManager(admin);

        protocolRoles.push(accessManager.ISSUER_ROLE());
        protocolRoles.push(accessManager.AGENT_ROLE());
        protocolRoles.push(accessManager.COMPLIANCE_ROLE());
        protocolRoles.push(accessManager.PAUSER_ROLE());
        protocolRoles.push(accessManager.UPGRADER_ROLE());
        protocolRoles.push(accessManager.BRIDGE_ROLE());
        protocolRoles.push(accessManager.IDENTITY_MANAGER_ROLE());
        protocolRoles.push(accessManager.DOCUMENT_MANAGER_ROLE());
        protocolRoles.push(accessManager.PARTITION_MANAGER_ROLE());
        protocolRoles.push(accessManager.CORPORATE_ACTION_ROLE());
    }

    function test_ConstructorGrantsDefaultAdminRole() public view {
        assertTrue(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_ConstructorDoesNotGrantDefaultAdminRoleToDeployer() public view {
        assertFalse(accessManager.hasRole(accessManager.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_ConstructorDoesNotGrantProtocolRolesByDefault() public view {
        for (uint256 i = 0; i < protocolRoles.length; ++i) {
            assertFalse(accessManager.hasRole(protocolRoles[i], admin));
        }
    }

    function test_ConstructorRevertsWhenAdminIsZeroAddress() public {
        vm.expectRevert(ProtocolAccessManager.ProtocolAccessManagerInvalidAdmin.selector);
        new ProtocolAccessManager(address(0));
    }

    function test_RoleConstantsMatchExpectedIdentifiers() public view {
        assertEq(accessManager.ISSUER_ROLE(), keccak256("ISSUER_ROLE"));
        assertEq(accessManager.AGENT_ROLE(), keccak256("AGENT_ROLE"));
        assertEq(accessManager.COMPLIANCE_ROLE(), keccak256("COMPLIANCE_ROLE"));
        assertEq(accessManager.PAUSER_ROLE(), keccak256("PAUSER_ROLE"));
        assertEq(accessManager.UPGRADER_ROLE(), keccak256("UPGRADER_ROLE"));
        assertEq(accessManager.BRIDGE_ROLE(), keccak256("BRIDGE_ROLE"));
        assertEq(accessManager.IDENTITY_MANAGER_ROLE(), keccak256("IDENTITY_MANAGER_ROLE"));
        assertEq(accessManager.DOCUMENT_MANAGER_ROLE(), keccak256("DOCUMENT_MANAGER_ROLE"));
        assertEq(accessManager.PARTITION_MANAGER_ROLE(), keccak256("PARTITION_MANAGER_ROLE"));
        assertEq(accessManager.CORPORATE_ACTION_ROLE(), keccak256("CORPORATE_ACTION_ROLE"));
    }

    function test_AllProtocolRolesUseDefaultAdminRole() public view {
        for (uint256 i = 0; i < protocolRoles.length; ++i) {
            assertEq(accessManager.getRoleAdmin(protocolRoles[i]), accessManager.DEFAULT_ADMIN_ROLE());
        }
    }

    function test_AdminCanGrantProtocolRole() public {
        bytes32 role = accessManager.COMPLIANCE_ROLE();

        vm.prank(admin);
        accessManager.grantRole(role, operator);

        assertTrue(accessManager.hasRole(role, operator));
    }

    function test_AdminCanRevokeProtocolRole() public {
        bytes32 role = accessManager.BRIDGE_ROLE();

        vm.startPrank(admin);
        accessManager.grantRole(role, operator);
        accessManager.revokeRole(role, operator);
        vm.stopPrank();

        assertFalse(accessManager.hasRole(role, operator));
    }

    function test_AdminCanGrantEveryProtocolRole() public {
        vm.startPrank(admin);

        for (uint256 i = 0; i < protocolRoles.length; ++i) {
            accessManager.grantRole(protocolRoles[i], operator);
            assertTrue(accessManager.hasRole(protocolRoles[i], operator));
        }

        vm.stopPrank();
    }

    function test_AdminCanRevokeEveryProtocolRole() public {
        vm.startPrank(admin);

        for (uint256 i = 0; i < protocolRoles.length; ++i) {
            accessManager.grantRole(protocolRoles[i], operator);
            accessManager.revokeRole(protocolRoles[i], operator);
            assertFalse(accessManager.hasRole(protocolRoles[i], operator));
        }

        vm.stopPrank();
    }

    function test_NonAdminCannotGrantProtocolRole() public {
        bytes32 role = accessManager.ISSUER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                accessManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        accessManager.grantRole(role, operator);
    }

    function test_NonAdminCannotRevokeProtocolRole() public {
        bytes32 role = accessManager.AGENT_ROLE();

        vm.prank(admin);
        accessManager.grantRole(role, operator);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                accessManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        accessManager.revokeRole(role, operator);
    }

    function test_RoleHolderCanRenounceOwnRole() public {
        bytes32 role = accessManager.PAUSER_ROLE();

        vm.prank(admin);
        accessManager.grantRole(role, operator);

        vm.prank(operator);
        accessManager.renounceRole(role, operator);

        assertFalse(accessManager.hasRole(role, operator));
    }

    function test_RenounceRoleRequiresCallerConfirmation() public {
        bytes32 role = accessManager.UPGRADER_ROLE();

        vm.prank(admin);
        accessManager.grantRole(role, operator);

        vm.prank(operator);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        accessManager.renounceRole(role, unauthorized);
    }

    function test_SupportsProtocolAccessManagerInterface() public view {
        assertTrue(accessManager.supportsInterface(type(IProtocolAccessManager).interfaceId));
    }

    function test_SupportsAccessControlInterface() public view {
        assertTrue(accessManager.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_SupportsERC165Interface() public view {
        assertTrue(accessManager.supportsInterface(type(IERC165).interfaceId));
    }

    function test_DoesNotSupportUnknownInterface() public view {
        assertFalse(accessManager.supportsInterface(bytes4(0xFFFFFFFF)));
    }
}
