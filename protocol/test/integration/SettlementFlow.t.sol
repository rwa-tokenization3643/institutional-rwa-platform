// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ProtocolTypes, ChainId} from "../../contracts/common/ProtocolTypes.sol";
import {ProtocolAccessManager} from "../../contracts/access/ProtocolAccessManager.sol";
import {IProtocolAccessManager} from "../../contracts/access/IProtocolAccessManager.sol";
import {ITransferIntentManager} from "../../contracts/interfaces/ITransferIntentManager.sol";
import {TransferIntentManager} from "../../contracts/core/TransferIntentManager.sol";
import {ICompliancePolicyProvider} from "../../contracts/interfaces/ICompliancePolicyProvider.sol";
import {RuleEngineComplianceProvider} from "../../contracts/compliance/RuleEngineComplianceProvider.sol";
import {IAssetAdapter} from "../../contracts/interfaces/IAssetAdapter.sol";
import {ERC3643AssetAdapter} from "../../contracts/adapters/ERC3643AssetAdapter.sol";
import {ISettlementCoordinator} from "../../contracts/interfaces/ISettlementCoordinator.sol";
import {SettlementCoordinator} from "../../contracts/core/SettlementCoordinator.sol";
import {ITransportProvider} from "../../contracts/interfaces/ITransportProvider.sol";
import {CCIPTransportProvider, ICcipRouterClient, Any2EVMMessage} from "../../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {MockERC3643Token} from "../mocks/MockERC3643Token.sol";
import {MockCCIPRouter} from "../mocks/MockCCIPRouter.sol";
import {ProtocolFixture, ProtocolFixtureBase} from "../utils/ProtocolFixture.sol";

// =============================================================================
// Settlement Flow Integration Test
// =============================================================================
//
// This test validates the complete six-message cross-chain settlement lifecycle
// using the ProtocolFixture for reusable deployment. Both chains run on a
// single EVM; cross-chain messages are simulated by crafting Any2EVMMessage
// structs and calling ccipReceive directly.
//
// ── Architecture ──
//
// Source Chain (ChainId 1)           Destination Chain (ChainId 2)
// ────────────────────────           ───────────────────────────
// SettlementCoordinator              SettlementCoordinator
// TransferIntentManager              TransferIntentManager
// CCIPTransportProvider              CCIPTransportProvider
// MockCCIPRouter                     MockCCIPRouter
// MockERC3643Token                   MockERC3643Token
// ERC3643AssetAdapter                ERC3643AssetAdapter
// RuleEngineComplianceProvider       RuleEngineComplianceProvider
// ProtocolAccessManager              ProtocolAccessManager
//
// ── Settlement Protocol ──
//
//   Source                          Destination
//   ──────                          ───────────
//   Phase 1: submitTransfer
//      -> PENDING_VALIDATION
//   Phase 2: --- VALIDATION_REQUEST -->  Create intent, compliance
//                                           -> VALIDATED
//                                        Dispatch APPROVED response
//   Phase 3: <--- VALIDATION_RESPONSE --
//      Handler: -> VALIDATED -> RESERVED
//      Dispatch SETTLEMENT_INSTRUCTION
//   Phase 4: --- dispatch INSTRUCTION ->  Mint assets -> SETTLED
//                                        Dispatch SETTLEMENT_ACK
//   Phase 5: <--- SETTLEMENT_ACK ----
//      Burn reserved tokens -> SETTLED
//   Phase 6: Verify invariants
//
// ── Protocol Invariants (verified) ──
//
//   A. Source state:   PENDING -> VALIDATED -> RESERVED -> SETTLED
//   B. Dest state:     PENDING -> VALIDATED -> SETTLED
//   C. Sender source balance decreases by TRANSFER_AMOUNT (burn)
//   D. Recipient dest balance increases by TRANSFER_AMOUNT (mint)
//   E. Total supply conserved across chains
//   F. No residual reservations after completion
//
// =============================================================================

contract SettlementFlowTest is ProtocolFixtureBase {
    ChainId internal constant SOURCE_CHAIN = ChainId.wrap(1);
    ChainId internal constant DEST_CHAIN = ChainId.wrap(2);
    uint64 internal constant CCIP_SOURCE_SELECTOR = 15971525489660198786;
    uint64 internal constant CCIP_DEST_SELECTOR = 5009297550715157269;

    bytes32 internal constant ASSET_ID = keccak256("RWA_TOKEN");
    bytes32 internal constant ASSET_TYPE = keccak256("BOND");
    bytes32 internal constant BURN_MINT = keccak256("BURN_MINT");
    bytes32 internal constant JURISDICTION_US = keccak256("US");
    bytes32 internal constant JURISDICTION_EU = keccak256("EU");

    uint256 internal constant TOKEN_SUPPLY = 10_000 ether;
    uint256 internal constant TRANSFER_AMOUNT = 1_000 ether;

    address internal admin = address(0xA11CE);
    address internal complianceOp = address(0xCAFE);
    address internal bridgeOp = address(0xB0B0B);
    address internal sender = address(0xAAA);
    address internal recipient = address(0xBBB);

    ProtocolFixture source;
    ProtocolFixture dest;

    uint64 internal _nonce;

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _nextNonce() internal returns (uint64) {
        return ++_nonce;
    }

    function _createIntent()
        internal
        returns (ProtocolTypes.TransferIntent memory intent)
    {
        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(
            abi.encode(SOURCE_CHAIN, nonce, sender, recipient, TRANSFER_AMOUNT)
        );
        intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: sender,
            recipient: recipient,
            senderIdentityHash: bytes32(uint256(1)),
            recipientIdentityHash: bytes32(uint256(2)),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: SOURCE_CHAIN,
            destinationChainId: DEST_CHAIN,
            amount: TRANSFER_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function _assertIntentState(
        ITransferIntentManager manager,
        bytes32 intentId,
        ProtocolTypes.SettlementState expectedState,
        string memory label
    ) internal view {
        assertEq(
            uint256(manager.getSettlementState(intentId)),
            uint256(expectedState),
            label
        );
    }

    function _outboundMessage(
        bytes32 messageId,
        uint64 ccipSourceSelector,
        address senderAddress,
        bytes memory payload
    ) internal pure returns (Any2EVMMessage memory) {
        address[] memory emptyAddrs;
        uint256[] memory emptyUints;
        return Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: ccipSourceSelector,
            sender: abi.encode(senderAddress),
            data: payload,
            destTokenAmounts: emptyAddrs,
            destTokenAmountsValues: emptyUints
        });
    }

    function _deliverTo(
        CCIPTransportProvider provider,
        MockCCIPRouter router,
        uint64 ccipSourceSelector,
        address sourceTransportAddress,
        bytes32 messageId,
        bytes memory payload
    ) internal {
        Any2EVMMessage memory ccipMsg = _outboundMessage(
            messageId, ccipSourceSelector, sourceTransportAddress, payload
        );
        vm.prank(address(router));
        provider.ccipReceive(ccipMsg);
    }

    function _deliverPhaseMessage(
        CCIPTransportProvider destProvider,
        MockCCIPRouter destRouter_,
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
            sourceChainId: sourceChain,
            destinationChainId: destChain,
            expiresAt: expiresAt,
            sender: address(0),
            recipient: address(0),
            payloadHash: keccak256(payload),
            payload: payload
        });
        _deliverTo(
            destProvider, destRouter_,
            ccipSourceSelector, sourceTransportAddress,
            msgId, abi.encode(tm)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Setup
    // ═══════════════════════════════════════════════════════════════════════

    function setUp() public {
        // Deploy both protocol stacks
        source = deployProtocol(
            admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp
        );
        dest = deployProtocol(
            admin, DEST_CHAIN, CCIP_DEST_SELECTOR, bridgeOp, complianceOp
        );

        // Configure transport on source
        vm.startPrank(bridgeOp);
        source.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        source.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        source.transportProvider.setAllowedSender(DEST_CHAIN, address(dest.transportProvider), true);
        vm.stopPrank();

        // Configure transport on destination
        vm.startPrank(bridgeOp);
        dest.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        dest.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        dest.transportProvider.setAllowedSender(SOURCE_CHAIN, address(source.transportProvider), true);
        vm.stopPrank();

        // Configure assets on both chains
        configureAsset(source, ASSET_ID, address(source.token), 18, ASSET_TYPE, BURN_MINT);
        configureAsset(dest, ASSET_ID, address(dest.token), 18, ASSET_TYPE, BURN_MINT);

        // Configure compliance on both chains
        ChainId[] memory chains = new ChainId[](2);
        chains[0] = SOURCE_CHAIN;
        chains[1] = DEST_CHAIN;
        bytes32[] memory jurisdictions = new bytes32[](2);
        jurisdictions[0] = JURISDICTION_US;
        jurisdictions[1] = JURISDICTION_EU;
        configureCompliance(source, ASSET_ID, ProtocolTypes.IntentAction.TRANSFER, chains, jurisdictions);
        configureCompliance(dest, ASSET_ID, ProtocolTypes.IntentAction.TRANSFER, chains, jurisdictions);

        // Mint tokens to sender on source
        source.token.mint(sender, TOKEN_SUPPLY);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Successful Cross-Chain Settlement
    // ═══════════════════════════════════════════════════════════════════════
    //
    // ── Invariant Summary ──
    //
    //   After all six message exchanges complete:
    //     Source state: SETTLED
    //     Dest state:   SETTLED
    //     Sender loses TRANSFER_AMOUNT tokens (burned on source)
    //     Recipient gains TRANSFER_AMOUNT tokens (minted on dest)
    //     Total supply is conserved: source + dest = TOKEN_SUPPLY
    //     No residual reservations remain
    //
    // ═══════════════════════════════════════════════════════════════════════

    function test_settlement_SuccessfulFlow() public {
        // ═══════════════════════════════════════════════════════════════════
        // Phase 0: Setup & Initial Assertions
        // ═══════════════════════════════════════════════════════════════════
        //
        // Protocol Invariant: Before any submission, the sender has the full
        //   TOKEN_SUPPLY on source and the recipient has zero on dest.
        //
        ProtocolTypes.TransferIntent memory intent = _createIntent();
        bytes32 intentId = intent.intentId;

        uint256 senderBalanceBefore = source.token.balanceOf(sender);
        uint256 recipientBalanceBefore = dest.token.balanceOf(recipient);

        assertEq(senderBalanceBefore, TOKEN_SUPPLY, "sender initial balance");
        assertEq(recipientBalanceBefore, 0, "recipient initial balance");
        assertEq(
            source.assetAdapter.availableBalance(ASSET_ID, sender, bytes32(0)),
            TOKEN_SUPPLY,
            "all tokens available before submission"
        );

        // ═══════════════════════════════════════════════════════════════════
        // Phase 1: Submit Transfer (Source)
        // ═══════════════════════════════════════════════════════════════════
        //
        // 1.1. Sender submits via submitTransfer(intent).
        // 1.2. Coordinator creates intent in PENDING_VALIDATION.
        // 1.3. Compliance passes (source=US, dest=EU, TRANSFER allowed).
        // 1.4. Coordinator dispatches VALIDATION_REQUEST to destination.
        //
        // Invariant: After submitTransfer, source intent is PENDING_VALIDATION.
        //   No assets are reserved during Phase 1. Sender balance unchanged.
        //
        vm.prank(sender);
        bytes32 returnedId = source.settlementCoordinator.submitTransfer(intent);
        assertEq(returnedId, intentId, "submitTransfer returns intentId");

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.PENDING_VALIDATION,
            "source state: PENDING_VALIDATION after submit"
        );

        assertEq(
            source.token.balanceOf(sender),
            senderBalanceBefore,
            "sender balance unchanged after submit"
        );
        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            0,
            "no reservation during Phase 1"
        );

        // ═══════════════════════════════════════════════════════════════════
        // Phase 2: Validation Request (Source -> Destination)
        // ═══════════════════════════════════════════════════════════════════
        //
        // 2.1. Source coordinator sent TransportMessage with
        //      payload = abi.encode(intent), messageType=TRANSFER_INTENT,
        //      phase=VALIDATION_REQUEST.
        // 2.2. Deliver via destTransport.ccipReceive().
        // 2.3. destCoordinator._handleValidationRequest:
        //      - Decodes TransferIntent from payload
        //      - Creates local intent record
        //      - Evaluates compliance (passes)
        //      - Transitions to VALIDATED
        //      - Dispatches VALIDATION_RESPONSE (APPROVED)
        //
        // Invariant: Destination MUST have intent in VALIDATED. No tokens
        //   minted on dest during validation.
        //
        bytes32 valReqMsgId = keccak256("validation_request");
        bytes memory valReqPayload = abi.encode(intent);

        _deliverPhaseMessage(
            dest.transportProvider, dest.router,
            CCIP_SOURCE_SELECTOR, address(source.transportProvider),
            source.transportProvider,
            intentId, SOURCE_CHAIN, DEST_CHAIN,
            intent.expiresAt,
            valReqMsgId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
            valReqPayload
        );

        _assertIntentState(
            dest.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.VALIDATED,
            "dest state: VALIDATED after validation request"
        );

        assertEq(
            dest.token.balanceOf(recipient),
            0,
            "recipient balance unchanged after validation"
        );

        // ═══════════════════════════════════════════════════════════════════
        // Phase 3: Validation Response (Destination -> Source)
        // ═══════════════════════════════════════════════════════════════════
        //
        // 3.1. Destination dispatches VALIDATION_RESPONSE with APPROVED.
        // 3.2. Deliver back to source via sourceTransport.ccipReceive().
        // 3.3. sourceCoordinator._handleValidationResponse:
        //      - Checks state == PENDING_VALIDATION (passes)
        //      - result is APPROVED → transitions VALIDATED
        //      - Calls _reserveAssets → locks sender tokens
        //      - Transitions to RESERVED
        //      - Dispatches SETTLEMENT_INSTRUCTION to destination
        //
        // Invariant: Source MUST transition from PENDING_VALIDATION to
        //   RESERVED atomically. Sender's tokens MUST be locked in
        //   reservation. Available balance decreases.
        //
        bytes32 valResMsgId = keccak256("validation_response");
        bytes memory valResPayload = abi.encode(ProtocolTypes.ComplianceResult.APPROVED);

        _deliverPhaseMessage(
            source.transportProvider, source.router,
            CCIP_DEST_SELECTOR, address(dest.transportProvider),
            dest.transportProvider,
            intentId, DEST_CHAIN, SOURCE_CHAIN,
            intent.expiresAt,
            valResMsgId,
            ProtocolTypes.MessageType.VALIDATION_RESPONSE,
            ProtocolTypes.SettlementPhase.VALIDATION_RESPONSE,
            valResPayload
        );

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.RESERVED,
            "source state: RESERVED after handler execution"
        );

        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            TRANSFER_AMOUNT,
            "reserved amount after handler"
        );

        assertEq(
            source.assetAdapter.availableBalance(ASSET_ID, sender, bytes32(0)),
            TOKEN_SUPPLY - TRANSFER_AMOUNT,
            "available balance decreased after reservation"
        );

        assertEq(
            dest.token.balanceOf(recipient),
            0,
            "no tokens minted on dest during Phase 3"
        );

        // ═══════════════════════════════════════════════════════════════════
        // Phase 4: Settlement Instruction (Source -> Destination)
        // ═══════════════════════════════════════════════════════════════════
        //
        // The handler's SETTLEMENT_INSTRUCTION was dispatched through the
        // mock CCIP router. We deliver a matching message to the destination
        // with a deterministic messageId.
        //
        // 4.1. destCoordinator._handleSettlementInstruction:
        //      - Fetches intent from local manager
        //      - Calls destAdapter.mintAssets(intent)
        //        -> destToken.mint(recipient, TRANSFER_AMOUNT)
        //      - Transitions VALIDATED -> SETTLED
        //      - Dispatches SETTLEMENT_ACK back to source
        //
        // Invariant: Destination intent MUST be SETTLED. Recipient MUST
        //   have received exactly TRANSFER_AMOUNT tokens.
        //
        bytes32 instrMsgId = keccak256("settlement_instruction");

        _deliverPhaseMessage(
            dest.transportProvider, dest.router,
            CCIP_SOURCE_SELECTOR, address(source.transportProvider),
            source.transportProvider,
            intentId, SOURCE_CHAIN, DEST_CHAIN,
            intent.expiresAt,
            instrMsgId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION,
            bytes("")
        );

        _assertIntentState(
            dest.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.SETTLED,
            "dest state: SETTLED after settlement instruction"
        );

        assertEq(
            dest.token.balanceOf(recipient),
            TRANSFER_AMOUNT,
            "recipient received tokens on destination"
        );

        // ═══════════════════════════════════════════════════════════════════
        // Phase 5: Settlement Acknowledgement (Source)
        // ═══════════════════════════════════════════════════════════════════
        //
        // 5.1. Destination dispatches SETTLEMENT_ACK.
        // 5.2. Deliver back to source via sourceTransport.ccipReceive().
        // 5.3. sourceCoordinator._handleSettlementAcknowledgement:
        //      - Calls sourceAdapter.burnReservedAssets(intent)
        //        -> sourceToken burn sender's tokens
        //      - Transitions to SETTLED
        //      - Emits IntentCompleted
        //
        // Invariant: Source intent MUST be SETTLED. Sender's token balance
        //   MUST decrease by TRANSFER_AMOUNT. No residual reservations.
        //
        bytes32 ackMsgId = keccak256("settlement_ack");

        _deliverPhaseMessage(
            source.transportProvider, source.router,
            CCIP_DEST_SELECTOR, address(dest.transportProvider),
            dest.transportProvider,
            intentId, DEST_CHAIN, SOURCE_CHAIN,
            intent.expiresAt,
            ackMsgId,
            ProtocolTypes.MessageType.SETTLEMENT_CONFIRMATION,
            ProtocolTypes.SettlementPhase.SETTLEMENT_ACK,
            bytes("")
        );

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.SETTLED,
            "source state: SETTLED after ack"
        );

        // ═══════════════════════════════════════════════════════════════════
        // Phase 6: Final Verification
        // ═══════════════════════════════════════════════════════════════════
        //
        // Invariant A: Sender's source balance decreased by TRANSFER_AMOUNT
        //
        assertEq(
            source.token.balanceOf(sender),
            TOKEN_SUPPLY - TRANSFER_AMOUNT,
            "sender final balance on source (burned)"
        );

        //
        // Invariant B: Recipient's dest balance increased by TRANSFER_AMOUNT
        //
        assertEq(
            dest.token.balanceOf(recipient),
            TRANSFER_AMOUNT,
            "recipient final balance on dest (minted)"
        );

        //
        // Invariant C: Total supply conserved across chains
        //
        assertEq(
            source.token.balanceOf(sender) + dest.token.balanceOf(recipient),
            TOKEN_SUPPLY,
            "total supply conserved across chains"
        );

        //
        // Invariant D: No residual reservation on source
        //
        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            0,
            "no residual reservation after settlement"
        );

        //
        // Invariant E: Available balance fully restored (minus burned amount)
        //
        assertEq(
            source.assetAdapter.availableBalance(ASSET_ID, sender, bytes32(0)),
            TOKEN_SUPPLY - TRANSFER_AMOUNT,
            "available balance reflects burn"
        );
    }
}
