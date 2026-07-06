// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Expired Intent Rejection
//
// An intent with expiresAt ≤ block.timestamp MUST be rejected at creation
// time by the TransferIntentManager. The submitTransfer call MUST revert
// with TransferIntentManager__IntentExpired. No state may be created.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {TransferIntentManager} from "../../contracts/core/TransferIntentManager.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract ExpiredIntentTest is ConformanceBase {
    ProtocolFixture source;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        _configureAssetAndCompliance(source);
        _mintSenderTokens(source);
    }

    function test_ExpiredIntent() public {
        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(
            abi.encode(SOURCE_CHAIN, nonce, sender, recipient, TRANSFER_AMOUNT)
        );
        // expiresAt = block.timestamp → intent is already expired (must be > block.timestamp)
        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
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
            expiresAt: uint64(block.timestamp)
        });

        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(
                TransferIntentManager.TransferIntentManager__IntentExpired.selector,
                intentId
            )
        );
        source.settlementCoordinator.submitTransfer(intent);

        // Verify no state was created.
        assertFalse(
            source.transferIntentManager.exists(intentId),
            "expired intent not created"
        );
        assertEq(source.token.balanceOf(sender), TOKEN_SUPPLY, "balance unchanged");
    }
}
