// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ConformanceBase} from "./ConformanceBase.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";

contract ConcurrentIntentsWithFailureTest is ConformanceBase {
    ProtocolFixture source;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        // Configure transport so submitTransfer can dispatch VALIDATION_REQUEST
        // without reverting for the valid intent.
        vm.startPrank(bridgeOp);
        source.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        source.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        vm.stopPrank();
        _configureAssetAndCompliance(source);
        _mintSenderTokens(source);
    }

    function test_ConcurrentIntentsWithFailure() public {
        // Intent A — valid, should reach PENDING_VALIDATION.
        ProtocolTypes.TransferIntent memory intentA = _createIntent();
        bytes32 intentIdA = intentA.intentId;

        // Intent B — invalid (zero sender identity), should be REJECTED.
        uint64 nonceB = _nextNonce();
        bytes32 intentIdB = keccak256(abi.encode(SOURCE_CHAIN, nonceB, sender, recipient, TRANSFER_AMOUNT));
        ProtocolTypes.TransferIntent memory intentB = ProtocolTypes.TransferIntent({
            intentId: intentIdB,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: sender,
            recipient: recipient,
            senderIdentityHash: bytes32(0),
            recipientIdentityHash: bytes32(uint256(2)),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: SOURCE_CHAIN,
            destinationChainId: DEST_CHAIN,
            amount: TRANSFER_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonceB,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        // Submit valid intent first.
        vm.prank(sender);
        source.settlementCoordinator.submitTransfer(intentA);
        _assertIntentState(
            source.transferIntentManager, intentIdA,
            ProtocolTypes.SettlementState.PENDING_VALIDATION,
            "intentA: PENDING_VALIDATION"
        );

        // Submit invalid intent.
        vm.prank(sender);
        source.settlementCoordinator.submitTransfer(intentB);
        _assertIntentState(
            source.transferIntentManager, intentIdB,
            ProtocolTypes.SettlementState.REJECTED,
            "intentB: REJECTED (invalid sender identity)"
        );

        // Invariant: intentA is unaffected by intentB's failure.
        _assertIntentState(
            source.transferIntentManager, intentIdA,
            ProtocolTypes.SettlementState.PENDING_VALIDATION,
            "intentA: still PENDING_VALIDATION after B rejected"
        );

        // No reservations for either intent.
        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            0,
            "no reservation after concurrent submit"
        );

        // Sender balance unchanged.
        assertEq(
            source.token.balanceOf(sender),
            TOKEN_SUPPLY,
            "sender balance unchanged"
        );
    }
}
