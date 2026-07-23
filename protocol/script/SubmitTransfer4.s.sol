// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {Config} from "./Config.sol";

interface ISettlement {
    function submitTransfer(ProtocolTypes.TransferIntent calldata intent) external returns (bytes32);
}

contract SubmitTransfer4 is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    address constant COORD = 0xB6C8c7c236fA9569Dc4DC64c3E081BA0089D8beB;

    function run() external {
        bytes32 idHash = keccak256(abi.encode(WALLET));
        uint256 amount = 100 ether;
        uint64 nonce = 8;
        bytes32 intentId = keccak256(abi.encode(Config.SOURCE_CHAIN, nonce, WALLET, WALLET, amount));

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: WALLET,
            recipient: WALLET,
            senderIdentityHash: idHash,
            recipientIdentityHash: idHash,
            assetId: Config.ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(Config.SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(Config.DEST_CHAIN),
            amount: amount,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 48 hours)
        });

        console.log("Submitting transfer...");
        console.log("nonce=%d intentId=%s", nonce, vm.toString(intentId));

        vm.startBroadcast();
        bytes32 result = ISettlement(COORD).submitTransfer(intent);
        vm.stopBroadcast();

        console.log("Done. result=%s", vm.toString(result));
    }
}
