// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {RuleEngineComplianceProvider} from "../contracts/compliance/RuleEngineComplianceProvider.sol";
import {Config} from "./Config.sol";

contract ComplianceDebug2 is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    address constant COMP = 0x7a237aC13E0Df03Fae5d21025C2265C97ec436De;
    bytes32 constant ID_HASH = 0xbcdb6cfabeedf4cb75ce3843392e397abf95b450b1712991ca6db65da2a9cf8c;

    function run() external {
        console.log("ASSET_ID used in Config.sol:");
        console.log("  %s", vm.toString(Config.ASSET_ID));
        console.log("ID_HASH used in scripts:");
        console.log("  %s", vm.toString(ID_HASH));

        console.log("");
        console.log("=== Compliance Provider State ===");
        console.log("isAssetAllowed: %s", RuleEngineComplianceProvider(COMP).isAssetAllowed(Config.ASSET_ID));
        console.log("getInvestorClassification: %d", uint8(RuleEngineComplianceProvider(COMP).getInvestorClassification(ID_HASH)));
        console.log("getMinimumClassification: %d", uint8(RuleEngineComplianceProvider(COMP).getMinimumClassification()));
        console.log("getChainJurisdiction(1): %s", vm.toString(RuleEngineComplianceProvider(COMP).getChainJurisdiction(ChainId.wrap(1))));
        console.log("getChainJurisdiction(2): %s", vm.toString(RuleEngineComplianceProvider(COMP).getChainJurisdiction(ChainId.wrap(2))));

        console.log("");
        console.log("=== Evaluate Transfer Intent ===");
        uint64 nonce = 999;
        bytes32 intentId = keccak256(abi.encode(Config.SOURCE_CHAIN, nonce, WALLET, WALLET, 100 ether));

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: WALLET,
            recipient: WALLET,
            senderIdentityHash: ID_HASH,
            recipientIdentityHash: ID_HASH,
            assetId: Config.ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(Config.SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(Config.DEST_CHAIN),
            amount: 100 ether,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        ProtocolTypes.ComplianceDecision memory d = RuleEngineComplianceProvider(COMP).evaluateTransferIntent(intent);
        console.log("Result: %d", uint8(d.result));
        console.log("DecisionHash: %s", vm.toString(d.decisionHash));
        console.log("PolicyVersion: %s", vm.toString(d.policyVersion));
    }
}
