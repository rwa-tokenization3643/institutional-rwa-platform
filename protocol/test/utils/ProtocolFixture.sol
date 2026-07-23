// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ProtocolAccessManager} from "../../contracts/access/ProtocolAccessManager.sol";
import {IProtocolAccessManager} from "../../contracts/access/IProtocolAccessManager.sol";
import {ChainId} from "../../contracts/common/ProtocolTypes.sol";
import {ProtocolTypes} from "../../contracts/common/ProtocolTypes.sol";
import {ITransferIntentManager} from "../../contracts/interfaces/ITransferIntentManager.sol";
import {TransferIntentManager} from "../../contracts/core/TransferIntentManager.sol";
import {ICompliancePolicyProvider} from "../../contracts/interfaces/ICompliancePolicyProvider.sol";
import {RuleEngineComplianceProvider} from "../../contracts/compliance/RuleEngineComplianceProvider.sol";
import {IAssetAdapter} from "../../contracts/interfaces/IAssetAdapter.sol";
import {ERC3643AssetAdapter} from "../../contracts/adapters/ERC3643AssetAdapter.sol";
import {ISettlementCoordinator} from "../../contracts/interfaces/ISettlementCoordinator.sol";
import {SettlementCoordinator} from "../../contracts/core/SettlementCoordinator.sol";
import {ITransportProvider} from "../../contracts/interfaces/ITransportProvider.sol";
import {CCIPTransportProvider, ICcipRouterClient} from "../../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {MockERC3643Token} from "../mocks/MockERC3643Token.sol";
import {MockCCIPRouter} from "../mocks/MockCCIPRouter.sol";
import {IERC3643TokenMinimal} from "../mocks/IERC3643TokenMinimal.sol";
import {ERC3643Deployer, ERC3643Stack, ITIR} from "./ERC3643Deployer.sol";

/// @title ProtocolFixture
/// @notice Returns a fully deployed protocol stack with all contracts wired
///         together and roles granted. Use `deployProtocol()` to create an
///         operational instance on any chain.
struct ProtocolFixture {
    ProtocolAccessManager accessManager;
    SettlementCoordinator settlementCoordinator;
    TransferIntentManager transferIntentManager;
    RuleEngineComplianceProvider complianceProvider;
    ERC3643AssetAdapter assetAdapter;
    CCIPTransportProvider transportProvider;
    IERC3643TokenMinimal token;
    MockCCIPRouter router;
    ChainId chainId;
    address admin;
    address bridgeOp;
    address complianceOp;
}

/// @title ProtocolFixtureBase
/// @notice Inherit this contract to gain access to `deployProtocol()` and
///         the standard configuration helpers.
contract ProtocolFixtureBase is ERC3643Deployer {
    /// @notice Deploys a complete protocol stack using the mock ERC-3643 token.
    ///         Tests that do NOT interact with ERC-3643 identity or compliance
    ///         enforcement (e.g. conformance tests focused on protocol state
    ///         machine) should use this function for speed and simplicity.
    /// @param  admin         Address that receives DEFAULT_ADMIN_ROLE.
    /// @param  chainId       This chain's protocol-level identifier.
    /// @param  ccipSelector  CCIP chain selector for this chain.
    /// @param  bridgeOp      Address that receives BRIDGE_ROLE.
    /// @param  complianceOp  Address that receives COMPLIANCE_ROLE.
    /// @return fixture       Fully deployed and initialized protocol stack.
    function deployProtocol(
        address admin,
        ChainId chainId,
        uint64 ccipSelector,
        address bridgeOp,
        address complianceOp
    ) internal returns (ProtocolFixture memory fixture) {
        uint256 nonceStart = vm.getNonce(address(this));

        // ── 1. ProtocolAccessManager (offset +0) ──
        fixture.accessManager = new ProtocolAccessManager(admin);

        // ── 2. TransferIntentManager (offset +1) ──
        fixture.transferIntentManager = new TransferIntentManager(
            IProtocolAccessManager(address(fixture.accessManager))
        );

        // ── 3. RuleEngineComplianceProvider (offset +2) ──
        fixture.complianceProvider = new RuleEngineComplianceProvider(
            IProtocolAccessManager(address(fixture.accessManager))
        );

        // ── 4. ERC3643AssetAdapter (offset +3) ──
        fixture.assetAdapter = new ERC3643AssetAdapter(
            IProtocolAccessManager(address(fixture.accessManager)),
            chainId
        );

        // ── 5. MockERC3643Token (offset +4) ──
        fixture.token = IERC3643TokenMinimal(address(new MockERC3643Token()));

        // ── 6. MockCCIPRouter (offset +5) ──
        fixture.router = new MockCCIPRouter();

        // ── 7. Resolve circular dependency ──
        // SettlementCoordinator (offset +7) must be pre-computed before
        // deploying CCIPTransportProvider (offset +6), because each needs
        // the other's address in its constructor.
        address predictedCoordinator = vm.computeCreateAddress(
            address(this), nonceStart + 7
        );

        // ── 8. CCIPTransportProvider (offset +6) ──
        fixture.transportProvider = new CCIPTransportProvider(
            IProtocolAccessManager(address(fixture.accessManager)),
            ICcipRouterClient(address(fixture.router)),
            ISettlementCoordinator(predictedCoordinator),
            address(0)
        );

        // ── 9. SettlementCoordinator (offset +7) ──
        fixture.settlementCoordinator = new SettlementCoordinator(
            IProtocolAccessManager(address(fixture.accessManager)),
            chainId,
            ITransferIntentManager(address(fixture.transferIntentManager)),
            ICompliancePolicyProvider(address(fixture.complianceProvider)),
            IAssetAdapter(address(fixture.assetAdapter)),
            ITransportProvider(address(fixture.transportProvider))
        );

        // ── 10. Store metadata ──
        fixture.chainId = chainId;
        fixture.admin = admin;
        fixture.bridgeOp = bridgeOp;
        fixture.complianceOp = complianceOp;

        // ── 11. Grant protocol roles ──
        vm.startPrank(admin);
        fixture.accessManager.grantRole(
            fixture.accessManager.BRIDGE_ROLE(), bridgeOp
        );
        fixture.accessManager.grantRole(
            fixture.accessManager.BRIDGE_ROLE(),
            address(fixture.settlementCoordinator)
        );
        fixture.accessManager.grantRole(
            fixture.accessManager.COMPLIANCE_ROLE(), complianceOp
        );
        vm.stopPrank();

        // ── 12. Fund transport provider with native gas for CCIP fees ──
        vm.deal(address(fixture.transportProvider), 10 ether);
    }

    /// @notice Deploys a complete protocol stack backed by the real ERC-3643
    ///         contracts (Token, IdentityRegistry, ModularCompliance, claim
    ///         infrastructure). The test contract receives AGENT_ROLE on the
    ///         token so that direct `fixture.token.mint(...)` calls from setUp
    ///         still work. The adapter also receives AGENT_ROLE for settlement
    ///         operations. A pre-configured investor identity is registered for
    ///         `sender` with a valid claim.
    /// @param  admin         Address that receives DEFAULT_ADMIN_ROLE.
    /// @param  chainId       This chain's protocol-level identifier.
    /// @param  ccipSelector  CCIP chain selector for this chain.
    /// @param  bridgeOp      Address that receives BRIDGE_ROLE.
    /// @param  complianceOp  Address that receives COMPLIANCE_ROLE.
    /// @param  sender        Address to register as an investor with a valid
    ///                       identity and claim (mint destination).
    /// @return fixture       Fully deployed and initialized protocol stack.
    /// @return erc3643Stack  The deployed ERC-3643 contracts for test access.
    function deployProtocolWithRealERC3643(
        address admin,
        ChainId chainId,
        uint64 ccipSelector,
        address bridgeOp,
        address complianceOp,
        address sender
    ) internal returns (ProtocolFixture memory fixture, ERC3643Stack memory erc3643Stack) {
        uint256 nonceStart = vm.getNonce(address(this));

        // ── 0. Deploy ERC-3643 stack via CREATE2 (no nonce impact) ──
        erc3643Stack = deployERC3643StackWithName("Protocol Token", "PTK", 18);

        // ── 1. ProtocolAccessManager (offset +0) ──
        fixture.accessManager = new ProtocolAccessManager(admin);

        // ── 2. TransferIntentManager (offset +1) ──
        fixture.transferIntentManager = new TransferIntentManager(
            IProtocolAccessManager(address(fixture.accessManager))
        );

        // ── 3. RuleEngineComplianceProvider (offset +2) ──
        fixture.complianceProvider = new RuleEngineComplianceProvider(
            IProtocolAccessManager(address(fixture.accessManager))
        );

        // ── 4. ERC3643AssetAdapter (offset +3) ──
        fixture.assetAdapter = new ERC3643AssetAdapter(
            IProtocolAccessManager(address(fixture.accessManager)),
            chainId
        );

        // ── 5. MockCCIPRouter (offset +4) ──
        fixture.router = new MockCCIPRouter();

        // ── 6. Resolve circular dependency ──
        // SettlementCoordinator (offset +6) must be pre-computed before
        // deploying CCIPTransportProvider (offset +5), because each needs
        // the other's address in its constructor.
        address predictedCoordinator = vm.computeCreateAddress(
            address(this), nonceStart + 6
        );

        // ── 7. CCIPTransportProvider (offset +5) ──
        fixture.transportProvider = new CCIPTransportProvider(
            IProtocolAccessManager(address(fixture.accessManager)),
            ICcipRouterClient(address(fixture.router)),
            ISettlementCoordinator(predictedCoordinator),
            address(0)
        );

        // ── 8. SettlementCoordinator (offset +6) ──
        fixture.settlementCoordinator = new SettlementCoordinator(
            IProtocolAccessManager(address(fixture.accessManager)),
            chainId,
            ITransferIntentManager(address(fixture.transferIntentManager)),
            ICompliancePolicyProvider(address(fixture.complianceProvider)),
            IAssetAdapter(address(fixture.assetAdapter)),
            ITransportProvider(address(fixture.transportProvider))
        );

        // ── 9. Token wiring ──
        fixture.token = IERC3643TokenMinimal(address(erc3643Stack.token));

        // Grant AGENT_ROLE on the real token to the test contract (for setUp)
        // and to the adapter (for settlement operations), then unpause.
        IERC3643TokenMinimal(address(erc3643Stack.token)).addAgent(address(this));
        IERC3643TokenMinimal(address(erc3643Stack.token)).addAgent(address(fixture.assetAdapter));
        IERC3643TokenMinimal(address(erc3643Stack.token)).unpause();

        // Register a trusted issuer claim topic, add the claim topic,
        // create an investor identity, and register it.
        ITIR(erc3643Stack.trustedIssuersRegistry).addTrustedIssuer(
            erc3643Stack.claimIssuer,
            _asUint256Array(erc3643Stack.claimTopic)
        );

        createAndRegisterInvestor(erc3643Stack, sender, 0);

        // ── 10. Store metadata ──
        fixture.chainId = chainId;
        fixture.admin = admin;
        fixture.bridgeOp = bridgeOp;
        fixture.complianceOp = complianceOp;

        // ── 11. Grant protocol roles ──
        vm.startPrank(admin);
        fixture.accessManager.grantRole(
            fixture.accessManager.BRIDGE_ROLE(), bridgeOp
        );
        fixture.accessManager.grantRole(
            fixture.accessManager.BRIDGE_ROLE(),
            address(fixture.settlementCoordinator)
        );
        fixture.accessManager.grantRole(
            fixture.accessManager.COMPLIANCE_ROLE(), complianceOp
        );
        vm.stopPrank();

        // ── 12. Fund transport provider with native gas for CCIP fees ──
        vm.deal(address(fixture.transportProvider), 10 ether);
    }

    function _asUint256Array(uint256 v) private pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    /// @notice Registers an asset in the adapter and sets its settlement model.
    /// @param fixture        The deployed protocol fixture.
    /// @param assetId        Protocol-level asset identifier.
    /// @param tokenAddress   The ERC-3643 token contract address.
    /// @param decimals       Token decimals.
    /// @param assetType      Asset type identifier (e.g. keccak256("BOND")).
    /// @param settlementModel Settlement model identifier (e.g. keccak256("BURN_MINT")).
    function configureAsset(
        ProtocolFixture memory fixture,
        bytes32 assetId,
        address tokenAddress,
        uint8 decimals,
        bytes32 assetType,
        bytes32 settlementModel
    ) internal {
        vm.prank(fixture.complianceOp);
        fixture.assetAdapter.configureAsset(
            assetId,
            tokenAddress,
            decimals,
            assetType,
            settlementModel,
            keccak256("T-REX:4.1.6")
        );
    }

    /// @notice Configures basic compliance policy: allowed asset, allowed
    ///         action, chain-to-jurisdiction mappings, and policy version.
    /// @param fixture            The deployed protocol fixture.
    /// @param assetId            Asset to allow in compliance.
    /// @param action             Intent action to allow.
    /// @param chainIds           Chain IDs to set jurisdictions for.
    /// @param jurisdictionCodes  Corresponding jurisdiction codes.
    function configureCompliance(
        ProtocolFixture memory fixture,
        bytes32 assetId,
        ProtocolTypes.IntentAction action,
        ChainId[] memory chainIds,
        bytes32[] memory jurisdictionCodes
    ) internal {
        require(
            chainIds.length == jurisdictionCodes.length,
            "ProtocolFixture: array length mismatch"
        );

        vm.startPrank(fixture.complianceOp);
        fixture.complianceProvider.setAllowedAsset(assetId, true);
        fixture.complianceProvider.setAllowedAction(action, true);

        for (uint256 i; i < chainIds.length; ++i) {
            fixture.complianceProvider.setChainJurisdiction(
                chainIds[i], jurisdictionCodes[i]
            );
        }

        fixture.complianceProvider.setPolicyVersion(
            keccak256("POLICY:v1")
        );
        vm.stopPrank();
    }

    /// @notice Configures transport: maps a remote chain to its CCIP selector
    ///         and allowlists a remote transport provider.
    /// @param fixture        The deployed protocol fixture.
    /// @param remoteChain    Remote protocol chain ID.
    /// @param remoteSelector CCIP chain selector for the remote chain.
    /// @param remoteProvider Address of the remote chain's CCIPTransportProvider.
    function configureTransport(
        ProtocolFixture memory fixture,
        ChainId remoteChain,
        uint64 remoteSelector,
        address remoteProvider
    ) internal {
        vm.startPrank(fixture.bridgeOp);
        fixture.transportProvider.setChainSelector(remoteChain, remoteSelector);
        fixture.transportProvider.setAllowedSender(remoteChain, remoteProvider, true);
        fixture.transportProvider.setRemoteReceiver(remoteChain, remoteProvider);
        vm.stopPrank();
    }
}
