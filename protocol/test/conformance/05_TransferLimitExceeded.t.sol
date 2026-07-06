// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Transfer Limit Exceeded
//
// If the transfer amount exceeds the per-asset maximum configured in the
// compliance provider, compliance MUST reject. The intent MUST transition to
// REJECTED. No reservation or transport may occur.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract TransferLimitExceededTest is ConformanceBase {
    ProtocolFixture source;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        _configureAssetAndCompliance(source);
        _mintSenderTokens(source);
    }

    function test_TransferLimitExceeded() public {
        // Set max transfer amount below the test transfer amount.
        vm.prank(complianceOp);
        source.complianceProvider.setMaxTransferAmount(ASSET_ID, TRANSFER_AMOUNT - 1);

        ProtocolTypes.TransferIntent memory intent = _createIntent();
        bytes32 intentId = intent.intentId;

        uint256 balanceBefore = source.token.balanceOf(sender);

        vm.prank(sender);
        bytes32 returnedId = source.settlementCoordinator.submitTransfer(intent);

        assertEq(returnedId, intentId, "intentId returned");

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.REJECTED,
            "state REJECTED for exceeding transfer limit"
        );

        assertEq(source.token.balanceOf(sender), balanceBefore, "balance unchanged");
        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            0,
            "no reservation after limit exceeded"
        );
    }
}
