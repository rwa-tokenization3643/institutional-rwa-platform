// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {Config} from "./Config.sol";

interface IComplianceExt {
    function evaluateTransferIntent(ProtocolTypes.TransferIntent calldata) external view returns (ProtocolTypes.ComplianceDecision memory);
    function evaluateWithReasons(ProtocolTypes.TransferIntent calldata) external view returns (ProtocolTypes.ComplianceDecision memory, uint8[] memory);
    function getInvestorClassification(bytes32) external view returns (uint8);
    function isAssetAllowed(bytes32) external view returns (bool);
    function getMinimumClassification() external view returns (uint8);
    function getMaxTransferAmount(bytes32) external view returns (uint256);
    function getMaxHolding(bytes32) external view returns (uint256);
    function getChainJurisdiction(ChainId) external view returns (bytes32);
    function isActionAllowed(ProtocolTypes.IntentAction) external view returns (bool);
    function isJurisdictionBlocked(bytes32) external view returns (bool);
    function isJurisdictionAllowed(bytes32) external view returns (bool);
}

contract ComplianceDebug3 is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    address constant COMP = 0x7a237aC13E0Df03Fae5d21025C2265C97ec436De;
    bytes32 constant ID_HASH = 0xbcdb6cfabeedf4cb75ce3843392e397abf95b450b1712991ca6db65da2a9cf8c;

    function run() external {
        console.log("ASSET_ID: %s", vm.toString(Config.ASSET_ID));
        console.log("ID_HASH:  %s", vm.toString(ID_HASH));

        console.log("");
        console.log("=== Compliance Provider State ===");
        console.log("isAssetAllowed(ASSET_ID): %s", IComplianceExt(COMP).isAssetAllowed(Config.ASSET_ID));
        console.log("getInvestorClassification: %d", IComplianceExt(COMP).getInvestorClassification(ID_HASH));
        console.log("getMinimumClassification: %d", IComplianceExt(COMP).getMinimumClassification());
        console.log("getMaxTransferAmount: %s", vm.toString(IComplianceExt(COMP).getMaxTransferAmount(Config.ASSET_ID)));
        console.log("getMaxHolding: %s", vm.toString(IComplianceExt(COMP).getMaxHolding(Config.ASSET_ID)));
        console.log("getChainJurisdiction(1): %s", vm.toString(IComplianceExt(COMP).getChainJurisdiction(ChainId.wrap(1))));
        console.log("getChainJurisdiction(2): %s", vm.toString(IComplianceExt(COMP).getChainJurisdiction(ChainId.wrap(2))));
        console.log("isActionAllowed(TRANSFER): %s", IComplianceExt(COMP).isActionAllowed(ProtocolTypes.IntentAction.TRANSFER));

        console.log("");
        console.log("=== Evaluate With Reasons ===");
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

        (ProtocolTypes.ComplianceDecision memory d, uint8[] memory reasons) = IComplianceExt(COMP).evaluateWithReasons(intent);
        console.log("Result: %d", uint8(d.result));
        for (uint i = 0; i < reasons.length; i++) {
            console.log("  Reason[%d]: %d", i, reasons[i]);
        }
    }
}
