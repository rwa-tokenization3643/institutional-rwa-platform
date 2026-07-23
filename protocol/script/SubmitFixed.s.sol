// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {Config} from "./Config.sol";

interface ISettlement {
    function submitTransfer(ProtocolTypes.TransferIntent calldata intent) external returns (bytes32);
}

contract SubmitFixed is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    address constant COORD = 0x8c86bFE389bC7E9EaD7930A1976ca78b085dAA0C;
    address constant TOKEN = 0x9DbEB1bC4eB090a653F19d166eDE17A5BFFc896d;

    function run() external {
        uint256 amount = 100 ether;
        uint64 nonce = uint64(block.timestamp);
        bytes32 intentId = keccak256(abi.encode(Config.SOURCE_CHAIN, nonce, WALLET, WALLET, amount));

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: WALLET,
            recipient: WALLET,
            senderIdentityHash: keccak256(abi.encode(WALLET)),
            recipientIdentityHash: keccak256(abi.encode(WALLET)),
            assetId: Config.ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(Config.SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(Config.DEST_CHAIN),
            amount: amount,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        console.log("Submitting 100 RWA Sepolia -> Fuji");
        console.log("Coordinator: %s", vm.toString(COORD));
        console.log("intentId: %s", vm.toString(intentId));
        console.log("Nonce: %d", nonce);

        vm.startBroadcast();
        bytes32 result = ISettlement(COORD).submitTransfer(intent);
        vm.stopBroadcast();

        console.log("submitTransfer returned: %s", vm.toString(result));
        console.log("Transfer submitted!");
    }
}
