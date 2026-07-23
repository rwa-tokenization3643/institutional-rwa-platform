// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {RuleEngineComplianceProvider} from "../contracts/compliance/RuleEngineComplianceProvider.sol";
import {ERC3643AssetAdapter} from "../contracts/adapters/ERC3643AssetAdapter.sol";
import {CCIPTransportProvider} from "../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {Config} from "./Config.sol";

/// @notice Configures and funds the Fuji deployment that was partially
///         completed (contracts deployed but asset/compliance/transport
///         not configured, transport not funded).
///
///   CHAIN=fuji REMOTE_TRANSPORT=0x40BBD60d3952f9C5C0654cbA6bb9f0c99fCb3C4a \
///     forge script script/ConfigureFuji.s.sol \
///     --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
///     --broadcast --private-key $PK -vvv
contract ConfigureFuji is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    bytes32 constant ASSET_ID = keccak256("RWA_TOKEN");

    // Fuji deployed addresses (from RedeployAdapter output)
    address constant FUJ_ADAPTER = 0x9d9bF08a84734Aea5099690B7BbF5e9bfC444cef;
    address constant FUJ_COMPLIANCE = 0x09F421164AC6b9826169BaaDA503bEe4D48BB35e;
    address constant FUJ_TRANSPORT = 0x3562A2D2Db30521abEA89331D4886fa6A0cd2BC0;
    address constant FUJ_TOKEN = 0xf66ab3981E0479Be90866dBEB19a9662Eea8bba8;

    function run() external {
        console.log("=== Configuring Fuji ===");

        RuleEngineComplianceProvider compliance = RuleEngineComplianceProvider(FUJ_COMPLIANCE);
        ERC3643AssetAdapter adapter = ERC3643AssetAdapter(FUJ_ADAPTER);
        CCIPTransportProvider transport = CCIPTransportProvider(payable(FUJ_TRANSPORT));

        // ── Configure asset on adapter ──
        console.log("\n--- Configuring asset on adapter ---");
        vm.startBroadcast();
        adapter.configureAsset(
            ASSET_ID,
            FUJ_TOKEN,
            18,
            keccak256("BOND"),
            keccak256("BURN_MINT"),
            keccak256("T-REX:4.1.6")
        );
        vm.stopBroadcast();
        console.log("Asset configured.");

        // ── Configure compliance ──
        console.log("\n--- Configuring compliance ---");
        vm.startBroadcast();
        compliance.setAllowedAsset(ASSET_ID, true);
        compliance.setAllowedAction(ProtocolTypes.IntentAction.TRANSFER, true);
        compliance.setChainJurisdiction(Config.DEST_CHAIN, Config.JURISDICTION_US);
        compliance.setChainJurisdiction(Config.SOURCE_CHAIN, Config.JURISDICTION_EU);

        bytes32 walletHash = keccak256(abi.encode(WALLET));
        compliance.setInvestorClassification(
            walletHash,
            RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL
        );
        compliance.setMinimumClassification(
            RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL
        );
        compliance.setMaxTransferAmount(ASSET_ID, 100_000 ether);
        compliance.setMaxHolding(ASSET_ID, 1_000_000 ether);
        compliance.setPolicyVersion(keccak256("POLICY:v1"));
        vm.stopBroadcast();
        console.log("Compliance configured.");

        // ── Fund transport ──
        address remoteTransport = vm.envOr("REMOTE_TRANSPORT", address(0));
        console.log("\n--- Configuring transport ---");
        vm.startBroadcast();
        transport.setChainSelector(Config.DEST_CHAIN, Config.FUJI_CHAIN_SELECTOR);
        transport.setChainSelector(Config.SOURCE_CHAIN, Config.SEPOLIA_CHAIN_SELECTOR);
        if (remoteTransport != address(0)) {
            transport.setAllowedSender(Config.SOURCE_CHAIN, remoteTransport, true);
            transport.setRemoteReceiver(Config.SOURCE_CHAIN, remoteTransport);
            console.log("Remote transport configured: %s", vm.toString(remoteTransport));
        }
        vm.stopBroadcast();

        // ── Fund transport with native + LINK ──
        console.log("\n--- Funding transport ---");
        vm.startBroadcast();
        payable(FUJ_TRANSPORT).transfer(0.1 ether);
        vm.stopBroadcast();
        console.log("Transport funded with 0.1 AVAX.");

        // Transfer LINK
        address linkToken = Config.FUJI_LINK;
        console.log("Transferring LINK to transport...");
        vm.startBroadcast();
        (bool ok,) = linkToken.call(
            abi.encodeWithSelector(0xa9059cbb, FUJ_TRANSPORT, 10 ether)
        );
        vm.stopBroadcast();
        if (ok) {
            console.log("LINK transferred: 10 ether");
        } else {
            console.log("*** LINK transfer FAILED ***");
        }

        // Approve router for LINK
        console.log("Approving Router to spend transport LINK...");
        vm.startBroadcast();
        transport.approveRouterLink();
        vm.stopBroadcast();
        console.log("Router approved for LINK.");

        console.log("\n=== Fuji configuration complete ===");
    }
}
