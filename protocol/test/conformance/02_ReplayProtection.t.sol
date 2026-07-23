// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Transport Message Replay Protection
//
// Once a messageId is delivered successfully (TransportStatus.DELIVERED), the
// TransportProvider MUST reject a second delivery of the same messageId. The
// SettlementCoordinator's _processedMessages mapping provides a secondary
// guard against duplicate processing, but the provider-level guard is the
// authoritative first line of defense.
//
// A replay attempt MUST revert with CCIPProvider__MessageNotRetryable.
// No duplicate mint, no duplicate state transition, no balance change.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes, ChainId} from "../../contracts/common/ProtocolTypes.sol";
import {CCIPTransportProvider, Any2EVMMessage} from "../../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract ReplayProtectionTest is ConformanceBase {
    ProtocolFixture source;
    ProtocolFixture dest;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        dest = deployProtocol(admin, DEST_CHAIN, CCIP_DEST_SELECTOR, bridgeOp, complianceOp);
        _configureTransport(source, dest);
        _configureAssetAndCompliance(source);
        _configureAssetAndCompliance(dest);
        _mintSenderTokens(source);
    }

    function test_ReplayProtection() public {
        ProtocolTypes.TransferIntent memory intent = _createIntent();
        bytes32 intentId = intent.intentId;

        // Setup destination as if VALIDATION_REQUEST was handled.
        vm.prank(bridgeOp);
        dest.transferIntentManager.createTransferIntent(intent);
        vm.prank(bridgeOp);
        dest.transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.VALIDATED);

        // Deliver SETTLEMENT_INSTRUCTION once (success).
        bytes32 msgId = keccak256("replay_test");

        _deliverPhaseMessage(
            dest.transportProvider, dest.router,
            CCIP_SOURCE_SELECTOR, address(source.transportProvider),
            source.transportProvider,
            intentId, SOURCE_CHAIN, DEST_CHAIN,
            intent.expiresAt,
            msgId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION,
            bytes("")
        );

        assertEq(dest.token.balanceOf(recipient), TRANSFER_AMOUNT, "first delivery minted tokens");

        _assertIntentState(
            dest.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.SETTLED,
            "dest SETTLED after first delivery"
        );

        // Deliver the SAME messageId again — must revert at provider level.
        ProtocolTypes.TransportMessage memory tm = ProtocolTypes.TransportMessage({
            messageVersion: 1,
            transportId: source.transportProvider.TRANSPORT_ID(),
            messageType: ProtocolTypes.MessageType.TRANSFER_INTENT,
            phase: ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION,
            messageId: bytes32(0),
            intentId: intentId,
            sourceChainId: ChainId.unwrap(SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(DEST_CHAIN),
            expiresAt: intent.expiresAt,
            sender: address(0),
            recipient: address(0),
            payloadHash: keccak256(bytes("")),
            payload: bytes("")
        });

        Any2EVMMessage memory ccipMsg = _outboundMessage(
            msgId,
            CCIP_SOURCE_SELECTOR,
            address(source.transportProvider),
            abi.encode(tm)
        );

        vm.prank(address(dest.router));
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTransportProvider.CCIPProvider__MessageNotRetryable.selector,
                msgId,
                ProtocolTypes.TransportStatus.DELIVERED
            )
        );
        dest.transportProvider.ccipReceive(ccipMsg);

        // State unchanged — no double mint.
        _assertIntentState(
            dest.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.SETTLED,
            "dest state unchanged after replay"
        );

        assertEq(dest.token.balanceOf(recipient), TRANSFER_AMOUNT, "no double mint after replay");
    }
}
