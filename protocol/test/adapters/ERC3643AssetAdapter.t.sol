// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProtocolAccessManager} from "../../contracts/access/ProtocolAccessManager.sol";
import {IProtocolAccessManager} from "../../contracts/access/IProtocolAccessManager.sol";
import {IAssetAdapter} from "../../contracts/interfaces/IAssetAdapter.sol";
import {ProtocolTypes, ChainId} from "../../contracts/common/ProtocolTypes.sol";
import {ERC3643AssetAdapter} from "../../contracts/adapters/ERC3643AssetAdapter.sol";

contract MockERC3643Token {
    mapping(address => uint256) private _balances;

    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }

    function burn(address account, uint256 amount) external {
        _balances[account] -= amount;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
}

contract ERC3643AssetAdapterTest is Test {
    ProtocolAccessManager private accessManager;
    ERC3643AssetAdapter private adapter;
    MockERC3643Token private token;

    address private admin = address(0xA11CE);
    address private bridge = address(0xB0B0B);
    address private compliance = address(0xCAFE);
    address private alice = address(0xAA);
    address private bob = address(0xBB);
    address private unauthorized = address(0xE4E);

    bytes32 private constant ASSET_ID = keccak256("TEST_ASSET");
    bytes32 private constant ASSET_TYPE = keccak256("EQUITY");
    bytes32 private constant VENDOR_VERSION = keccak256("T-REX:4.1.6");
    uint256 private constant AMOUNT = 100;

    ChainId private constant SOURCE_CHAIN = ChainId.wrap(1);
    ChainId private constant DEST_CHAIN = ChainId.wrap(2);

    function setUp() public {
        accessManager = new ProtocolAccessManager(admin);

        vm.startPrank(admin);
        accessManager.grantRole(accessManager.BRIDGE_ROLE(), bridge);
        accessManager.grantRole(accessManager.COMPLIANCE_ROLE(), compliance);
        vm.stopPrank();

        adapter = new ERC3643AssetAdapter(accessManager, SOURCE_CHAIN);

        token = new MockERC3643Token();
        token.mint(alice, 1000);

        vm.prank(compliance);
        adapter.configureAsset(
            ASSET_ID,
            address(token),
            18,               // decimals
            ASSET_TYPE,
            keccak256("BURN_MINT"),
            VENDOR_VERSION
        );
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_ConstructorRevertsWhenAccessManagerZeroAddress() public {
        vm.expectRevert(ERC3643AssetAdapter.ERC3643Adapter__ZeroAddress.selector);
        new ERC3643AssetAdapter(IProtocolAccessManager(address(0)), SOURCE_CHAIN);
    }

    // =========================================================================
    // configureAsset
    // =========================================================================

    function test_ConfigureAsset() public {
        bytes32 newId = keccak256("NEW_TOKEN");
        MockERC3643Token newToken = new MockERC3643Token();

        vm.prank(compliance);
        adapter.configureAsset(
            newId,
            address(newToken),
            18,
            keccak256("BOND"),
            keccak256("BURN_MINT"),
            VENDOR_VERSION
        );

        assertTrue(adapter.assetExists(newId));
        assertEq(adapter.assetId(address(newToken)), newId);
    }

    function test_ConfigureAssetRevertsWhenAssetIdZero() public {
        vm.prank(compliance);
        vm.expectRevert(ERC3643AssetAdapter.ERC3643Adapter__ZeroAssetId.selector);
        adapter.configureAsset(
            bytes32(0),
            address(token),
            18,
            ASSET_TYPE,
            keccak256("BURN_MINT"),
            VENDOR_VERSION
        );
    }

    function test_ConfigureAssetRevertsWhenTokenZero() public {
        vm.prank(compliance);
        vm.expectRevert(ERC3643AssetAdapter.ERC3643Adapter__ZeroAddress.selector);
        adapter.configureAsset(
            keccak256("any"),
            address(0),
            18,
            ASSET_TYPE,
            keccak256("BURN_MINT"),
            VENDOR_VERSION
        );
    }

    function test_ConfigureAssetRevertsWhenAlreadyRegistered() public {
        vm.prank(compliance);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__AssetAlreadyRegistered.selector,
                ASSET_ID,
                SOURCE_CHAIN
            )
        );
        adapter.configureAsset(
            ASSET_ID,
            address(token),
            18,
            ASSET_TYPE,
            keccak256("BURN_MINT"),
            VENDOR_VERSION
        );
    }

    function test_ConfigureAssetRevertsWhenNotComplianceRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__Unauthorized.selector,
                unauthorized,
                accessManager.COMPLIANCE_ROLE()
            )
        );
        vm.prank(unauthorized);
        adapter.configureAsset(
            keccak256("x"),
            address(1),
            18,
            ASSET_TYPE,
            keccak256("BURN_MINT"),
            VENDOR_VERSION
        );
    }

    // =========================================================================
    // getAssetConfig
    // =========================================================================

    function test_GetAssetConfigReturnsConfig() public {
        ERC3643AssetAdapter.AssetConfig memory cfg = adapter.getAssetConfig(ASSET_ID);
        assertEq(cfg.token, address(token));
        assertEq(cfg.settlementModel, keccak256("BURN_MINT"));
    }

    function test_GetAssetConfigRevertsWhenNotConfigured() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__AssetNotFound.selector,
                keccak256("UNREGISTERED"),
                SOURCE_CHAIN
            )
        );
        adapter.getAssetConfig(keccak256("UNREGISTERED"));
    }

    // =========================================================================
    // supportsInterface
    // =========================================================================

    function test_SupportsIAssetAdapter() public view {
        assertTrue(adapter.supportsInterface(type(IAssetAdapter).interfaceId));
    }

    function test_SupportsERC165() public view {
        assertTrue(adapter.supportsInterface(type(IERC165).interfaceId));
    }

    function test_DoesNotSupportUnknownInterface() public view {
        assertFalse(adapter.supportsInterface(bytes4(0xFFFFFFFF)));
    }

    // =========================================================================
    // assetExists
    // =========================================================================

    function test_AssetExistsReturnsTrueWhenConfigured() public view {
        assertTrue(adapter.assetExists(ASSET_ID));
    }

    function test_AssetExistsReturnsFalseWhenNotConfigured() public view {
        assertFalse(adapter.assetExists(keccak256("UNREGISTERED")));
    }

    // =========================================================================
    // supportsPartition
    // =========================================================================

    function test_SupportsPartitionReturnsTrueForDefault() public view {
        assertTrue(adapter.supportsPartition(ASSET_ID, bytes32(0)));
    }

    function test_SupportsPartitionReturnsFalseForNonDefault() public view {
        assertFalse(adapter.supportsPartition(ASSET_ID, keccak256("CUSTOM_PARTITION")));
    }

    // =========================================================================
    // reserveAssets
    // =========================================================================

    function _intent(bytes32 intentId) internal view returns (ProtocolTypes.TransferIntent memory) {
        return ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: alice,
            recipient: bob,
            senderIdentityHash: bytes32(0),
            recipientIdentityHash: bytes32(0),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: SOURCE_CHAIN,
            destinationChainId: DEST_CHAIN,
            amount: AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: 1,
            expiresAt: 0
        });
    }

    function _customIntent(
        bytes32 intentId,
        address sender,
        uint256 amount,
        bytes32 assetId
    ) internal view returns (ProtocolTypes.TransferIntent memory) {
        return ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: sender,
            recipient: bob,
            senderIdentityHash: bytes32(0),
            recipientIdentityHash: bytes32(0),
            assetId: assetId,
            partitionId: bytes32(0),
            sourceChainId: SOURCE_CHAIN,
            destinationChainId: DEST_CHAIN,
            amount: amount,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: 1,
            expiresAt: 0
        });
    }

    function test_ReserveAssets() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("reserve-basic"));

        vm.prank(bridge);
        bool reserved = adapter.reserveAssets(i);

        assertTrue(reserved);
        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), AMOUNT);
        assertEq(adapter.balanceOf(ASSET_ID, alice, bytes32(0)), 1000);
        assertEq(adapter.availableBalance(ASSET_ID, alice, bytes32(0)), 900);
    }

    function test_ReserveAssetsIdempotent() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("reserve-idempotent"));

        vm.startPrank(bridge);
        assertTrue(adapter.reserveAssets(i));
        assertTrue(adapter.reserveAssets(i));
        vm.stopPrank();

        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), AMOUNT);
    }

    function test_ReserveAssetsReturnsFalseWhenInsufficientBalance() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("reserve-insufficient"));
        i.amount = 100_000;

        vm.prank(bridge);
        bool reserved = adapter.reserveAssets(i);

        assertFalse(reserved);
        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), 0);
    }

    function test_ReserveAssetsRevertsWhenAssetNotConfigured() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("reserve-unregistered"));
        i.assetId = keccak256("UNREGISTERED");

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__AssetNotFound.selector,
                i.assetId,
                SOURCE_CHAIN
            )
        );
        adapter.reserveAssets(i);
    }

    function test_ReserveAssetsRevertsWhenNotBridgeRole() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("reserve-unauth"));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__Unauthorized.selector,
                unauthorized,
                accessManager.BRIDGE_ROLE()
            )
        );
        vm.prank(unauthorized);
        adapter.reserveAssets(i);
    }

    // =========================================================================
    // releaseReservation
    // =========================================================================

    function test_ReleaseReservation() public {
        bytes32 id = keccak256("release-basic");
        ProtocolTypes.TransferIntent memory i = _intent(id);

        vm.prank(bridge);
        adapter.reserveAssets(i);

        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), AMOUNT);

        vm.prank(bridge);
        bool released = adapter.releaseReservation(i);

        assertTrue(released);
        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), 0);
        assertEq(adapter.balanceOf(ASSET_ID, alice, bytes32(0)), 1000);
        assertEq(adapter.availableBalance(ASSET_ID, alice, bytes32(0)), 1000);
    }

    function test_ReleaseReservationReturnsFalseWhenNoReservation() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("release-nonexistent"));

        vm.prank(bridge);
        bool released = adapter.releaseReservation(i);

        assertFalse(released);
    }

    function test_ReleaseReservationIdempotent() public {
        bytes32 id = keccak256("release-idempotent");
        ProtocolTypes.TransferIntent memory i = _intent(id);

        vm.startPrank(bridge);
        adapter.reserveAssets(i);
        adapter.releaseReservation(i);
        bool released = adapter.releaseReservation(i);
        vm.stopPrank();

        assertFalse(released);
    }

    function test_ReleaseReservationRevertsWhenNotBridgeRole() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("release-unauth"));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__Unauthorized.selector,
                unauthorized,
                accessManager.BRIDGE_ROLE()
            )
        );
        vm.prank(unauthorized);
        adapter.releaseReservation(i);
    }

    // =========================================================================
    // burnReservedAssets
    // =========================================================================

    function test_BurnReservedAssets() public {
        bytes32 id = keccak256("burn-basic");
        ProtocolTypes.TransferIntent memory i = _intent(id);

        vm.startPrank(bridge);
        adapter.reserveAssets(i);
        adapter.burnReservedAssets(i);
        vm.stopPrank();

        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), 0);
        assertEq(adapter.balanceOf(ASSET_ID, alice, bytes32(0)), 900);
        assertEq(token.balanceOf(alice), 900);
    }

    function test_BurnReservedAssetsRevertsWhenReservationNotFound() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("burn-notfound"));

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3643AssetAdapter.ERC3643Adapter__ReservationNotFound.selector, i.intentId)
        );
        adapter.burnReservedAssets(i);
    }

    function test_BurnReservedAssetsRevertsWhenSenderMismatch() public {
        bytes32 id = keccak256("burn-sender-mismatch");
        ProtocolTypes.TransferIntent memory i = _intent(id);

        vm.prank(bridge);
        adapter.reserveAssets(i);

        ProtocolTypes.TransferIntent memory wrong = _customIntent(id, bob, AMOUNT, ASSET_ID);

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3643AssetAdapter.ERC3643Adapter__ReservationMismatch.selector, id)
        );
        adapter.burnReservedAssets(wrong);
    }

    function test_BurnReservedAssetsRevertsWhenAmountMismatch() public {
        bytes32 id = keccak256("burn-amount-mismatch");
        ProtocolTypes.TransferIntent memory i = _intent(id);

        vm.prank(bridge);
        adapter.reserveAssets(i);

        ProtocolTypes.TransferIntent memory wrong = _customIntent(id, alice, AMOUNT + 1, ASSET_ID);

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3643AssetAdapter.ERC3643Adapter__ReservationMismatch.selector, id)
        );
        adapter.burnReservedAssets(wrong);
    }

    function test_BurnReservedAssetsRevertsWhenAssetIdMismatch() public {
        bytes32 id = keccak256("burn-asset-mismatch");
        ProtocolTypes.TransferIntent memory i = _intent(id);

        vm.prank(bridge);
        adapter.reserveAssets(i);

        ProtocolTypes.TransferIntent memory wrong = _customIntent(id, alice, AMOUNT, keccak256("WRONG_ASSET"));

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(ERC3643AssetAdapter.ERC3643Adapter__ReservationMismatch.selector, id)
        );
        adapter.burnReservedAssets(wrong);
    }

    function test_BurnReservedAssetsRevertsWhenNotBridgeRole() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("burn-unauth"));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__Unauthorized.selector,
                unauthorized,
                accessManager.BRIDGE_ROLE()
            )
        );
        vm.prank(unauthorized);
        adapter.burnReservedAssets(i);
    }

    // =========================================================================
    // mintAssets
    // =========================================================================

    function test_MintAssets() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("mint-basic"));

        vm.prank(bridge);
        bool minted = adapter.mintAssets(i);

        assertTrue(minted);
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    function test_MintAssetsRevertsWhenAssetNotConfigured() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("mint-unregistered"));
        i.assetId = keccak256("UNREGISTERED");

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__AssetNotFound.selector,
                i.assetId,
                SOURCE_CHAIN
            )
        );
        adapter.mintAssets(i);
    }

    function test_MintAssetsRevertsWhenNotBridgeRole() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("mint-unauth"));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__Unauthorized.selector,
                unauthorized,
                accessManager.BRIDGE_ROLE()
            )
        );
        vm.prank(unauthorized);
        adapter.mintAssets(i);
    }

    // =========================================================================
    // rollbackReservation
    // =========================================================================

    function test_RollbackReservation() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("rollback-basic"));

        vm.prank(bridge);
        bool rolled = adapter.rollbackReservation(i);

        assertTrue(rolled);
        assertEq(token.balanceOf(alice), 1000 + AMOUNT);
    }

    function test_RollbackReservationRevertsWhenAssetNotConfigured() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("rollback-unregistered"));
        i.assetId = keccak256("UNREGISTERED");

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__AssetNotFound.selector,
                i.assetId,
                SOURCE_CHAIN
            )
        );
        adapter.rollbackReservation(i);
    }

    function test_RollbackReservationRevertsWhenNotBridgeRole() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("rollback-unauth"));

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__Unauthorized.selector,
                unauthorized,
                accessManager.BRIDGE_ROLE()
            )
        );
        vm.prank(unauthorized);
        adapter.rollbackReservation(i);
    }

    // =========================================================================
    // Queries — balanceOf, reservedBalance, availableBalance
    // =========================================================================

    function test_BalanceOf() public {
        assertEq(adapter.balanceOf(ASSET_ID, alice, bytes32(0)), 1000);
    }

    function test_BalanceOfReturnsZeroForNonDefaultPartition() public {
        assertEq(adapter.balanceOf(ASSET_ID, alice, keccak256("CUSTOM")), 0);
    }

    function test_BalanceOfRevertsWhenAssetNotConfigured() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__AssetNotFound.selector,
                keccak256("UNREGISTERED"),
                SOURCE_CHAIN
            )
        );
        adapter.balanceOf(keccak256("UNREGISTERED"), alice, bytes32(0));
    }

    function test_ReservedBalance() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("reserved-balance"));

        vm.prank(bridge);
        adapter.reserveAssets(i);

        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), AMOUNT);
        assertEq(adapter.reservedBalance(ASSET_ID, bob, bytes32(0)), 0);
    }

    function test_ReservedBalanceReturnsZeroForNonDefaultPartition() public {
        assertEq(adapter.reservedBalance(ASSET_ID, alice, keccak256("CUSTOM")), 0);
    }

    function test_ReservedBalanceReturnsZeroForUnregisteredAsset() public {
        assertEq(adapter.reservedBalance(keccak256("UNREGISTERED"), alice, bytes32(0)), 0);
    }

    function test_AvailableBalance() public {
        ProtocolTypes.TransferIntent memory i = _intent(keccak256("available-balance"));

        vm.prank(bridge);
        adapter.reserveAssets(i);

        assertEq(adapter.availableBalance(ASSET_ID, alice, bytes32(0)), 900);
        assertEq(adapter.availableBalance(ASSET_ID, bob, bytes32(0)), 0);
    }

    function test_AvailableBalanceReturnsZeroForNonDefaultPartition() public {
        assertEq(adapter.availableBalance(ASSET_ID, alice, keccak256("CUSTOM")), 0);
    }

    function test_AvailableBalanceRevertsWhenAssetNotConfigured() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__AssetNotFound.selector,
                keccak256("UNREGISTERED"),
                SOURCE_CHAIN
            )
        );
        adapter.availableBalance(keccak256("UNREGISTERED"), alice, bytes32(0));
    }

    // =========================================================================
    // Metadata
    // =========================================================================

    function test_AssetId() public {
        assertEq(adapter.assetId(address(token)), ASSET_ID);
    }

    function test_AssetIdReturnsZeroForUnknownToken() public {
        assertEq(adapter.assetId(address(1)), bytes32(0));
    }

    function test_AssetVersion() public {
        assertEq(adapter.assetVersion(), keccak256("ERC3643AssetAdapter:1.0.0"));
    }

    function test_AdapterId() public {
        assertEq(adapter.adapterId(), keccak256("ERC3643AssetAdapter"));
    }

    // =========================================================================
    // Non-Interface Metadata (getAssetConfig, adapterChain, vendorVersion,
    // assetType, settlementModel, identityRegistry, compliance, decimals)
    // =========================================================================

    function test_AdapterChainReturnsConfiguredChain() public {
        assertEq(ChainId.unwrap(adapter.adapterChain()), ChainId.unwrap(SOURCE_CHAIN));
    }

    function test_VendorVersion() public {
        assertEq(adapter.vendorVersion(ASSET_ID), VENDOR_VERSION);
    }

    function test_AssetType() public {
        assertEq(adapter.assetType(ASSET_ID), ASSET_TYPE);
    }

    function test_SettlementModel() public {
        assertEq(adapter.settlementModel(ASSET_ID), keccak256("BURN_MINT"));
    }

    function test_Decimals() public {
        assertEq(adapter.decimals(ASSET_ID), 18);
    }

    // =========================================================================
    // Integration — full lifecycle
    // =========================================================================

    function test_Integration_FullSettlementCycle() public {
        bytes32 id = keccak256("integration-full");
        ProtocolTypes.TransferIntent memory i = _intent(id);

        vm.startPrank(bridge);

        bool reserved = adapter.reserveAssets(i);
        assertTrue(reserved);
        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), AMOUNT);
        assertEq(adapter.balanceOf(ASSET_ID, alice, bytes32(0)), 1000);

        bool minted = adapter.mintAssets(i);
        assertTrue(minted);
        assertEq(token.balanceOf(bob), AMOUNT);

        adapter.burnReservedAssets(i);
        assertEq(token.balanceOf(alice), 900);

        vm.stopPrank();

        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), 0);
        assertEq(adapter.availableBalance(ASSET_ID, alice, bytes32(0)), 900);
    }

    function test_Integration_ReserveThenReleaseRollback() public {
        bytes32 id = keccak256("integration-rollback");
        ProtocolTypes.TransferIntent memory i = _intent(id);

        vm.startPrank(bridge);

        adapter.reserveAssets(i);
        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), AMOUNT);

        adapter.releaseReservation(i);

        vm.stopPrank();

        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), 0);
        assertEq(adapter.balanceOf(ASSET_ID, alice, bytes32(0)), 1000);
        assertEq(adapter.availableBalance(ASSET_ID, alice, bytes32(0)), 1000);
    }

    function test_Integration_MultipleConcurrentIntents() public {
        bytes32 id1 = keccak256("concurrent-1");
        bytes32 id2 = keccak256("concurrent-2");
        ProtocolTypes.TransferIntent memory i1 = _intent(id1);
        ProtocolTypes.TransferIntent memory i2 = _intent(id2);

        vm.startPrank(bridge);

        adapter.reserveAssets(i1);
        adapter.reserveAssets(i2);

        vm.stopPrank();

        assertEq(adapter.reservedBalance(ASSET_ID, alice, bytes32(0)), 2 * AMOUNT);
        assertEq(adapter.availableBalance(ASSET_ID, alice, bytes32(0)), 800);
    }
}
