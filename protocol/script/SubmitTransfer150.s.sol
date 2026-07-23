// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {ISettlementCoordinator} from "../contracts/interfaces/ISettlementCoordinator.sol";
import {Config} from "./Config.sol";

/// @notice Submits a 150-token transfer from Sepolia to Fuji.
///
///   CHAIN=sepolia forge script script/SubmitTransfer150.s.sol \
///     --rpc-url https://ethereum-sepolia.publicnode.com \
///     --broadcast --private-key $PK -vvv
contract SubmitTransfer150 is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    address constant SRC_COORD = 0x02fC65e85d0c3940D2Af62a836420F97Ef520185;
    bytes32 constant ASSET_ID = keccak256("RWA_TOKEN");

    function run() external {
        uint64 nonce = uint64(block.timestamp);
        bytes32 intentId = keccak256(
            abi.encode(ChainId.unwrap(Config.SOURCE_CHAIN), nonce, WALLET, WALLET, 150 ether)
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
            amount: 150 ether,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        console.log("=== Submitting Transfer ===");
        console.log("  IntentId:  %s", vm.toString(intentId));
        console.log("  Amount:    150 tokens");
        console.log("  Sender:    %s", vm.toString(WALLET));
        console.log("  Recipient: %s", vm.toString(WALLET));
        console.log("  SrcChain:  Sepolia (1)");
        console.log("  DstChain:  Fuji (2)");

        vm.startBroadcast();
        ISettlementCoordinator(SRC_COORD).submitTransfer(intent);
        vm.stopBroadcast();

        console.log("\nTransfer submitted!");
        console.log("CCIP message delivery takes ~2-5 minutes.");
    }
}
