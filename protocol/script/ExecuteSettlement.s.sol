// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {IProtocolAccessManager} from "../contracts/access/IProtocolAccessManager.sol";
import {ISettlementCoordinator} from "../contracts/interfaces/ISettlementCoordinator.sol";
import {Config} from "./Config.sol";

// =============================================================================
// Minimal interface for CCIPTransportProvider interactions
// =============================================================================

interface ITransportConfig {
    function setChainSelector(ChainId chainId, uint64 selector) external;
    function setAllowedSender(ChainId chainId, address sender, bool allowed) external;
    function setRemoteReceiver(ChainId chainId, address receiver) external;
    function sendMessage(ChainId destinationChain, ProtocolTypes.TransportMessage calldata message) external payable returns (bytes32);
}

interface ISettlementConfig {
    function submitTransfer(ProtocolTypes.TransferIntent calldata intent) external;
}

// =============================================================================
// ExecuteSettlement - Configure cross-chain and execute settlement
// =============================================================================
//
// Reads deployed addresses from environment variables and:
//   1. Configures cross-chain selectors and allowed senders on both chains
//   2. Executes the first phase of settlement (submit + send CCIP message)
//
// Required environment variables:
//   SRC_SETTLEMENT       - Sepolia SettlementCoordinator address
//   SRC_TRANSPORT        - Sepolia CCIPTransportProvider address
//   DST_TRANSPORT        - Fuji CCIPTransportProvider address
//
// =============================================================================

contract ExecuteSettlement is Script {

    address srcSettlement;
    address srcTransport;
    address dstTransport;

    function run() external {
        srcSettlement = vm.envAddress("SRC_SETTLEMENT");
        srcTransport = vm.envAddress("SRC_TRANSPORT");
        dstTransport = vm.envAddress("DST_TRANSPORT");

        console.log("+============================================================+");
        console.log("|  Cross-Chain Settlement Execution                          |");
        console.log("+============================================================+");
        console.log("");
        console.log("  Sepolia SettlementCoordinator: %s", vm.toString(srcSettlement));
        console.log("  Sepolia TransportProvider:     %s", vm.toString(srcTransport));
        console.log("  Fuji TransportProvider:        %s", vm.toString(dstTransport));
        console.log("");

        // -- Phase 1: Configure cross-chain settings --
        _printPhaseHeader("PHASE 1", "Configure Cross-Chain Transport");
        _configureTransport();

        // -- Phase 2: Execute settlement --
        _printPhaseHeader("PHASE 2", "Execute Settlement (Sepolia -> Fuji)");
        _executeSettlement();

        // -- Summary --
        _printSummary();
    }

    // =========================================================================
    // Phase 1: Configure Cross-Chain Transport
    // =========================================================================

    function _configureTransport() internal {
        console.log("-- Configuring Transport Providers --");

        // -- Source chain (Sepolia) --
        vm.startPrank(Config.BRIDGE_OP);

        ITransportConfig(srcTransport).setChainSelector(
            Config.SOURCE_CHAIN, Config.SEPOLIA_CHAIN_SELECTOR
        );
        ITransportConfig(srcTransport).setChainSelector(
            Config.DEST_CHAIN, Config.FUJI_CHAIN_SELECTOR
        );
        ITransportConfig(srcTransport).setAllowedSender(
            Config.DEST_CHAIN, dstTransport, true
        );
        ITransportConfig(srcTransport).setRemoteReceiver(
            Config.DEST_CHAIN, dstTransport
        );

        vm.stopPrank();
        console.log("  Sepolia transport configured");

        // -- Destination chain (Fuji) --
        vm.startPrank(Config.BRIDGE_OP);

        ITransportConfig(dstTransport).setChainSelector(
            Config.DEST_CHAIN, Config.FUJI_CHAIN_SELECTOR
        );
        ITransportConfig(dstTransport).setChainSelector(
            Config.SOURCE_CHAIN, Config.SEPOLIA_CHAIN_SELECTOR
        );
        ITransportConfig(dstTransport).setAllowedSender(
            Config.SOURCE_CHAIN, srcTransport, true
        );
        ITransportConfig(dstTransport).setRemoteReceiver(
            Config.SOURCE_CHAIN, srcTransport
        );

        vm.stopPrank();
        console.log("  Fuji transport configured");
        console.log("");
    }

    // =========================================================================
    // Phase 2: Execute Settlement
    // =========================================================================

    function _executeSettlement() internal {
        console.log("-- Executing Settlement --");

        uint64 nonce = 1;
        bytes32 intentId = keccak256(
            abi.encode(Config.SOURCE_CHAIN, nonce, Config.INVESTOR_A, Config.INVESTOR_B, Config.TRANSFER_AMOUNT)
        );

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: Config.INVESTOR_A,
            recipient: Config.INVESTOR_B,
            senderIdentityHash: keccak256(abi.encode(Config.INVESTOR_A)),
            recipientIdentityHash: keccak256(abi.encode(Config.INVESTOR_B)),
            assetId: Config.ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(Config.SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(Config.DEST_CHAIN),
            amount: Config.TRANSFER_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        console.log("  IntentId: %s", vm.toString(intentId));
        console.log("  Amount:   %d RWA tokens", Config.TRANSFER_AMOUNT / 1e18);
        console.log("");

        // -- Phase 1: Submit Transfer on Source --
        _printPhaseStep("1", "Submit Transfer (Source)");
        vm.prank(Config.INVESTOR_A);
        ISettlementConfig(payable(srcSettlement)).submitTransfer(intent);
        console.log("  [OK] Transfer submitted on Sepolia");
        console.log("");

        // -- Phase 2: Send Validation Request via CCIP --
        _printPhaseStep("2", "Send Validation Request (Sepolia -> Fuji)");
        bytes memory validationRequestPayload = abi.encode(intent);
        vm.prank(Config.BRIDGE_OP);
        bytes32 msgId1 = ITransportConfig(payable(srcTransport)).sendMessage(
            Config.DEST_CHAIN,
            ProtocolTypes.TransportMessage({
                messageVersion: 1,
                transportId: keccak256("CCIP"),
                messageType: ProtocolTypes.MessageType.TRANSFER_INTENT,
                phase: ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
                messageId: bytes32(0),
                intentId: intentId,
                sourceChainId: ChainId.unwrap(Config.SOURCE_CHAIN),
                destinationChainId: ChainId.unwrap(Config.DEST_CHAIN),
                expiresAt: intent.expiresAt,
                sender: address(0),
                recipient: address(0),
                payloadHash: keccak256(validationRequestPayload),
                payload: validationRequestPayload
            })
        );
        console.log("  [OK] Validation request sent via CCIP");
        console.log("  CCIP MessageId: %s", vm.toString(msgId1));
        console.log("");

        console.log("================================================================");
        console.log("  CROSS-CHAIN MESSAGE SENT SUCCESSFULLY");
        console.log("================================================================");
        console.log("");
        console.log("  Cross-chain delivery typically takes 15-30 minutes.");
        console.log("  After delivery, the settlement will proceed automatically.");
        console.log("");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _printPhaseHeader(string memory phase, string memory title) internal pure {
        console.log("+============================================================+");
        console.log("|  %s: %s", phase, title);
        console.log("+============================================================+");
        console.log("");
    }

    function _printPhaseStep(string memory step, string memory title) internal pure {
        console.log("  -- Step %s: %s --", step, title);
    }

    function _printSummary() internal {
        console.log("+============================================================+");
        console.log("|                    SETTLEMENT SUMMARY                      |");
        console.log("+============================================================+");
        console.log("");
        console.log("  Cross-chain message sent from Sepolia to Fuji.");
        console.log("  CCIP delivery typically takes 15-30 minutes.");
        console.log("");
        console.log("  Monitor on explorers:");
        console.log("    Sepolia: https://sepolia.etherscan.io/address/%s", vm.toString(srcTransport));
        console.log("    Fuji:    https://testnet.snowtrace.io/address/%s", vm.toString(dstTransport));
        console.log("");
    }
}
