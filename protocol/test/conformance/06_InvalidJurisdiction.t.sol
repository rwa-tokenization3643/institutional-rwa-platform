// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Invalid Jurisdiction Rejection
//
// If the source or destination chain's jurisdiction is on the blocked list,
// or if the allow-list is active and the jurisdiction is not in it, the
// compliance provider MUST reject the intent. No reservation or transport
// may occur.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract InvalidJurisdictionTest is ConformanceBase {
    ProtocolFixture source;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        _configureAssetAndCompliance(source);
        _mintSenderTokens(source);
    }

    function test_InvalidJurisdiction() public {
        // Block the source chain jurisdiction.
        vm.prank(complianceOp);
        source.complianceProvider.setBlockedJurisdiction(JURISDICTION_US, true);

        ProtocolTypes.TransferIntent memory intent = _createIntent();
        bytes32 intentId = intent.intentId;

        uint256 balanceBefore = source.token.balanceOf(sender);

        vm.prank(sender);
        bytes32 returnedId = source.settlementCoordinator.submitTransfer(intent);

        assertEq(returnedId, intentId, "intentId returned");

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.REJECTED,
            "state REJECTED for blocked jurisdiction"
        );

        assertEq(source.token.balanceOf(sender), balanceBefore, "balance unchanged");
        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            0,
            "no reservation after jurisdiction rejection"
        );
    }
}
