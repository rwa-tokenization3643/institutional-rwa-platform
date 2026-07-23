// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Reservation Rollback
//
// When settlement fails after reservation but before burn, rollback MUST
// release the reserved tokens and transition the intent to ROLLED_BACK.
// The sender's available balance MUST be fully restored. No residual
// reservation may remain. The sender's actual token balance (which was
// never moved during reservation) MUST be unchanged.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract ReservationRollbackTest is ConformanceBase {
    ProtocolFixture source;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        // Configure transport so submitTransfer can dispatch the validation
        // request without reverting. The message goes to the mock router and
        // is never delivered — we manually advance state in this test.
        vm.startPrank(bridgeOp);
        source.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        source.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        source.transportProvider.setRemoteReceiver(DEST_CHAIN, address(1));
        vm.stopPrank();
        _configureAssetAndCompliance(source);
        _mintSenderTokens(source);
    }

    function test_ReservationRollback() public {
        ProtocolTypes.TransferIntent memory intent = _createIntent();
        bytes32 intentId = intent.intentId;

        // Phase 1: Submit — creates intent in PENDING_VALIDATION.
        vm.prank(sender);
        source.settlementCoordinator.submitTransfer(intent);

        // Phase 2: Manual advance to VALIDATED (bypassing validation response bug).
        vm.prank(bridgeOp);
        source.transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.VALIDATED);

        // Phase 3: Reserve assets.
        vm.prank(bridgeOp);
        bool reserved = source.assetAdapter.reserveAssets(intent);
        assertTrue(reserved, "reserveAssets succeeded");

        uint256 reservedBefore = source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0));
        assertEq(reservedBefore, TRANSFER_AMOUNT, "reserved amount before rollback");

        uint256 availableBefore = source.assetAdapter.availableBalance(ASSET_ID, sender, bytes32(0));
        assertEq(availableBefore, TOKEN_SUPPLY - TRANSFER_AMOUNT, "available reduced after reserve");

        // Phase 4: Advance to RESERVED.
        vm.prank(bridgeOp);
        source.transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.RESERVED);

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.RESERVED,
            "state RESERVED before rollback"
        );

        // ═══════════════════════════════════════════════════════════════════
        // Rollback: release reservation and transition to ROLLED_BACK.
        // ═══════════════════════════════════════════════════════════════════

        uint256 senderBalance = source.token.balanceOf(sender);

        vm.prank(bridgeOp);
        bool released = source.assetAdapter.releaseReservation(intent);
        assertTrue(released, "releaseReservation succeeded");

        vm.prank(bridgeOp);
        source.transferIntentManager.transitionState(intentId, ProtocolTypes.SettlementState.ROLLED_BACK);

        // Verify ROLLED_BACK state.
        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.ROLLED_BACK,
            "state ROLLED_BACK after rollback"
        );

        // No residual reservation.
        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            0,
            "no residual reservation after rollback"
        );

        // Sender's token balance unchanged (reservation is internal accounting only).
        assertEq(source.token.balanceOf(sender), senderBalance, "sender balance unchanged");

        // Available balance fully restored.
        assertEq(
            source.assetAdapter.availableBalance(ASSET_ID, sender, bytes32(0)),
            TOKEN_SUPPLY,
            "full amount available after rollback"
        );
    }
}
