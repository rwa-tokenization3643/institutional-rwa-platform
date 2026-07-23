// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {ProtocolAccessManager} from "../../contracts/access/ProtocolAccessManager.sol";
import {IProtocolAccessManager} from "../../contracts/access/IProtocolAccessManager.sol";
import {ChainId, ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {TransferIntentManager} from "../../contracts/core/TransferIntentManager.sol";
import {ITransferIntentManager} from "../../contracts/interfaces/ITransferIntentManager.sol";
import {RuleEngineComplianceProvider} from "../../contracts/compliance/RuleEngineComplianceProvider.sol";
import {ERC3643AssetAdapter} from "../../contracts/adapters/ERC3643AssetAdapter.sol";
import {IAssetAdapter} from "../../contracts/interfaces/IAssetAdapter.sol";
import {ICompliancePolicyProvider} from "../../contracts/interfaces/ICompliancePolicyProvider.sol";
import {ITransportProvider} from "../../contracts/interfaces/ITransportProvider.sol";
import {SettlementCoordinator} from "../../contracts/core/SettlementCoordinator.sol";
import {ISettlementCoordinator} from "../../contracts/interfaces/ISettlementCoordinator.sol";
import {CCIPTransportProvider, ICcipRouterClient, Any2EVMMessage, ICcipReceiver} from "../../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {MockCCIPRouter} from "../mocks/MockCCIPRouter.sol";
import {IERC3643TokenMinimal} from "../mocks/IERC3643TokenMinimal.sol";
import {MockERC3643Token} from "../mocks/MockERC3643Token.sol";

// =============================================================================
// CrossChainSettlement.t.sol - Smoke test for cross-chain settlement
// =============================================================================
//
// Tests the full 6-phase cross-chain settlement flow using MockCCRouters.
// This verifies that the CCIPTransportProvider correctly:
//   - Encodes messages in real CCIP-compatible format
//   - Decodes inbound messages
//   - Authenticates senders via allowlist
//   - Handles replay protection
//   - Delivers to SettlementCoordinator
//
// =============================================================================

contract CrossChainSettlementTest is Test {

    // ── Constants ──
    ChainId internal constant SOURCE_CHAIN = ChainId.wrap(1);
    ChainId internal constant DEST_CHAIN   = ChainId.wrap(2);
    uint64 internal constant CCIP_SOURCE_SELECTOR = 16015286601757825753;
    uint64 internal constant CCIP_DEST_SELECTOR   = 14767482510784806047;

    bytes32 internal constant ASSET_ID      = keccak256("RWA_TOKEN");
    bytes32 internal constant ASSET_TYPE    = keccak256("BOND");
    bytes32 internal constant BURN_MINT     = keccak256("BURN_MINT");

    uint256 internal constant TOKEN_SUPPLY    = 10_000 ether;
    uint256 internal constant TRANSFER_AMOUNT = 1_000 ether;

    address internal constant ADMIN         = address(0xA11CE);
    address internal constant COMPLIANCE_OP = address(0xCAFE);
    address internal constant BRIDGE_OP     = address(0xB0B0B);
    address internal constant INVESTOR_A    = address(0xAAA);
    address internal constant INVESTOR_B    = address(0xBBB);

    // ── Source chain ──
    ProtocolAccessManager     srcAccessManager;
    TransferIntentManager     srcTIM;
    RuleEngineComplianceProvider srcCompliance;
    ERC3643AssetAdapter       srcAdapter;
    MockCCIPRouter            srcRouter;
    CCIPTransportProvider     srcTransport;
    SettlementCoordinator     srcSettlement;
    MockERC3643Token          srcToken;

    // ── Destination chain ──
    ProtocolAccessManager     dstAccessManager;
    TransferIntentManager     dstTIM;
    RuleEngineComplianceProvider dstCompliance;
    ERC3643AssetAdapter       dstAdapter;
    MockCCIPRouter            dstRouter;
    CCIPTransportProvider     dstTransport;
    SettlementCoordinator     dstSettlement;
    MockERC3643Token          dstToken;

    // ── Nonce tracking ──
    uint64 _nonce;

    // ═══════════════════════════════════════════════════════════════════════
    // Setup
    // ═══════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Deploy source chain stack
        (srcAccessManager, srcTIM, srcCompliance, srcAdapter, srcRouter, srcTransport, srcSettlement)
            = _deployProtocolStack(SOURCE_CHAIN);
        srcToken = new MockERC3643Token();
        srcToken.mint(INVESTOR_A, TOKEN_SUPPLY);

        // Deploy destination chain stack
        (dstAccessManager, dstTIM, dstCompliance, dstAdapter, dstRouter, dstTransport, dstSettlement)
            = _deployProtocolStack(DEST_CHAIN);
        dstToken = new MockERC3643Token();

        // Configure assets
        vm.prank(COMPLIANCE_OP);
        srcAdapter.configureAsset(ASSET_ID, address(srcToken), 18, ASSET_TYPE, BURN_MINT, keccak256("T-REX:4.1.3"));
        vm.prank(COMPLIANCE_OP);
        dstAdapter.configureAsset(ASSET_ID, address(dstToken), 18, ASSET_TYPE, BURN_MINT, keccak256("T-REX:4.1.3"));

        // Grant adapter agent roles (MockERC3643Token has no addAgent, so this is a no-op for mock)

        // Configure compliance
        _configureCompliance(srcCompliance);
        _configureCompliance(dstCompliance);

        // Configure cross-chain transport
        vm.prank(BRIDGE_OP);
        srcTransport.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        vm.prank(BRIDGE_OP);
        srcTransport.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        vm.prank(BRIDGE_OP);
        srcTransport.setAllowedSender(DEST_CHAIN, address(dstTransport), true);
        vm.prank(BRIDGE_OP);
        srcTransport.setRemoteReceiver(DEST_CHAIN, address(dstTransport));

        vm.prank(BRIDGE_OP);
        dstTransport.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        vm.prank(BRIDGE_OP);
        dstTransport.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        vm.prank(BRIDGE_OP);
        dstTransport.setAllowedSender(SOURCE_CHAIN, address(srcTransport), true);
        vm.prank(BRIDGE_OP);
        dstTransport.setRemoteReceiver(SOURCE_CHAIN, address(srcTransport));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: Full Cross-Chain Settlement
    // ═══════════════════════════════════════════════════════════════════════

    function test_crossChainSettlement_FullFlow() public {
        // -- Create TransferIntent --
        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(
            abi.encode(SOURCE_CHAIN, nonce, INVESTOR_A, INVESTOR_B, TRANSFER_AMOUNT)
        );

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: INVESTOR_A,
            recipient: INVESTOR_B,
            senderIdentityHash: keccak256(abi.encode(INVESTOR_A)),
            recipientIdentityHash: keccak256(abi.encode(INVESTOR_B)),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(DEST_CHAIN),
            amount: TRANSFER_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        // Record initial balances
        uint256 srcBalanceBefore = srcToken.balanceOf(INVESTOR_A);
        uint256 dstBalanceBefore = dstToken.balanceOf(INVESTOR_B);

        // -- Phase 1: Submit Transfer (Source) --
        vm.prank(INVESTOR_A);
        srcSettlement.submitTransfer(intent);
        assertEq(
            uint256(srcTIM.getSettlementState(intentId)),
            uint256(ProtocolTypes.SettlementState.PENDING_VALIDATION),
            "Source should be PENDING_VALIDATION"
        );

        // -- Phase 2: Send Validation Request via CCIP (Source -> Dest) --
        bytes32 valReqMsgId = keccak256("val_req");
        _deliverPhaseMessage(
            dstTransport, dstRouter,
            CCIP_SOURCE_SELECTOR, address(srcTransport), srcTransport,
            intentId, SOURCE_CHAIN, DEST_CHAIN, intent.expiresAt,
            valReqMsgId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
            abi.encode(intent)
        );
        assertEq(
            uint256(dstTIM.getSettlementState(intentId)),
            uint256(ProtocolTypes.SettlementState.VALIDATED),
            "Dest should be VALIDATED"
        );

        // -- Phase 3: Send Validation Response via CCIP (Dest -> Source) --
        bytes32 valResMsgId = keccak256("val_res");
        _deliverPhaseMessage(
            srcTransport, srcRouter,
            CCIP_DEST_SELECTOR, address(dstTransport), dstTransport,
            intentId, DEST_CHAIN, SOURCE_CHAIN, intent.expiresAt,
            valResMsgId,
            ProtocolTypes.MessageType.VALIDATION_RESPONSE,
            ProtocolTypes.SettlementPhase.VALIDATION_RESPONSE,
            abi.encode(ProtocolTypes.ComplianceResult.APPROVED)
        );
        assertEq(
            uint256(srcTIM.getSettlementState(intentId)),
            uint256(ProtocolTypes.SettlementState.RESERVED),
            "Source should be RESERVED"
        );

        uint256 reserved = srcAdapter.reservedBalance(ASSET_ID, INVESTOR_A, bytes32(0));
        assertEq(reserved, TRANSFER_AMOUNT, "Reserved amount should match");

        // -- Phase 4: Send Settlement Instruction via CCIP (Source -> Dest) --
        bytes32 instrMsgId = keccak256("settle_instr");
        _deliverPhaseMessage(
            dstTransport, dstRouter,
            CCIP_SOURCE_SELECTOR, address(srcTransport), srcTransport,
            intentId, SOURCE_CHAIN, DEST_CHAIN, intent.expiresAt,
            instrMsgId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION,
            bytes("")
        );
        assertEq(
            uint256(dstTIM.getSettlementState(intentId)),
            uint256(ProtocolTypes.SettlementState.SETTLED),
            "Dest should be SETTLED"
        );

        uint256 dstBalanceAfterMint = dstToken.balanceOf(INVESTOR_B);
        assertEq(dstBalanceAfterMint, dstBalanceBefore + TRANSFER_AMOUNT, "Dest balance should increase");

        // -- Phase 5: Send Settlement ACK via CCIP (Dest -> Source) --
        bytes32 ackMsgId = keccak256("settle_ack");
        _deliverPhaseMessage(
            srcTransport, srcRouter,
            CCIP_DEST_SELECTOR, address(dstTransport), dstTransport,
            intentId, DEST_CHAIN, SOURCE_CHAIN, intent.expiresAt,
            ackMsgId,
            ProtocolTypes.MessageType.SETTLEMENT_CONFIRMATION,
            ProtocolTypes.SettlementPhase.SETTLEMENT_ACK,
            bytes("")
        );
        assertEq(
            uint256(srcTIM.getSettlementState(intentId)),
            uint256(ProtocolTypes.SettlementState.SETTLED),
            "Source should be SETTLED"
        );

        // -- Phase 6: Final Verification --
        uint256 srcBalanceAfter = srcToken.balanceOf(INVESTOR_A);
        uint256 dstBalanceAfter = dstToken.balanceOf(INVESTOR_B);

        assertEq(srcBalanceAfter, srcBalanceBefore - TRANSFER_AMOUNT, "Source balance decreased");
        assertEq(dstBalanceAfter, dstBalanceBefore + TRANSFER_AMOUNT, "Dest balance increased");
        assertEq(srcBalanceAfter + dstBalanceAfter, TOKEN_SUPPLY, "Supply conserved");
        assertEq(srcAdapter.reservedBalance(ASSET_ID, INVESTOR_A, bytes32(0)), 0, "No residual reservation");
        assertEq(
            srcAdapter.availableBalance(ASSET_ID, INVESTOR_A, bytes32(0)),
            srcBalanceAfter,
            "Available balance matches token balance"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: Rejection via compliance
    // ═══════════════════════════════════════════════════════════════════════

    function test_crossChainSettlement_ComplianceRejection() public {
        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(
            abi.encode(SOURCE_CHAIN, nonce, INVESTOR_A, INVESTOR_B, TRANSFER_AMOUNT)
        );

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: INVESTOR_A,
            recipient: INVESTOR_B,
            senderIdentityHash: keccak256(abi.encode(INVESTOR_A)),
            recipientIdentityHash: keccak256(abi.encode(INVESTOR_B)),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(DEST_CHAIN),
            amount: TRANSFER_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        // Submit transfer
        vm.prank(INVESTOR_A);
        srcSettlement.submitTransfer(intent);

        // Deliver validation request
        _deliverPhaseMessage(
            dstTransport, dstRouter,
            CCIP_SOURCE_SELECTOR, address(srcTransport), srcTransport,
            intentId, SOURCE_CHAIN, DEST_CHAIN, intent.expiresAt,
            keccak256("val_req"),
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
            abi.encode(intent)
        );

        // Deliver validation response with REJECTION
        _deliverPhaseMessage(
            srcTransport, srcRouter,
            CCIP_DEST_SELECTOR, address(dstTransport), dstTransport,
            intentId, DEST_CHAIN, SOURCE_CHAIN, intent.expiresAt,
            keccak256("val_res"),
            ProtocolTypes.MessageType.VALIDATION_RESPONSE,
            ProtocolTypes.SettlementPhase.VALIDATION_RESPONSE,
            abi.encode(ProtocolTypes.ComplianceResult.DENIED)
        );

        assertEq(
            uint256(srcTIM.getSettlementState(intentId)),
            uint256(ProtocolTypes.SettlementState.REJECTED),
            "Source should be REJECTED"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: Replay Protection
    // ═══════════════════════════════════════════════════════════════════════

    function test_crossChainSettlement_ReplayProtection() public {
        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(
            abi.encode(SOURCE_CHAIN, nonce, INVESTOR_A, INVESTOR_B, TRANSFER_AMOUNT)
        );

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: INVESTOR_A,
            recipient: INVESTOR_B,
            senderIdentityHash: keccak256(abi.encode(INVESTOR_A)),
            recipientIdentityHash: keccak256(abi.encode(INVESTOR_B)),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(DEST_CHAIN),
            amount: TRANSFER_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        vm.prank(INVESTOR_A);
        srcSettlement.submitTransfer(intent);

        bytes32 msgId = keccak256("test_msg");

        // First delivery - should succeed
        _deliverPhaseMessage(
            dstTransport, dstRouter,
            CCIP_SOURCE_SELECTOR, address(srcTransport), srcTransport,
            intentId, SOURCE_CHAIN, DEST_CHAIN, intent.expiresAt,
            msgId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
            abi.encode(intent)
        );

        // Second delivery with same messageId - should revert
        ProtocolTypes.TransportMessage memory tm2 = ProtocolTypes.TransportMessage({
            messageVersion: 1,
            transportId: srcTransport.TRANSPORT_ID(),
            messageType: ProtocolTypes.MessageType.TRANSFER_INTENT,
            phase: ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
            messageId: bytes32(0),
            intentId: intentId,
            sourceChainId: ChainId.unwrap(SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(DEST_CHAIN),
            expiresAt: intent.expiresAt,
            sender: address(0),
            recipient: address(0),
            payloadHash: keccak256(abi.encode(intent)),
            payload: abi.encode(intent)
        });

        Any2EVMMessage memory ccipMsg2 = Any2EVMMessage({
            messageId: msgId,
            sourceChainSelector: CCIP_SOURCE_SELECTOR,
            sender: abi.encode(address(srcTransport)),
            data: abi.encode(tm2),
            destTokenAmounts: new ICcipRouterClient.EVMTokenAmount[](0)
        });

        vm.expectRevert();
        vm.prank(address(dstRouter));
        dstTransport.ccipReceive(ccipMsg2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: Unauthorized Sender
    // ═══════════════════════════════════════════════════════════════════════

    function test_crossChainSettlement_UnauthorizedSender() public {
        bytes32 msgId = keccak256("unauth_msg");

        Any2EVMMessage memory ccipMsg = Any2EVMMessage({
            messageId: msgId,
            sourceChainSelector: CCIP_SOURCE_SELECTOR,
            sender: abi.encode(address(0xDEAD)), // unauthorized sender
            data: abi.encode("dummy"),
            destTokenAmounts: new ICcipRouterClient.EVMTokenAmount[](0)
        });

        vm.prank(address(dstRouter));
        vm.expectRevert();
        dstTransport.ccipReceive(ccipMsg);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: CCIP Message Encoding Compatibility
    // ═══════════════════════════════════════════════════════════════════════

    function test_crossChainSettlement_CCIPMessageEncoding() public {
        // Verify that sendMessage produces a valid CCIP message
        // that the real router would accept (struct compatibility)

        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(
            abi.encode(SOURCE_CHAIN, nonce, INVESTOR_A, INVESTOR_B, TRANSFER_AMOUNT)
        );

        ProtocolTypes.TransportMessage memory tm = ProtocolTypes.TransportMessage({
            messageVersion: 1,
            transportId: keccak256("CCIP"),
            messageType: ProtocolTypes.MessageType.TRANSFER_INTENT,
            phase: ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
            messageId: bytes32(0),
            intentId: intentId,
            sourceChainId: ChainId.unwrap(SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(DEST_CHAIN),
            expiresAt: uint64(block.timestamp + 1 hours),
            sender: address(0),
            recipient: address(0),
            payloadHash: keccak256("test"),
            payload: abi.encode("test")
        });

        vm.prank(BRIDGE_OP);
        bytes32 messageId = srcTransport.sendMessage(DEST_CHAIN, tm);

        // Verify messageId was returned (MockCCIPRouter returns non-zero)
        assertTrue(messageId != bytes32(0), "CCIP messageId should be non-zero");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test: ERC165 supportsInterface
    // ═══════════════════════════════════════════════════════════════════════

    function test_crossChainSettlement_SupportsInterfaces() public {
        // Verify the transport provider supports required interfaces
        assertTrue(srcTransport.supportsInterface(type(ITransportProvider).interfaceId));
        assertTrue(srcTransport.supportsInterface(type(ICcipReceiver).interfaceId));
        assertTrue(srcTransport.supportsInterface(0x81d17744)); // IAny2EVMMessageReceiver
        assertTrue(srcTransport.supportsInterface(0x01ffc9a7)); // ERC165
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _deployProtocolStack(
        ChainId chainId
    ) internal returns (
        ProtocolAccessManager accessManager,
        TransferIntentManager tim,
        RuleEngineComplianceProvider compliance,
        ERC3643AssetAdapter adapter,
        MockCCIPRouter router,
        CCIPTransportProvider transport,
        SettlementCoordinator settlement
    ) {
        accessManager = new ProtocolAccessManager(ADMIN);
        tim = new TransferIntentManager(IProtocolAccessManager(address(accessManager)));
        compliance = new RuleEngineComplianceProvider(IProtocolAccessManager(address(accessManager)));
        adapter = new ERC3643AssetAdapter(IProtocolAccessManager(address(accessManager)), chainId);
        router = new MockCCIPRouter();

        address predictedCoordinator = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);

        transport = new CCIPTransportProvider(
            IProtocolAccessManager(address(accessManager)),
            ICcipRouterClient(address(router)),
            ISettlementCoordinator(predictedCoordinator),
            address(0)
        );

        settlement = new SettlementCoordinator(
            IProtocolAccessManager(address(accessManager)),
            chainId,
            ITransferIntentManager(address(tim)),
            ICompliancePolicyProvider(address(compliance)),
            IAssetAdapter(address(adapter)),
            ITransportProvider(address(transport))
        );

        // Grant roles
        bytes32 bridgeRole = accessManager.BRIDGE_ROLE();
        bytes32 complianceRole = accessManager.COMPLIANCE_ROLE();
        vm.prank(ADMIN);
        accessManager.grantRole(bridgeRole, BRIDGE_OP);
        vm.prank(ADMIN);
        accessManager.grantRole(bridgeRole, address(settlement));
        vm.prank(ADMIN);
        accessManager.grantRole(complianceRole, COMPLIANCE_OP);

        // Fund transport with ETH
        vm.deal(address(transport), 10 ether);
    }

    function _configureCompliance(RuleEngineComplianceProvider compliance) internal {
        vm.startPrank(COMPLIANCE_OP);
        compliance.setAllowedAsset(ASSET_ID, true);
        compliance.setAllowedAction(ProtocolTypes.IntentAction.TRANSFER, true);
        compliance.setChainJurisdiction(SOURCE_CHAIN, keccak256("US"));
        compliance.setChainJurisdiction(DEST_CHAIN, keccak256("EU"));
        compliance.setMaxTransferAmount(ASSET_ID, 100_000 ether);
        compliance.setMaxHolding(ASSET_ID, 1_000_000 ether);
        vm.stopPrank();
    }

    function _deliverPhaseMessage(
        CCIPTransportProvider destProvider,
        MockCCIPRouter destRouter,
        uint64 ccipSourceSelector,
        address sourceTransportAddress,
        CCIPTransportProvider sourceProvider,
        bytes32 intentId,
        ChainId sourceChain,
        ChainId destChain,
        uint64 expiresAt,
        bytes32 msgId,
        ProtocolTypes.MessageType messageType,
        ProtocolTypes.SettlementPhase phase,
        bytes memory payload
    ) internal {
        ProtocolTypes.TransportMessage memory tm = ProtocolTypes.TransportMessage({
            messageVersion: 1,
            transportId: sourceProvider.TRANSPORT_ID(),
            messageType: messageType,
            phase: phase,
            messageId: bytes32(0),
            intentId: intentId,
            sourceChainId: ChainId.unwrap(sourceChain),
            destinationChainId: ChainId.unwrap(destChain),
            expiresAt: expiresAt,
            sender: address(0),
            recipient: address(0),
            payloadHash: keccak256(payload),
            payload: payload
        });

        Any2EVMMessage memory ccipMsg = Any2EVMMessage({
            messageId: msgId,
            sourceChainSelector: ccipSourceSelector,
            sender: abi.encode(sourceTransportAddress),
            data: abi.encode(tm),
            destTokenAmounts: new ICcipRouterClient.EVMTokenAmount[](0)
        });

        vm.prank(address(destRouter));
        destProvider.ccipReceive(ccipMsg);
    }

    function _nextNonce() internal returns (uint64) {
        return ++_nonce;
    }
}
