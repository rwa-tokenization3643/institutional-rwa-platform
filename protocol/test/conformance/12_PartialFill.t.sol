// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ConformanceBase} from "./ConformanceBase.sol";
import {ProtocolTypes, ChainId} from "../../contracts/common/ProtocolTypes.sol";

contract PartialFillTest is ConformanceBase {
    ProtocolFixture source;
    ProtocolFixture dest;

    uint256 internal constant INSUFFICIENT_BALANCE = 5_000 ether;
    uint256 internal constant EXCESS_AMOUNT = 10_000 ether;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        dest = deployProtocol(admin, DEST_CHAIN, CCIP_DEST_SELECTOR, bridgeOp, complianceOp);
        _configureTransport(source, dest);
        _configureAssetAndCompliance(source);
        _configureAssetAndCompliance(dest);
        source.token.mint(sender, INSUFFICIENT_BALANCE);
    }

    function test_PartialFillReservationFailure() public {
        // Intent amount (10000) exceeds sender balance (5000).
        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(abi.encode(SOURCE_CHAIN, nonce, sender, recipient, EXCESS_AMOUNT));
        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: sender,
            recipient: recipient,
            senderIdentityHash: bytes32(uint256(1)),
            recipientIdentityHash: bytes32(uint256(2)),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(DEST_CHAIN),
            amount: EXCESS_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        // Phase 1: Source submits — compliance passes (doesn't check balance).
        vm.prank(sender);
        source.settlementCoordinator.submitTransfer(intent);
        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.PENDING_VALIDATION,
            "source: PENDING_VALIDATION after submit"
        );

        // Phase 2: Deliver VALIDATION_REQUEST to dest.
        bytes32 valReqMsgId = keccak256("val_req");
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
            "dest: VALIDATED after validation request"
        );

        // Phase 3: Deliver VALIDATION_RESPONSE(APPROVED) back to source.
        // Handler: transitions to VALIDATED, tries _reserveAssets(10000),
        //          sender only has 5000 → fails → transitions to REJECTED.
        bytes32 valResMsgId = keccak256("val_res");
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

        // Source rejected — insufficient balance caused reservation failure.
        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.REJECTED,
            "source: REJECTED after reservation failure"
        );

        // No tokens reserved.
        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            0,
            "no residual reservation"
        );

        // No tokens minted on dest.
        assertEq(
            dest.token.balanceOf(recipient),
            0,
            "no tokens minted on dest"
        );

        // Dest intent is orphaned in VALIDATED (protocol asymmetry:
        // destination approved but source couldn't reserve). Recovery
        // requires external expiry or a future recovery mechanism.
        _assertIntentState(
            dest.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.VALIDATED,
            "dest: orphaned in VALIDATED (protocol asymmetry)"
        );
    }
}
