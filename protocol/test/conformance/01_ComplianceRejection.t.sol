// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Compliance Rejection
//
// When compliance evaluation fails during submitTransfer, the intent MUST
// transition to REJECTED. No assets may be reserved, no transport messages
// may be dispatched, and the sender's token balance MUST be unchanged.
//
// This invariant holds regardless of which specific compliance check fails.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract ComplianceRejectionTest is ConformanceBase {
    ProtocolFixture source;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        _configureAssetAndCompliance(source);
        _mintSenderTokens(source);
    }

    function test_ComplianceRejection() public {
        ProtocolTypes.TransferIntent memory intent = _createIntent();
        bytes32 intentId = intent.intentId;

        // Block the TRANSFER action — this triggers a compliance failure
        // before any assets move or messages are sent.
        vm.prank(complianceOp);
        source.complianceProvider.setAllowedAction(ProtocolTypes.IntentAction.TRANSFER, false);

        uint256 balanceBefore = source.token.balanceOf(sender);
        uint256 reservedBefore = source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0));

        vm.prank(sender);
        bytes32 returnedId = source.settlementCoordinator.submitTransfer(intent);

        assertEq(returnedId, intentId, "intentId returned on rejection");

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.REJECTED,
            "state REJECTED after compliance failure"
        );

        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            reservedBefore,
            "no reservation after compliance rejection"
        );

        assertEq(
            source.token.balanceOf(sender),
            balanceBefore,
            "sender balance unchanged after compliance rejection"
        );
    }
}
