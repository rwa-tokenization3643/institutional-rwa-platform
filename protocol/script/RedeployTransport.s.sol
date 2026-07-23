// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {IProtocolAccessManager} from "../contracts/access/IProtocolAccessManager.sol";
import {ProtocolAccessManager} from "../contracts/access/ProtocolAccessManager.sol";
import {TransferIntentManager} from "../contracts/core/TransferIntentManager.sol";
import {ITransferIntentManager} from "../contracts/interfaces/ITransferIntentManager.sol";
import {RuleEngineComplianceProvider} from "../contracts/compliance/RuleEngineComplianceProvider.sol";
import {ERC3643AssetAdapter} from "../contracts/adapters/ERC3643AssetAdapter.sol";
import {IAssetAdapter} from "../contracts/interfaces/IAssetAdapter.sol";
import {ICompliancePolicyProvider} from "../contracts/interfaces/ICompliancePolicyProvider.sol";
import {ITransportProvider} from "../contracts/interfaces/ITransportProvider.sol";
import {SettlementCoordinator} from "../contracts/core/SettlementCoordinator.sol";
import {ISettlementCoordinator} from "../contracts/interfaces/ISettlementCoordinator.sol";
import {CCIPTransportProvider, ICcipRouterClient} from "../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {Config} from "./Config.sol";

interface IToken {
    function balanceOf(address) external view returns (uint256);
}

contract RedeployTransport is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;

    // Sepolia addresses
    address constant SEP_PAM = 0x4Adc11101De09D31bc2a931DC27774b0886d8d20;
    address constant SEP_TIM = 0x1b7b2e85bE973D875b4Ed5C20cF0ab01ECBB93Ab;
    address constant SEP_COMPLIANCE = 0x7a237aC13E0Df03Fae5d21025C2265C97ec436De;
    address constant SEP_ADAPTER = 0x7eFCe77A1c32060596Af60a6556375714f154485;
    address constant SEP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant SEP_TOKEN = 0x9DbEB1bC4eB090a653F19d166eDE17A5BFFc896d;

    // Fuji addresses
    address constant FUJ_PAM = 0x576FdA6522B2490e872356e3C8adf70D3361cdb9;
    address constant FUJ_TIM = 0x4e2E8f19a95BE64C0df6efEC0f60b3aE2876Ede7;
    address constant FUJ_COMPLIANCE = 0xdBA28eC39075d67a56bbF0B4ed3fc6a11f9370e5;
    address constant FUJ_ADAPTER = 0xDe9487e81d1d7A19F40ae2671fDA2e8C251FbD31;
    address constant FUJ_ROUTER = 0xF694E193200268f9a4868e4Aa017A0118C9a8177;
    address constant FUJ_TOKEN = 0xf66ab3981E0479Be90866dBEB19a9662Eea8bba8;

    // New deployments
    CCIPTransportProvider transport;
    SettlementCoordinator coord;

    function run() external {
        string memory chain = vm.envString("CHAIN");

        address pam;
        address tim;
        address compliance;
        address adapter;
        address router;
        address token;
        ChainId localChainId;
        ChainId remoteChainId;
        uint64 localSelector;
        uint64 remoteSelector;
        address remoteTransport;

        if (keccak256(bytes(chain)) == keccak256(bytes("sepolia"))) {
            pam = SEP_PAM;
            tim = SEP_TIM;
            compliance = SEP_COMPLIANCE;
            adapter = SEP_ADAPTER;
            router = SEP_ROUTER;
            token = SEP_TOKEN;
            localChainId = Config.SOURCE_CHAIN;
            remoteChainId = Config.DEST_CHAIN;
            localSelector = Config.SEPOLIA_CHAIN_SELECTOR;
            remoteSelector = Config.FUJI_CHAIN_SELECTOR;
            remoteTransport = vm.envOr("FUJI_TRANSPORT", address(0));
        } else if (keccak256(bytes(chain)) == keccak256(bytes("fuji"))) {
            pam = FUJ_PAM;
            tim = FUJ_TIM;
            compliance = FUJ_COMPLIANCE;
            adapter = FUJ_ADAPTER;
            router = FUJ_ROUTER;
            token = FUJ_TOKEN;
            localChainId = Config.DEST_CHAIN;
            remoteChainId = Config.SOURCE_CHAIN;
            localSelector = Config.FUJI_CHAIN_SELECTOR;
            remoteSelector = Config.SEPOLIA_CHAIN_SELECTOR;
            remoteTransport = vm.envOr("SEPOLIA_TRANSPORT", address(0));
        } else {
            revert(string.concat("Unknown chain: ", chain));
        }

        console.log("=== %s redeploy ===", chain);
        console.log("PAM:         %s", vm.toString(pam));
        console.log("TIM:         %s", vm.toString(tim));
        console.log("Compliance:  %s", vm.toString(compliance));
        console.log("Adapter:     %s", vm.toString(adapter));
        console.log("Router:      %s", vm.toString(router));
        console.log("Token:       %s", vm.toString(token));
        console.log("LocalChainId: %s", vm.toString(ChainId.unwrap(localChainId)));
        console.log("RemoteChainId: %s", vm.toString(ChainId.unwrap(remoteChainId)));
        console.log("RemoteTransport: %s", vm.toString(remoteTransport));

        // Step 1: Compute predicted coordinator address (nonce+1)
        uint256 nonce = vm.getNonce(msg.sender);
        address predictedCoord = vm.computeCreateAddress(msg.sender, nonce + 1);
        console.log("Predicting coordinator at nonce %d: %s", nonce + 1, vm.toString(predictedCoord));

        // Step 2: Deploy transport (nonce)
        console.log("Deploying transport...");
        vm.startBroadcast();
        transport = new CCIPTransportProvider(
            IProtocolAccessManager(pam),
            ICcipRouterClient(router),
            ISettlementCoordinator(predictedCoord),
            address(0)
        );
        vm.stopBroadcast();
        console.log("Transport:   %s", vm.toString(address(transport)));

        // Step 3: Deploy coordinator (nonce+1)
        console.log("Deploying coordinator...");
        vm.startBroadcast();
        coord = new SettlementCoordinator(
            IProtocolAccessManager(pam),
            localChainId,
            ITransferIntentManager(tim),
            ICompliancePolicyProvider(compliance),
            IAssetAdapter(adapter),
            ITransportProvider(address(transport))
        );
        vm.stopBroadcast();
        console.log("Coordinator: %s", vm.toString(address(coord)));

        // Step 4: Grant BRIDGE_ROLE to new coordinator
        console.log("Granting BRIDGE_ROLE to new coordinator...");
        bytes32 bridgeRole = IProtocolAccessManager(pam).BRIDGE_ROLE();
        vm.startBroadcast();
        IProtocolAccessManager(pam).grantRole(bridgeRole, address(coord));
        vm.stopBroadcast();

        // Step 5: Configure transport (chain selectors always)
        console.log("Configuring transport...");
        vm.startBroadcast();
        transport.setChainSelector(localChainId, localSelector);
        transport.setChainSelector(remoteChainId, remoteSelector);
        if (remoteTransport != address(0)) {
            transport.setAllowedSender(remoteChainId, remoteTransport, true);
            transport.setRemoteReceiver(remoteChainId, remoteTransport);
            console.log("Remote transport configured");
        } else {
            console.log("Skipping remote config (no remote transport address yet)");
        }
        vm.stopBroadcast();

        // Step 6: Set investor classification
        console.log("Classifying wallet...");
        bytes32 identityHash = keccak256(abi.encode(WALLET));
        vm.startBroadcast();
        RuleEngineComplianceProvider(compliance).setInvestorClassification(
            identityHash,
            RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL
        );
        vm.stopBroadcast();

        console.log("");
        console.log("=== Summary ===");
        console.log("New Transport:   %s", vm.toString(address(transport)));
        console.log("New Coordinator: %s", vm.toString(address(coord)));

        uint256 bal = IToken(token).balanceOf(WALLET);
        console.log("RWA balance: %d", bal / 1e18);
    }
}
