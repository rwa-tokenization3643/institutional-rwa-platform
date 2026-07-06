// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ConformanceBase} from "./ConformanceBase.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";

contract InvalidIdentityTest is ConformanceBase {
    ProtocolFixture source;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        _configureAssetAndCompliance(source);
        _mintSenderTokens(source);
    }

    function test_InvalidSenderIdentity() public {
        ProtocolTypes.TransferIntent memory intent = _createIntent();
        intent.senderIdentityHash = bytes32(0);
        bytes32 intentId = intent.intentId;

        vm.prank(sender);
        source.settlementCoordinator.submitTransfer(intent);

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.REJECTED,
            "zero sender identity -> REJECTED"
        );

        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            0,
            "no reservation after identity rejection"
        );

        assertEq(
            source.token.balanceOf(sender),
            TOKEN_SUPPLY,
            "sender balance unchanged"
        );
    }

    function test_InvalidRecipientIdentity() public {
        ProtocolTypes.TransferIntent memory intent = _createIntent();
        intent.recipientIdentityHash = bytes32(0);
        bytes32 intentId = intent.intentId;

        vm.prank(sender);
        source.settlementCoordinator.submitTransfer(intent);

        _assertIntentState(
            source.transferIntentManager, intentId,
            ProtocolTypes.SettlementState.REJECTED,
            "zero recipient identity -> REJECTED"
        );

        assertEq(
            source.assetAdapter.reservedBalance(ASSET_ID, sender, bytes32(0)),
            0,
            "no reservation after identity rejection"
        );
    }
}
