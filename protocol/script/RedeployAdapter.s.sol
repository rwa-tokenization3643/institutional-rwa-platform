// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {IProtocolAccessManager} from "../contracts/access/IProtocolAccessManager.sol";
import {ITransferIntentManager} from "../contracts/interfaces/ITransferIntentManager.sol";
import {RuleEngineComplianceProvider} from "../contracts/compliance/RuleEngineComplianceProvider.sol";
import {ERC3643AssetAdapter} from "../contracts/adapters/ERC3643AssetAdapter.sol";
import {IAssetAdapter} from "../contracts/interfaces/IAssetAdapter.sol";
import {ICompliancePolicyProvider} from "../contracts/interfaces/ICompliancePolicyProvider.sol";
import {ITransportProvider} from "../contracts/interfaces/ITransportProvider.sol";
import {ISettlementCoordinator} from "../contracts/interfaces/ISettlementCoordinator.sol";
import {SettlementCoordinator} from "../contracts/core/SettlementCoordinator.sol";
import {CCIPTransportProvider, ICcipRouterClient} from "../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {Config} from "./Config.sol";

/// @notice Deploys a new ERC3643AssetAdapter, CCIPTransportProvider, and
///         SettlementCoordinator on Sepolia or Fuji. This replaces the old
///         adapter (which has an incompatible interface) and redeploys the
///         settlement stack pointing to the new adapter.
///
/// The script deploys 4 contracts in one broadcast block for deterministic
/// nonce-based address prediction:
///
///   nonce+0: ComplianceProvider
///   nonce+1: ERC3643AssetAdapter
///   nonce+2: CCIPTransportProvider  (needs predicted coordinator address)
///   nonce+3: SettlementCoordinator  (needs adapter, compliance, transport)
///
/// After deployment it:
///   - Grants BRIDGE_ROLE to the new adapter and coordinator
///   - Adds the new adapter as agent on the ERC-3643 token
///   - Configures the asset on the adapter
///   - Configures compliance settings
///   - Configures transport (chain selectors, remote receiver)
///   - Funds transport with native + LINK
///   - Approves LINK for CCIP Router
///
/// Run Sepolia first, then Fuji with REMOTE_TRANSPORT set to the new
/// Sepolia transport address:
///
///   # Sepolia
///   CHAIN=sepolia forge script script/RedeployAdapter.s.sol \
///     --rpc-url https://ethereum-sepolia.publicnode.com \
///     --broadcast --private-key $PK -vvv
///
///   # Fuji (set REMOTE_TRANSPORT to the new Sepolia transport address)
///   CHAIN=fuji REMOTE_TRANSPORT=<new-sepolia-transport> forge script \
///     script/RedeployAdapter.s.sol \
///     --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
///     --broadcast --private-key $PK -vvv
contract RedeployAdapter is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    bytes32 constant ASSET_ID = keccak256("RWA_TOKEN");
    address constant COMPLIANCE_OP = address(0xCAFE);

    // Sepolia
    address constant SEP_PAM = 0x4Adc11101De09D31bc2a931DC27774b0886d8d20;
    address constant SEP_TIM = 0x1b7b2e85bE973D875b4Ed5C20cF0ab01ECBB93Ab;
    address constant SEP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address constant SEP_TOKEN = 0x9DbEB1bC4eB090a653F19d166eDE17A5BFFc896d;
    address constant SEP_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;

    // Fuji
    address constant FUJ_PAM = 0x576FdA6522B2490e872356e3C8adf70D3361cdb9;
    address constant FUJ_TIM = 0x4e2E8f19a95BE64C0df6efEC0f60b3aE2876Ede7;
    address constant FUJ_ROUTER = 0xF694E193200268f9a4868e4Aa017A0118C9a8177;
    address constant FUJ_TOKEN = 0xf66ab3981E0479Be90866dBEB19a9662Eea8bba8;
    address constant FUJ_LINK = 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846;

    RuleEngineComplianceProvider compliance;
    ERC3643AssetAdapter adapter;
    CCIPTransportProvider transport;
    SettlementCoordinator coord;

    function run() external {
        string memory chain = vm.envString("CHAIN");

        address pam;
        address tim;
        address router;
        address token;
        ChainId localChainId;
        ChainId remoteChainId;
        uint64 localSelector;
        uint64 remoteSelector;
        address linkToken;
        uint256 nativeFund;

        if (keccak256(bytes(chain)) == keccak256(bytes("sepolia"))) {
            linkToken = SEP_LINK;
            nativeFund = 0.01 ether;
            pam = SEP_PAM;
            tim = SEP_TIM;
            router = SEP_ROUTER;
            token = SEP_TOKEN;
            localChainId = Config.SOURCE_CHAIN;
            remoteChainId = Config.DEST_CHAIN;
            localSelector = Config.SEPOLIA_CHAIN_SELECTOR;
            remoteSelector = Config.FUJI_CHAIN_SELECTOR;
        } else if (keccak256(bytes(chain)) == keccak256(bytes("fuji"))) {
            linkToken = FUJ_LINK;
            nativeFund = 0.1 ether;
            pam = FUJ_PAM;
            tim = FUJ_TIM;
            router = FUJ_ROUTER;
            token = FUJ_TOKEN;
            localChainId = Config.DEST_CHAIN;
            remoteChainId = Config.SOURCE_CHAIN;
            localSelector = Config.FUJI_CHAIN_SELECTOR;
            remoteSelector = Config.SEPOLIA_CHAIN_SELECTOR;
        } else {
            revert("Unknown chain (use 'sepolia' or 'fuji')");
        }

        console.log("=== RedeployAdapter: %s ===", chain);
        console.log("PAM:      %s", vm.toString(pam));
        console.log("TIM:      %s", vm.toString(tim));
        console.log("Router:   %s", vm.toString(router));
        console.log("Token:    %s", vm.toString(token));
        console.log("LocalId:  %s", vm.toString(ChainId.unwrap(localChainId)));
        console.log("RemoteId: %s", vm.toString(ChainId.unwrap(remoteChainId)));

        // ── Predict addresses ──
        // Order inside the single broadcast block:
        //   nonce+0: ComplianceProvider
        //   nonce+1: ERC3643AssetAdapter
        //   nonce+2: CCIPTransportProvider
        //   nonce+3: SettlementCoordinator
        uint256 nonce = vm.getNonce(msg.sender);
        address predictedAdapter = vm.computeCreateAddress(msg.sender, nonce + 1);
        address predictedTransport = vm.computeCreateAddress(msg.sender, nonce + 2);
        address predictedCoord = vm.computeCreateAddress(msg.sender, nonce + 3);
        console.log("\nNonce: %d", nonce);
        console.log("Predicted Adapter:    %s", vm.toString(predictedAdapter));
        console.log("Predicted Transport:  %s", vm.toString(predictedTransport));
        console.log("Predicted Coordinator: %s", vm.toString(predictedCoord));

        // ── Deploy all 4 in one broadcast block ──
        console.log("\n--- Deploying contracts ---");
        vm.startBroadcast();
        compliance = new RuleEngineComplianceProvider(IProtocolAccessManager(pam));
        console.log("Compliance deployed: %s", vm.toString(address(compliance)));

        adapter = new ERC3643AssetAdapter(IProtocolAccessManager(pam), localChainId);
        console.log("Adapter deployed:    %s", vm.toString(address(adapter)));

        transport = new CCIPTransportProvider(
            IProtocolAccessManager(pam),
            ICcipRouterClient(router),
            ISettlementCoordinator(predictedCoord),
            linkToken
        );
        console.log("Transport deployed:  %s", vm.toString(address(transport)));

        coord = new SettlementCoordinator(
            IProtocolAccessManager(pam),
            localChainId,
            ITransferIntentManager(tim),
            ICompliancePolicyProvider(address(compliance)),
            IAssetAdapter(address(adapter)),
            ITransportProvider(address(transport))
        );
        console.log("Coordinator deployed: %s", vm.toString(address(coord)));
        vm.stopBroadcast();

        if (address(adapter) != predictedAdapter) {
            console.log("*** WARNING: Adapter != prediction ***");
            console.log("  Predicted: %s", vm.toString(predictedAdapter));
            console.log("  Actual:    %s", vm.toString(address(adapter)));
        } else {
            console.log("Adapter matches prediction.");
        }
        if (address(coord) != predictedCoord) {
            console.log("*** WARNING: Coordinator != prediction ***");
            console.log("  Predicted: %s", vm.toString(predictedCoord));
            console.log("  Actual:    %s", vm.toString(address(coord)));
        } else {
            console.log("Coordinator matches prediction.");
        }

        // ── Grant roles on PAM ──
        bytes32 bridgeRole = IProtocolAccessManager(pam).BRIDGE_ROLE();
        bytes32 complianceRole = IProtocolAccessManager(pam).COMPLIANCE_ROLE();

        console.log("\n--- Granting roles on PAM ---");
        vm.startBroadcast();
        IProtocolAccessManager(pam).grantRole(bridgeRole, address(adapter));
        IProtocolAccessManager(pam).grantRole(bridgeRole, address(coord));
        IProtocolAccessManager(pam).grantRole(complianceRole, address(adapter));
        IProtocolAccessManager(pam).grantRole(complianceRole, COMPLIANCE_OP);
        vm.stopBroadcast();
        console.log("BRIDGE_ROLE     -> adapter");
        console.log("BRIDGE_ROLE     -> coordinator");
        console.log("COMPLIANCE_ROLE -> adapter");
        console.log("COMPLIANCE_ROLE -> %s", vm.toString(COMPLIANCE_OP));

        // ── Add adapter as agent on ERC-3643 token ──
        console.log("\n--- Adding adapter as agent on token ---");
        vm.startBroadcast();
        // Token interface: addAgent(address agent)
        (bool ok,) = token.call(abi.encodeWithSelector(0x84e79842, address(adapter)));
        vm.stopBroadcast();
        if (ok) {
            console.log("Adapter added as agent on token: %s", vm.toString(address(adapter)));
        } else {
            console.log("*** WARNING: addAgent failed ***");
        }

        // ── Configure asset on adapter ──
        console.log("\n--- Configuring asset on adapter ---");
        vm.startBroadcast();
        adapter.configureAsset(
            ASSET_ID,
            token,
            18,
            keccak256("BOND"),
            keccak256("BURN_MINT"),
            keccak256("T-REX:4.1.6")
        );
        vm.stopBroadcast();
        console.log("Asset configured: %s", vm.toString(ASSET_ID));

        // ── Configure compliance ──
        console.log("\n--- Configuring compliance ---");
        vm.startBroadcast();
        compliance.setAllowedAsset(ASSET_ID, true);
        compliance.setAllowedAction(ProtocolTypes.IntentAction.TRANSFER, true);
        compliance.setChainJurisdiction(localChainId, Config.JURISDICTION_US);
        compliance.setChainJurisdiction(remoteChainId, Config.JURISDICTION_EU);

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

        // ── Configure transport ──
        address remoteTransport = vm.envOr("REMOTE_TRANSPORT", address(0));
        console.log("\n--- Configuring transport ---");
        vm.startBroadcast();
        transport.setChainSelector(localChainId, localSelector);
        transport.setChainSelector(remoteChainId, remoteSelector);
        if (remoteTransport != address(0)) {
            transport.setAllowedSender(remoteChainId, remoteTransport, true);
            transport.setRemoteReceiver(remoteChainId, remoteTransport);
            console.log("Remote transport configured: %s", vm.toString(remoteTransport));
        } else {
            console.log("Skipping remote config (set REMOTE_TRANSPORT to enable).");
        }
        vm.stopBroadcast();

        // ── Fund transport (native + LINK) ──
        console.log("\n--- Funding transport ---");
        vm.startBroadcast();
        payable(address(transport)).transfer(nativeFund);
        vm.stopBroadcast();
        console.log("Transport funded with %s wei native.", vm.toString(nativeFund));

        if (linkToken != address(0)) {
            console.log("Transferring LINK to transport...");
            vm.startBroadcast();
            (bool linkOk,) = linkToken.call(
                abi.encodeWithSelector(0xa9059cbb, address(transport), 10 ether)
            );
            vm.stopBroadcast();
            if (linkOk) {
                console.log("LINK transferred: 10 ether");
            } else {
                console.log("*** LINK transfer FAILED ***");
            }

            console.log("Approving Router to spend transport LINK...");
            vm.startBroadcast();
            transport.approveRouterLink();
            vm.stopBroadcast();
            console.log("Router approved for LINK.");
        }

        // ── Summary ──
        console.log("\n========================================");
        console.log("  DEPLOYMENT COMPLETE: %s", chain);
        console.log("========================================");
        console.log("  New Adapter:      %s", vm.toString(address(adapter)));
        console.log("  New Compliance:   %s", vm.toString(address(compliance)));
        console.log("  New Transport:    %s", vm.toString(address(transport)));
        console.log("  New Coordinator:  %s", vm.toString(address(coord)));
        console.log("");
        console.log("  Next step: run the other chain with:");
        console.log("  REMOTE_TRANSPORT=%s", vm.toString(address(transport)));
        console.log("========================================");
    }
}
