// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Invalid Transport Sender Authentication
//
// The TransportProvider MUST authenticate the sender of every inbound CCIP
// message against its per-chain allowlist (setAllowedSender). Messages from
// senders that are not allowlisted MUST revert with
// CCIPProvider__SenderNotAllowed. No state changes, no settlement, no token
// movement may occur.
//
// This is the second authentication layer (after the Router identity check
// in layer 1). Even if a malicious actor gains access to the CCIP Router,
// they cannot deliver messages without being on the allowlist.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes, ChainId} from "../../contracts/common/ProtocolTypes.sol";
import {CCIPTransportProvider, Any2EVMMessage} from "../../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract InvalidTransportSenderTest is ConformanceBase {
    ProtocolFixture source;
    ProtocolFixture dest;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        dest = deployProtocol(admin, DEST_CHAIN, CCIP_DEST_SELECTOR, bridgeOp, complianceOp);

        // Configure chain selectors on both sides (needed for routing/lookup)
        // but do NOT call setAllowedSender — the source transport is NOT
        // allowlisted on the destination.
        vm.startPrank(bridgeOp);
        source.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        source.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        dest.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        dest.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        vm.stopPrank();

        _configureAssetAndCompliance(source);
        _configureAssetAndCompliance(dest);
        _mintSenderTokens(source);
    }

    function test_InvalidTransportSender() public {
        ProtocolTypes.TransferIntent memory intent = _createIntent();
        bytes32 intentId = intent.intentId;

        // Setup destination intent as if it were validated.
        vm.prank(bridgeOp);
        dest.transferIntentManager.createTransferIntent(intent);
        vm.prank(bridgeOp);
        dest.transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.VALIDATED);

        // Attempt to deliver a SETTLEMENT_INSTRUCTION from source transport.
        // The source transport is NOT allowlisted on dest — must revert.
        bytes32 msgId = keccak256("unauthorized_sender");

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
                CCIPTransportProvider.CCIPProvider__SenderNotAllowed.selector,
                CCIP_SOURCE_SELECTOR,
                address(source.transportProvider)
            )
        );
        dest.transportProvider.ccipReceive(ccipMsg);

        // Destination state unchanged — still VALIDATED.
        _assertIntentState(
            dest.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.VALIDATED,
            "dest state unchanged after unauthorized delivery"
        );

        // No tokens moved.
        assertEq(dest.token.balanceOf(recipient), 0, "recipient balance unchanged");
    }
}
