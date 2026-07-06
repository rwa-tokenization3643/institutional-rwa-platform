// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// ═════════════════════════════════════════════════════════════════════════════
// Protocol Invariant: Unsupported Settlement Model Rejection
//
// The adapter's configureAsset() MUST revert when given a settlement model
// that it does not support. Only BURN_MINT, LOCK_MINT, LOCK_UNLOCK, and
// ESCROW_RELEASE are recognised. Any other value MUST produce
// ERC3643Adapter__UnsupportedSettlementModel.
//
// This ensures asset onboarding cannot proceed with an invalid configuration
// that would cause silent mint/burn failures at settlement time.
// ═════════════════════════════════════════════════════════════════════════════

import {ProtocolFixture} from "../utils/ProtocolFixture.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {ERC3643AssetAdapter} from "../../contracts/adapters/ERC3643AssetAdapter.sol";
import {ConformanceBase} from "./ConformanceBase.sol";

contract UnsupportedSettlementModelTest is ConformanceBase {
    ProtocolFixture source;

    function setUp() public {
        source = deployProtocol(admin, SOURCE_CHAIN, CCIP_SOURCE_SELECTOR, bridgeOp, complianceOp);
        // No asset configuration — we are testing rejection.
    }

    function test_UnsupportedSettlementModel() public {
        bytes32 garbageModel = keccak256("GARBAGE_MODEL");

        vm.prank(complianceOp);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC3643AssetAdapter.ERC3643Adapter__UnsupportedSettlementModel.selector,
                garbageModel
            )
        );
        source.assetAdapter.configureAsset(
            keccak256("NEW_ASSET"),
            address(0xBEEF),
            18,
            ASSET_TYPE,
            garbageModel,
            keccak256("T-REX:4.1.6")
        );
    }
}
