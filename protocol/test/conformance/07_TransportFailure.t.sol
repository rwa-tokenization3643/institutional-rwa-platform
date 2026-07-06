// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Transport Delivery Failure
//
// When SettlementCoordinator.handleTransportMessage reverts (e.g. because
// the mint call fails), the TransportProvider MUST catch the failure and
// set TransportStatus to FAILED. No settlement completion may occur.
// The intent state on the destination MUST remain unchanged (not SETTLED).
// The recipient MUST NOT receive tokens.
// The message remains retryable — a second delivery with a new messageId
// MUST succeed after the underlying issue is resolved.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {ITransportProvider} from "../../contracts/interfaces/ITransportProvider.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract TransportFailureTest is ConformanceBase {
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

    function test_TransportFailure() public {
        ProtocolTypes.TransferIntent memory intent = _createIntent();
        bytes32 intentId = intent.intentId;

        // Setup destination as if VALIDATION_REQUEST was handled.
        vm.prank(bridgeOp);
        dest.transferIntentManager.createTransferIntent(intent);
        vm.prank(bridgeOp);
        dest.transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.VALIDATED);

        // Make destination token revert on mint.
        dest.token.setShouldRevertMint(true);

        // Deliver SETTLEMENT_INSTRUCTION — handler will try to mint and fail.
        bytes32 msgId = keccak256("transport_failure");

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

        // Transport status MUST be FAILED.
        ProtocolTypes.TransportStatus status = dest.transportProvider.getMessageStatus(msgId);
        assertEq(
            uint256(status), uint256(ProtocolTypes.TransportStatus.FAILED),
            "transport status FAILED after mint revert"
        );

        // Destination intent MUST remain VALIDATED (mint never completed).
        _assertIntentState(
            dest.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.VALIDATED,
            "dest state unchanged (VALIDATED) after failed mint"
        );

        // Recipient MUST NOT have received tokens.
        assertEq(dest.token.balanceOf(recipient), 0, "recipient balance zero after failed mint");

        // Now fix the token and retry with a new messageId.
        dest.token.setShouldRevertMint(false);

        bytes32 retryMsgId = keccak256("transport_failure_retry");

        _deliverPhaseMessage(
            dest.transportProvider, dest.router,
            CCIP_SOURCE_SELECTOR, address(source.transportProvider),
            source.transportProvider,
            intentId, SOURCE_CHAIN, DEST_CHAIN,
            intent.expiresAt,
            retryMsgId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION,
            bytes("")
        );

        // After retry, destination MUST be SETTLED.
        _assertIntentState(
            dest.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.SETTLED,
            "dest SETTLED after retry"
        );

        assertEq(
            dest.token.balanceOf(recipient), TRANSFER_AMOUNT,
            "recipient received tokens after retry"
        );
    }
}
