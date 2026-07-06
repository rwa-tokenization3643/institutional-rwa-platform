// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Unknown Asset Rejection
//
// An asset that has not been configured via configureAsset() MUST be rejected
// before any assets are reserved. The adapter will not recognise it, and the
// compliance provider will not allow it (unknown asset not in allowed list).
//
// The intent MUST transition to REJECTED. No tokens may move. The sender's
// balance MUST be unchanged.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract UnknownAssetTest is ConformanceBase {
    ProtocolFixture source;

    bytes32 internal constant UNKNOWN_ASSET = keccak256("UNKNOWN_ASSET");

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        _configureAssetAndCompliance(source);
        _mintSenderTokens(source);
    }

    function test_UnknownAsset() public {
        // Create an intent referencing an asset that is NOT configured
        // in the adapter and NOT in the compliance allowed list.
        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(
            abi.encode(SOURCE_CHAIN, nonce, sender, recipient, TRANSFER_AMOUNT)
        );
        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: sender,
            recipient: recipient,
            senderIdentityHash: bytes32(uint256(1)),
            recipientIdentityHash: bytes32(uint256(2)),
            assetId: UNKNOWN_ASSET,
            partitionId: bytes32(0),
            sourceChainId: SOURCE_CHAIN,
            destinationChainId: DEST_CHAIN,
            amount: TRANSFER_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        // Verify the adapter does not recognise the asset.
        assertFalse(source.assetAdapter.assetExists(UNKNOWN_ASSET), "unknown asset not registered");

        uint256 balanceBefore = source.token.balanceOf(sender);

        vm.prank(sender);
        bytes32 returnedId = source.settlementCoordinator.submitTransfer(intent);

        assertEq(returnedId, intentId, "intentId returned");

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.REJECTED,
            "state REJECTED for unknown asset"
        );

        assertEq(source.token.balanceOf(sender), balanceBefore, "sender balance unchanged");
        assertEq(
            source.assetAdapter.reservedBalance(UNKNOWN_ASSET, sender, bytes32(0)),
            0,
            "no reservation for unknown asset"
        );
    }
}
