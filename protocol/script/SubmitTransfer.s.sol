// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {ISettlementCoordinator} from "../contracts/interfaces/ISettlementCoordinator.sol";
import {Config} from "./Config.sol";

contract SubmitTransfer is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    address constant SRC_COORD = 0x31a4a867eEcD2504E7fCd8589746bfd1faf5A560;
    bytes32 constant ASSET_ID = keccak256("RWA_TOKEN");

    function run() external {
        uint64 nonce = uint64(block.timestamp);
        bytes32 intentId = keccak256(
            abi.encode(ChainId.unwrap(Config.SOURCE_CHAIN), nonce, WALLET, WALLET, Config.TRANSFER_AMOUNT)
        );

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: WALLET,
            recipient: WALLET,
            senderIdentityHash: keccak256(abi.encode(WALLET)),
            recipientIdentityHash: keccak256(abi.encode(WALLET)),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(Config.SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(Config.DEST_CHAIN),
            amount: 1 ether,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        console.log("Submitting transfer...");
        console.log("  IntentId: %s", vm.toString(intentId));
        console.log("  Amount:   1 token");
        console.log("  Sender:   %s", vm.toString(WALLET));
        console.log("  Recipient: %s", vm.toString(WALLET));

        vm.startBroadcast();
        ISettlementCoordinator(SRC_COORD).submitTransfer(intent);
        vm.stopBroadcast();

        console.log("Transfer submitted!");
        console.log("\nNow wait for CCIP message delivery to Fuji (~2-5 mins)");
    }
}
