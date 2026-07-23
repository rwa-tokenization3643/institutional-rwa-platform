// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {ICompliancePolicyProvider} from "../contracts/interfaces/ICompliancePolicyProvider.sol";
import {Config} from "./Config.sol";

interface ITIM {
    function getTransferIntent(bytes32) external view returns (ProtocolTypes.TransferIntent memory);
}

contract ComplianceDebug4 is Script {
    address constant COMP = 0x7a237aC13E0Df03Fae5d21025C2265C97ec436De;
    address constant TIM = 0x1b7b2e85bE973D875b4Ed5C20cF0ab01ECBB93Ab;

    function run() external {
        bytes32 intentId = 0x9e32dad71b0f24a99944853439ad099510077c8b99786526b1dc5c2fb4f2d28a;
        ProtocolTypes.TransferIntent memory intent = ITIM(TIM).getTransferIntent(intentId);

        console.log("=== Intent from TIM ===");
        console.log("intentId: %s", vm.toString(intent.intentId));
        console.log("action: %d", uint8(intent.action));
        console.log("sender: %s", vm.toString(intent.sender));
        console.log("recipient: %s", vm.toString(intent.recipient));
        console.log("assetId: %s", vm.toString(intent.assetId));
        console.log("amount: %s", vm.toString(intent.amount));
        console.log("nonce: %d", intent.nonce);
        console.log("expiresAt: %d", intent.expiresAt);
        console.log("block.timestamp: %d", block.timestamp);

        console.log("");
        console.log("=== evaluateTransferIntent with this intent ===");
        ProtocolTypes.ComplianceDecision memory d = ICompliancePolicyProvider(COMP).evaluateTransferIntent(intent);

        console.log("Result: %d", uint8(d.result));
        console.log("DecisionHash: %s", vm.toString(d.decisionHash));
    }
}
