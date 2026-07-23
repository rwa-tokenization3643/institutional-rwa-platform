// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {ICompliancePolicyProvider} from "../contracts/interfaces/ICompliancePolicyProvider.sol";
import {Config} from "./Config.sol";



contract TestCompliance is Script {
    function run() external view {
        address comp = 0x7a237aC13E0Df03Fae5d21025C2265C97ec436De;
        address wallet = 0x837171DCE4161927795c61524E92260b0BDaeB70;
        bytes32 idHash = keccak256(abi.encode(wallet));
        uint256 amount = 100 ether;
        bytes32 intentId = 0xbe8f67a9466f74239ad5961711bb87ab2d64134491b60fe4c6d15c3b9a11d732;

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: wallet,
            recipient: wallet,
            senderIdentityHash: idHash,
            recipientIdentityHash: idHash,
            assetId: Config.ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(Config.SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(Config.DEST_CHAIN),
            amount: amount,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: 5,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        ProtocolTypes.ComplianceDecision memory d = ICompliancePolicyProvider(comp).evaluateTransferIntent(intent);
        console.log("Result: %d", uint8(d.result));
        console.log("DecisionHash: %s", vm.toString(d.decisionHash));
        console.log("PolicyVersion: %s", vm.toString(d.policyVersion));
    }
}
