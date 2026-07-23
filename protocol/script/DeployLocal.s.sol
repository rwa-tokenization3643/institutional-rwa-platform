// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ProtocolAccessManager} from "../contracts/access/ProtocolAccessManager.sol";
import {IProtocolAccessManager} from "../contracts/access/IProtocolAccessManager.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {TransferIntentManager} from "../contracts/core/TransferIntentManager.sol";
import {ITransferIntentManager} from "../contracts/interfaces/ITransferIntentManager.sol";
import {RuleEngineComplianceProvider} from "../contracts/compliance/RuleEngineComplianceProvider.sol";
import {ERC3643AssetAdapter} from "../contracts/adapters/ERC3643AssetAdapter.sol";
import {IAssetAdapter} from "../contracts/interfaces/IAssetAdapter.sol";
import {ICompliancePolicyProvider} from "../contracts/interfaces/ICompliancePolicyProvider.sol";
import {ITransportProvider} from "../contracts/interfaces/ITransportProvider.sol";
import {SettlementCoordinator} from "../contracts/core/SettlementCoordinator.sol";
import {ISettlementCoordinator} from "../contracts/interfaces/ISettlementCoordinator.sol";
import {CCIPTransportProvider, ICcipRouterClient, Any2EVMMessage} from "../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {MockCCIPRouter} from "../test/mocks/MockCCIPRouter.sol";
import {IERC3643TokenMinimal} from "../test/mocks/IERC3643TokenMinimal.sol";
import {VendorBytecode} from "../test/utils/VendorBytecode.sol";

// =============================================================================
// Interfaces for vendor contract initialization
// =============================================================================

interface ITIR {
    function init() external;
    function addTrustedIssuer(address _trustedIssuer, uint256[] memory _claimTopics) external;
}

interface ICTR {
    function init() external;
    function addClaimTopic(uint256 topic) external;
}

interface IIRS {
    function init() external;
    function bindIdentityRegistry(address ir) external;
}

interface IIR {
    function init(address tir, address ctr, address irs) external;
    function registerIdentity(address user, address identity, uint16 country) external;
    function addAgent(address agent) external;
}

interface IMC {
    function init() external;
}

interface IClaimIssuer {
    function addKey(bytes32 key, uint256 purpose, uint256 type_) external;
    function addAgent(address agent) external;
}

interface ITokenVendor {
    function init(
        address ir,
        address comp,
        string memory name,
        string memory symbol,
        uint8 decimals,
        address onchainID
    ) external;
    function addAgent(address agent) external;
    function unpause() external;
    function mint(address to, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IIdentityVendor {
    function addKey(bytes32 key, uint256 purpose, uint256 type_) external;
    function addClaim(
        uint256 topic,
        uint256 scheme,
        address issuer,
        bytes memory signature,
        bytes memory data,
        string memory uri
    ) external;
}

// =============================================================================
// Deployment Result Structs
// =============================================================================

struct ERC3643Stack {
    address trustedIssuersRegistry;
    address claimTopicsRegistry;
    address identityRegistryStorage;
    address identityRegistry;
    address modularCompliance;
    address claimIssuer;
    address token;
    uint256 claimTopic;
}

struct ProtocolStack {
    ProtocolAccessManager accessManager;
    SettlementCoordinator settlementCoordinator;
    TransferIntentManager transferIntentManager;
    RuleEngineComplianceProvider complianceProvider;
    ERC3643AssetAdapter assetAdapter;
    CCIPTransportProvider transportProvider;
    MockCCIPRouter router;
}

// =============================================================================
// DeployLocal - Full local Anvil deployment harness
// =============================================================================
//
// Deploys the complete Institutional RWA Protocol stack:
//
//   Phase 1: Real ERC-3643 ecosystem (ONCHAINID, identity, compliance, token)
//   Phase 2: Protocol contracts (access, intent, settlement, compliance, adapter, transport)
//   Phase 3: Happy-path end-to-end settlement via Mock CCIP
//
// Usage:
//   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
//
// =============================================================================

contract DeployLocal is Script {

    // -- Constants --
    ChainId internal constant SOURCE_CHAIN = ChainId.wrap(1);
    ChainId internal constant DEST_CHAIN   = ChainId.wrap(2);
    uint64 internal constant CCIP_SOURCE_SELECTOR = 15971525489660198786;
    uint64 internal constant CCIP_DEST_SELECTOR   = 5009297550715157269;

    bytes32 internal constant ASSET_ID      = keccak256("RWA_TOKEN");
    bytes32 internal constant ASSET_TYPE    = keccak256("BOND");
    bytes32 internal constant BURN_MINT     = keccak256("BURN_MINT");
    bytes32 internal constant JURISDICTION_US = keccak256("US");
    bytes32 internal constant JURISDICTION_EU = keccak256("EU");

    uint256 internal constant TOKEN_SUPPLY    = 10_000 ether;
    uint256 internal constant TRANSFER_AMOUNT = 1_000 ether;

    uint256 internal constant CLAIM_SIGNER_SK = 0xA11CE;
    uint256 internal constant CLAIM_TOPIC     = 1;

    address internal constant ADMIN         = address(0xA11CE);
    address internal constant COMPLIANCE_OP = address(0xCAFE);
    address internal constant BRIDGE_OP     = address(0xB0B0B);
    address internal constant INVESTOR_A    = address(0xAAA);
    address internal constant INVESTOR_B    = address(0xBBB);

    // -- Storage --
    ERC3643Stack  srcERC3643;
    ERC3643Stack  dstERC3643;
    ProtocolStack srcProtocol;
    ProtocolStack dstProtocol;
    address       deployer;

    // -- Nonce tracking for cross-chain simulation --
    uint64 _nonce;

    // =========================================================================
    // Entry Point
    // =========================================================================

    function run() external {
        deployer = msg.sender;

        console.log("+============================================================+");
        console.log("|  Institutional RWA Protocol -- Local Anvil Deployment      |");
        console.log("+============================================================+");
        console.log("");

        // -- Phase 1: Deploy ERC-3643 --
        _printPhaseHeader("PHASE 1", "Deploy & Configure ERC-3643 Ecosystem");
        srcERC3643 = _deployERC3643Stack("Source", SOURCE_CHAIN);
        dstERC3643 = _deployERC3643Stack("Destination", DEST_CHAIN);

        // -- Verify ERC-3643 transfers --
        _verifyERC3643Transfers();

        // -- Phase 2: Deploy Protocol --
        _printPhaseHeader("PHASE 2", "Deploy & Wire Protocol Contracts");
        srcProtocol = _deployProtocolStack(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        dstProtocol = _deployProtocolStack(DEST_CHAIN, CCIP_DEST_SELECTOR);

        // -- Configure protocol --
        _configureProtocol();

        // -- Phase 3: Execute Happy Path --
        _printPhaseHeader("PHASE 3", "Execute Happy-Path Settlement");
        _executeHappyPath();

        // -- Summary --
        _printSummary();
    }

    // =========================================================================
    // Phase 1: ERC-3643 Deployment
    // =========================================================================

    function _deployERC3643Stack(
        string memory label,
        ChainId chainId
    ) internal returns (ERC3643Stack memory stack) {
        console.log("-- Deploying %s ERC-3643 Stack (ChainId=%d) --", label, ChainId.unwrap(chainId));

        bytes32 saltTir = keccak256(abi.encode("erc3643-tir", ChainId.unwrap(chainId)));
        bytes32 saltCtr = keccak256(abi.encode("erc3643-ctr", ChainId.unwrap(chainId)));
        bytes32 saltIrs = keccak256(abi.encode("erc3643-irs", ChainId.unwrap(chainId)));
        bytes32 saltIr  = keccak256(abi.encode("erc3643-ir",  ChainId.unwrap(chainId)));
        bytes32 saltMc  = keccak256(abi.encode("erc3643-mc",  ChainId.unwrap(chainId)));
        bytes32 saltCi  = keccak256(abi.encode("erc3643-ci",  ChainId.unwrap(chainId)));
        bytes32 saltTok = keccak256(abi.encode("erc3643-tok", ChainId.unwrap(chainId)));

        // TrustedIssuersRegistry
        stack.trustedIssuersRegistry = _deploy2(VendorBytecode.TRUSTED_ISSUERS_REGISTRY, saltTir);
        vm.prank(deployer);
        ITIR(stack.trustedIssuersRegistry).init();
        console.log("  TrustedIssuersRegistry: %s", _addr(stack.trustedIssuersRegistry));

        // ClaimTopicsRegistry
        stack.claimTopicsRegistry = _deploy2(VendorBytecode.CLAIM_TOPICS_REGISTRY, saltCtr);
        vm.prank(deployer);
        ICTR(stack.claimTopicsRegistry).init();
        console.log("  ClaimTopicsRegistry:    %s", _addr(stack.claimTopicsRegistry));

        // IdentityRegistryStorage
        stack.identityRegistryStorage = _deploy2(VendorBytecode.IDENTITY_REGISTRY_STORAGE, saltIrs);
        vm.prank(deployer);
        IIRS(stack.identityRegistryStorage).init();
        console.log("  IdentityRegistryStorage:%s", _addr(stack.identityRegistryStorage));

        // IdentityRegistry
        stack.identityRegistry = _deploy2(VendorBytecode.IDENTITY_REGISTRY, saltIr);
        vm.prank(deployer);
        IIR(stack.identityRegistry).init(
            stack.trustedIssuersRegistry,
            stack.claimTopicsRegistry,
            stack.identityRegistryStorage
        );
        console.log("  IdentityRegistry:       %s", _addr(stack.identityRegistry));

        // ModularCompliance
        stack.modularCompliance = _deploy2(VendorBytecode.MODULAR_COMPLIANCE, saltMc);
        vm.prank(deployer);
        IMC(stack.modularCompliance).init();
        console.log("  ModularCompliance:      %s", _addr(stack.modularCompliance));

        // ClaimIssuer (ONCHAINID) -- deployer is the management key
        bytes memory ciArgs = abi.encode(deployer, false);
        bytes memory ciBytecode = abi.encodePacked(VendorBytecode.CLAIM_ISSUER, ciArgs);
        stack.claimIssuer = _deploy2(ciBytecode, saltCi);
        address signer = vm.addr(CLAIM_SIGNER_SK);
        vm.prank(deployer);
        IClaimIssuer(stack.claimIssuer).addKey(keccak256(abi.encode(signer)), 3, 1);
        console.log("  ClaimIssuer:            %s", _addr(stack.claimIssuer));

        // ERC-3643 Token
        stack.token = _deploy2(VendorBytecode.TOKEN, saltTok);
        vm.prank(deployer);
        ITokenVendor(stack.token).init(
            stack.identityRegistry,
            stack.modularCompliance,
            "Institutional RWA Token",
            "iRWA",
            18,
            address(0)
        );
        console.log("  Token:                  %s", _addr(stack.token));

        // Configure: add claim topic
        vm.prank(deployer);
        ICTR(stack.claimTopicsRegistry).addClaimTopic(CLAIM_TOPIC);

        // Configure: add trusted issuer
        uint256[] memory topics = new uint256[](1);
        topics[0] = CLAIM_TOPIC;
        vm.prank(deployer);
        ITIR(stack.trustedIssuersRegistry).addTrustedIssuer(stack.claimIssuer, topics);

        // Configure: bind identity registry to storage
        vm.prank(deployer);
        IIRS(stack.identityRegistryStorage).bindIdentityRegistry(stack.identityRegistry);

        // Configure: add deployer as agent on token and identity registry
        vm.prank(deployer);
        ITokenVendor(stack.token).addAgent(deployer);
        vm.prank(deployer);
        IIR(stack.identityRegistry).addAgent(deployer);

        // Unpause the token (starts paused by default)
        vm.prank(deployer);
        ITokenVendor(stack.token).unpause();

        stack.claimTopic = CLAIM_TOPIC;

        // -- Create & register two investor identities --
        _createAndRegisterInvestor(stack, chainId, INVESTOR_A, 840, "Investor A");
        _createAndRegisterInvestor(stack, chainId, INVESTOR_B, 276, "Investor B");

        // -- Mint tokens to Investor A --
        vm.prank(deployer);
        ITokenVendor(stack.token).mint(INVESTOR_A, TOKEN_SUPPLY);
        console.log("  Minted %d tokens to Investor A", TOKEN_SUPPLY / 1e18);
        console.log("");

        return stack;
    }

    function _createAndRegisterInvestor(
        ERC3643Stack memory stack,
        ChainId chainId,
        address investor,
        uint16 country,
        string memory label
    ) internal {
        bytes32 salt = keccak256(abi.encode("investor", investor, ChainId.unwrap(chainId)));
        // Identity management key = deployer
        bytes memory idArgs = abi.encode(deployer, false);
        bytes memory idBytecode = abi.encodePacked(VendorBytecode.IDENTITY, idArgs);
        address identity = _deploy2(idBytecode, salt);

        // Add management key (deployer already has it from constructor)
        // Add claim signer key
        vm.prank(deployer);
        IIdentityVendor(identity).addKey(keccak256(abi.encode(vm.addr(CLAIM_SIGNER_SK))), 3, 1);

        // Issue claim
        _issueClaim(stack, identity);

        // Register in identity registry
        vm.prank(deployer);
        IIR(stack.identityRegistry).registerIdentity(investor, identity, country);

        console.log("  %s identity registered (country=%d)", label, country);
    }

    function _issueClaim(ERC3643Stack memory stack, address investorIdentity) internal {
        address issuer = stack.claimIssuer;
        uint256 topic = stack.claimTopic;
        bytes memory data = "";

        bytes32 dataHash = keccak256(abi.encode(investorIdentity, topic, data));
        bytes32 prefixedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CLAIM_SIGNER_SK, prefixedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // addClaim requires claim key (purpose 3). deployer has management key
        // which grants all purposes, so this works.
        vm.prank(deployer);
        IIdentityVendor(investorIdentity).addClaim(topic, 1, issuer, signature, data, "");
    }

    function _verifyERC3643Transfers() internal {
        console.log("-- Verifying ERC-3643 Transfers --");

        uint256 balanceBefore = ITokenVendor(srcERC3643.token).balanceOf(INVESTOR_A);
        console.log("  Investor A balance: %d", balanceBefore / 1e18);

        vm.prank(INVESTOR_A);
        ITokenVendor(srcERC3643.token).transfer(INVESTOR_B, 100 ether);

        uint256 balanceAfterA = ITokenVendor(srcERC3643.token).balanceOf(INVESTOR_A);
        uint256 balanceAfterB = ITokenVendor(srcERC3643.token).balanceOf(INVESTOR_B);

        console.log("  After transfer: A=%d, B=%d", balanceAfterA / 1e18, balanceAfterB / 1e18);
        require(balanceAfterA == TOKEN_SUPPLY - 100 ether, "ERC-3643 transfer failed for A");
        require(balanceAfterB == 100 ether, "ERC-3643 transfer failed for B");
        console.log("  [OK] ERC-3643 transfers work correctly");
        console.log("");

        // Restore full balance to Investor A for the settlement test
        vm.prank(INVESTOR_B);
        ITokenVendor(srcERC3643.token).transfer(INVESTOR_A, 100 ether);
    }

    // =========================================================================
    // Phase 2: Protocol Deployment
    // =========================================================================

    function _deployProtocolStack(
        ChainId chainId,
        uint64 /* ccipSelector */
    ) internal returns (ProtocolStack memory stack) {
        console.log("-- Deploying Protocol Stack (ChainId=%d) --", ChainId.unwrap(chainId));

        uint256 nonceStart = vm.getNonce(deployer);

        // -- 1. ProtocolAccessManager (offset +0) --
        vm.startBroadcast(deployer);
        stack.accessManager = new ProtocolAccessManager(ADMIN);
        vm.stopBroadcast();
        console.log("  ProtocolAccessManager: %s", _addr(address(stack.accessManager)));

        // -- 2. TransferIntentManager (offset +1) --
        vm.startBroadcast(deployer);
        stack.transferIntentManager = new TransferIntentManager(
            IProtocolAccessManager(address(stack.accessManager))
        );
        vm.stopBroadcast();
        console.log("  TransferIntentManager: %s", _addr(address(stack.transferIntentManager)));

        // -- 3. RuleEngineComplianceProvider (offset +2) --
        vm.startBroadcast(deployer);
        stack.complianceProvider = new RuleEngineComplianceProvider(
            IProtocolAccessManager(address(stack.accessManager))
        );
        vm.stopBroadcast();
        console.log("  RuleEngineCompliance:  %s", _addr(address(stack.complianceProvider)));

        // -- 4. ERC3643AssetAdapter (offset +3) --
        vm.startBroadcast(deployer);
        stack.assetAdapter = new ERC3643AssetAdapter(
            IProtocolAccessManager(address(stack.accessManager)),
            chainId
        );
        vm.stopBroadcast();
        console.log("  ERC3643AssetAdapter:   %s", _addr(address(stack.assetAdapter)));

        // -- 5. MockCCIPRouter (offset +4) --
        vm.startBroadcast(deployer);
        stack.router = new MockCCIPRouter();
        vm.stopBroadcast();
        console.log("  MockCCIPRouter:        %s", _addr(address(stack.router)));

        // -- 6. Predict SettlementCoordinator address (offset +6) --
        // CCIPTransportProvider needs the coordinator address in its constructor.
        // The coordinator will be at nonceStart + 6, and the transport at nonceStart + 5.
        // Since we're using vm.startBroadcast, nonces are incremented for the deployer.
        address predictedCoordinator = vm.computeCreateAddress(deployer, nonceStart + 6);

        // -- 7. CCIPTransportProvider (offset +5) --
        vm.startBroadcast(deployer);
        stack.transportProvider = new CCIPTransportProvider(
            IProtocolAccessManager(address(stack.accessManager)),
            ICcipRouterClient(address(stack.router)),
            ISettlementCoordinator(predictedCoordinator),
            address(0)
        );
        vm.stopBroadcast();
        console.log("  CCIPTransportProvider: %s", _addr(address(stack.transportProvider)));

        // -- 8. SettlementCoordinator (offset +6) --
        vm.startBroadcast(deployer);
        stack.settlementCoordinator = new SettlementCoordinator(
            IProtocolAccessManager(address(stack.accessManager)),
            chainId,
            ITransferIntentManager(address(stack.transferIntentManager)),
            ICompliancePolicyProvider(address(stack.complianceProvider)),
            IAssetAdapter(address(stack.assetAdapter)),
            ITransportProvider(address(stack.transportProvider))
        );
        vm.stopBroadcast();
        console.log("  SettlementCoordinator: %s", _addr(address(stack.settlementCoordinator)));

        // -- 9. Grant protocol roles --
        bytes32 bridgeRole = stack.accessManager.BRIDGE_ROLE();
        bytes32 complianceRole = stack.accessManager.COMPLIANCE_ROLE();
        vm.prank(ADMIN);
        stack.accessManager.grantRole(bridgeRole, BRIDGE_OP);
        vm.prank(ADMIN);
        stack.accessManager.grantRole(bridgeRole, address(stack.settlementCoordinator));
        vm.prank(ADMIN);
        stack.accessManager.grantRole(complianceRole, COMPLIANCE_OP);
        console.log("  Roles granted: BRIDGE->%s, COMPLIANCE->%s, COORDINATOR->BRIDGE", _addr(BRIDGE_OP), _addr(COMPLIANCE_OP));

        // -- 10. Fund transport provider with ETH for CCIP fees --
        vm.deal(address(stack.transportProvider), 10 ether);

        console.log("");
        return stack;
    }

    function _configureProtocol() internal {
        console.log("-- Configuring Protocol --");

        // -- Grant asset adapter agent role on ERC-3643 tokens --
        vm.prank(deployer);
        IERC3643TokenMinimal(srcERC3643.token).addAgent(address(srcProtocol.assetAdapter));
        vm.prank(deployer);
        IERC3643TokenMinimal(dstERC3643.token).addAgent(address(dstProtocol.assetAdapter));

        // -- Configure assets on both chains --
        _configureAsset(srcProtocol, IERC3643TokenMinimal(srcERC3643.token), "Source");
        _configureAsset(dstProtocol, IERC3643TokenMinimal(dstERC3643.token), "Destination");

        // -- Configure compliance on both chains --
        _configureCompliance(srcProtocol, "Source");
        _configureCompliance(dstProtocol, "Destination");

        // -- Configure transport --
        // Source chain
        vm.startPrank(BRIDGE_OP);
        srcProtocol.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        srcProtocol.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        srcProtocol.transportProvider.setAllowedSender(DEST_CHAIN, address(dstProtocol.transportProvider), true);
        srcProtocol.transportProvider.setRemoteReceiver(DEST_CHAIN, address(dstProtocol.transportProvider));
        vm.stopPrank();

        // Destination chain
        vm.startPrank(BRIDGE_OP);
        dstProtocol.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        dstProtocol.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        dstProtocol.transportProvider.setAllowedSender(SOURCE_CHAIN, address(srcProtocol.transportProvider), true);
        dstProtocol.transportProvider.setRemoteReceiver(SOURCE_CHAIN, address(srcProtocol.transportProvider));
        vm.stopPrank();

        console.log("  Transport configured: src<->dest");
        console.log("");
    }

    function _configureAsset(
        ProtocolStack memory stack,
        IERC3643TokenMinimal token,
        string memory label
    ) internal {
        vm.prank(COMPLIANCE_OP);
        stack.assetAdapter.configureAsset(
            ASSET_ID,
            address(token),
            18,
            ASSET_TYPE,
            BURN_MINT,
            keccak256("T-REX:4.1.3")
        );
        console.log("  Asset configured on %s chain", label);
    }

    function _configureCompliance(
        ProtocolStack memory stack,
        string memory label
    ) internal {
        vm.startPrank(COMPLIANCE_OP);

        stack.complianceProvider.setAllowedAsset(ASSET_ID, true);
        stack.complianceProvider.setAllowedAction(ProtocolTypes.IntentAction.TRANSFER, true);

        // Set chain jurisdictions
        stack.complianceProvider.setChainJurisdiction(SOURCE_CHAIN, JURISDICTION_US);
        stack.complianceProvider.setChainJurisdiction(DEST_CHAIN, JURISDICTION_EU);

        // Set investor classifications (INSTITUTIONAL = 3)
        bytes32 senderHash = keccak256(abi.encode(INVESTOR_A));
        bytes32 recipientHash = keccak256(abi.encode(INVESTOR_B));
        stack.complianceProvider.setInvestorClassification(senderHash, RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL);
        stack.complianceProvider.setInvestorClassification(recipientHash, RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL);
        stack.complianceProvider.setMinimumClassification(RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL);

        // Set generous limits
        stack.complianceProvider.setMaxTransferAmount(ASSET_ID, 100_000 ether);
        stack.complianceProvider.setMaxHolding(ASSET_ID, 1_000_000 ether);

        // Set policy version
        stack.complianceProvider.setPolicyVersion(keccak256("POLICY:v1"));

        vm.stopPrank();
        console.log("  Compliance configured on %s chain", label);
    }

    // =========================================================================
    // Phase 3: Happy-Path Settlement
    // =========================================================================

    function _executeHappyPath() internal {
        console.log("-- Executing Happy-Path Settlement --");
        console.log("");

        // -- Create TransferIntent --
        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(
            abi.encode(SOURCE_CHAIN, nonce, INVESTOR_A, INVESTOR_B, TRANSFER_AMOUNT)
        );

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: INVESTOR_A,
            recipient: INVESTOR_B,
            senderIdentityHash: keccak256(abi.encode(INVESTOR_A)),
            recipientIdentityHash: keccak256(abi.encode(INVESTOR_B)),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(DEST_CHAIN),
            amount: TRANSFER_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        console.log("  IntentId: %s", _bytes32(intentId));
        console.log("  Amount:   %d tokens", TRANSFER_AMOUNT / 1e18);
        console.log("  Sender:   %s", _addr(INVESTOR_A));
        console.log("  Recipient:%s", _addr(INVESTOR_B));
        console.log("");

        // -- Record initial balances --
        uint256 srcBalanceBefore = ITokenVendor(srcERC3643.token).balanceOf(INVESTOR_A);
        uint256 dstBalanceBefore = ITokenVendor(dstERC3643.token).balanceOf(INVESTOR_B);
        console.log("  [Before] Investor A (source): %d", srcBalanceBefore / 1e18);
        console.log("  [Before] Investor B (dest):   %d", dstBalanceBefore / 1e18);
        console.log("");

        // -- Phase 1: Submit Transfer --
        _printPhaseStep("1", "Submit Transfer (Source)");
        vm.prank(INVESTOR_A);
        srcProtocol.settlementCoordinator.submitTransfer(intent);
        _assertState(
            srcProtocol.transferIntentManager,
            intentId,
            ProtocolTypes.SettlementState.PENDING_VALIDATION,
            "Source -> PENDING_VALIDATION"
        );

        // -- Phase 2: Deliver Validation Request to Destination --
        _printPhaseStep("2", "Validation Request (Source -> Dest)");
        bytes32 valReqMsgId = keccak256("val_req");
        _deliverPhaseMessage(
            dstProtocol.transportProvider,
            dstProtocol.router,
            CCIP_SOURCE_SELECTOR,
            address(srcProtocol.transportProvider),
            srcProtocol.transportProvider,
            intentId, SOURCE_CHAIN, DEST_CHAIN,
            intent.expiresAt,
            valReqMsgId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
            abi.encode(intent)
        );
        _assertState(
            dstProtocol.transferIntentManager,
            intentId,
            ProtocolTypes.SettlementState.VALIDATED,
            "Dest -> VALIDATED"
        );

        // -- Phase 3: Deliver Validation Response to Source --
        _printPhaseStep("3", "Validation Response (Dest -> Source)");
        bytes32 valResMsgId = keccak256("val_res");
        _deliverPhaseMessage(
            srcProtocol.transportProvider,
            srcProtocol.router,
            CCIP_DEST_SELECTOR,
            address(dstProtocol.transportProvider),
            dstProtocol.transportProvider,
            intentId, DEST_CHAIN, SOURCE_CHAIN,
            intent.expiresAt,
            valResMsgId,
            ProtocolTypes.MessageType.VALIDATION_RESPONSE,
            ProtocolTypes.SettlementPhase.VALIDATION_RESPONSE,
            abi.encode(ProtocolTypes.ComplianceResult.APPROVED)
        );
        _assertState(
            srcProtocol.transferIntentManager,
            intentId,
            ProtocolTypes.SettlementState.RESERVED,
            "Source -> RESERVED"
        );
        uint256 reserved = srcProtocol.assetAdapter.reservedBalance(ASSET_ID, INVESTOR_A, bytes32(0));
        console.log("  Reserved: %d tokens", reserved / 1e18);

        // -- Phase 4: Deliver Settlement Instruction to Destination --
        _printPhaseStep("4", "Settlement Instruction (Source -> Dest)");
        bytes32 instrMsgId = keccak256("settle_instr");
        _deliverPhaseMessage(
            dstProtocol.transportProvider,
            dstProtocol.router,
            CCIP_SOURCE_SELECTOR,
            address(srcProtocol.transportProvider),
            srcProtocol.transportProvider,
            intentId, SOURCE_CHAIN, DEST_CHAIN,
            intent.expiresAt,
            instrMsgId,
            ProtocolTypes.MessageType.TRANSFER_INTENT,
            ProtocolTypes.SettlementPhase.SETTLEMENT_INSTRUCTION,
            bytes("")
        );
        _assertState(
            dstProtocol.transferIntentManager,
            intentId,
            ProtocolTypes.SettlementState.SETTLED,
            "Dest -> SETTLED"
        );
        uint256 dstBalanceAfterMint = ITokenVendor(dstERC3643.token).balanceOf(INVESTOR_B);
        console.log("  Investor B (dest) balance: %d", dstBalanceAfterMint / 1e18);

        // -- Phase 5: Deliver Settlement Acknowledgement to Source --
        _printPhaseStep("5", "Settlement ACK (Dest -> Source)");
        bytes32 ackMsgId = keccak256("settle_ack");
        _deliverPhaseMessage(
            srcProtocol.transportProvider,
            srcProtocol.router,
            CCIP_DEST_SELECTOR,
            address(dstProtocol.transportProvider),
            dstProtocol.transportProvider,
            intentId, DEST_CHAIN, SOURCE_CHAIN,
            intent.expiresAt,
            ackMsgId,
            ProtocolTypes.MessageType.SETTLEMENT_CONFIRMATION,
            ProtocolTypes.SettlementPhase.SETTLEMENT_ACK,
            bytes("")
        );
        _assertState(
            srcProtocol.transferIntentManager,
            intentId,
            ProtocolTypes.SettlementState.SETTLED,
            "Source -> SETTLED"
        );

        // -- Phase 6: Final Verification --
        _printPhaseStep("6", "Final Verification");
        uint256 srcBalanceAfter = ITokenVendor(srcERC3643.token).balanceOf(INVESTOR_A);
        uint256 dstBalanceAfter = ITokenVendor(dstERC3643.token).balanceOf(INVESTOR_B);

        require(
            srcBalanceAfter == srcBalanceBefore - TRANSFER_AMOUNT,
            "Source balance invariant violated"
        );
        require(
            dstBalanceAfter == dstBalanceBefore + TRANSFER_AMOUNT,
            "Dest balance invariant violated"
        );
        require(
            srcBalanceAfter + dstBalanceAfter == TOKEN_SUPPLY,
            "Supply conservation violated"
        );
        require(
            srcProtocol.assetAdapter.reservedBalance(ASSET_ID, INVESTOR_A, bytes32(0)) == 0,
            "Residual reservation exists"
        );
        require(
            srcProtocol.assetAdapter.availableBalance(ASSET_ID, INVESTOR_A, bytes32(0))
                == srcBalanceAfter,
            "Available balance mismatch"
        );

        console.log("  [OK] All invariants verified:");
        console.log("    - Source balance decreased by %d", TRANSFER_AMOUNT / 1e18);
        console.log("    - Dest balance increased by %d", TRANSFER_AMOUNT / 1e18);
        console.log("    - Total supply conserved: %d", TOKEN_SUPPLY / 1e18);
        console.log("    - No residual reservations");
        console.log("    - Available balance matches token balance");
        console.log("");
    }

    // =========================================================================
    // Helpers: Cross-Chain Message Delivery
    // =========================================================================

    function _deliverPhaseMessage(
        CCIPTransportProvider destProvider,
        MockCCIPRouter destRouter,
        uint64 ccipSourceSelector,
        address sourceTransportAddress,
        CCIPTransportProvider sourceProvider,
        bytes32 intentId,
        ChainId sourceChain,
        ChainId destChain,
        uint64 expiresAt,
        bytes32 msgId,
        ProtocolTypes.MessageType messageType,
        ProtocolTypes.SettlementPhase phase,
        bytes memory payload
    ) internal {
        ProtocolTypes.TransportMessage memory tm = ProtocolTypes.TransportMessage({
            messageVersion: 1,
            transportId: sourceProvider.TRANSPORT_ID(),
            messageType: messageType,
            phase: phase,
            messageId: bytes32(0),
            intentId: intentId,
            sourceChainId: ChainId.unwrap(sourceChain),
            destinationChainId: ChainId.unwrap(destChain),
            expiresAt: expiresAt,
            sender: address(0),
            recipient: address(0),
            payloadHash: keccak256(payload),
            payload: payload
        });

        Any2EVMMessage memory ccipMsg = Any2EVMMessage({
            messageId: msgId,
            sourceChainSelector: ccipSourceSelector,
            sender: abi.encode(sourceTransportAddress),
            data: abi.encode(tm),
            destTokenAmounts: new ICcipRouterClient.EVMTokenAmount[](0)
        });

        vm.prank(address(destRouter));
        destProvider.ccipReceive(ccipMsg);
    }

    function _nextNonce() internal returns (uint64) {
        return ++_nonce;
    }

    function _assertState(
        ITransferIntentManager manager,
        bytes32 intentId,
        ProtocolTypes.SettlementState expected,
        string memory label
    ) internal view {
        ProtocolTypes.SettlementState actual = manager.getSettlementState(intentId);
        require(
            uint256(actual) == uint256(expected),
            string.concat(label, ": expected state mismatch")
        );
        console.log("  [OK] %s", label);
    }

    // =========================================================================
    // Helpers: Printing
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
        console.log("|                    DEPLOYMENT SUMMARY                      |");
        console.log("+============================================================+");
        console.log("");
        console.log("-- Deployed Contract Addresses --");
        console.log("");
        console.log("  Source Chain (ChainId=%d):", ChainId.unwrap(SOURCE_CHAIN));
        console.log("    ERC-3643 Infrastructure:");
        console.log("      TrustedIssuersRegistry : %s", _addr(srcERC3643.trustedIssuersRegistry));
        console.log("      ClaimTopicsRegistry    : %s", _addr(srcERC3643.claimTopicsRegistry));
        console.log("      IdentityRegistryStorage: %s", _addr(srcERC3643.identityRegistryStorage));
        console.log("      IdentityRegistry       : %s", _addr(srcERC3643.identityRegistry));
        console.log("      ModularCompliance      : %s", _addr(srcERC3643.modularCompliance));
        console.log("      ClaimIssuer            : %s", _addr(srcERC3643.claimIssuer));
        console.log("      Token                  : %s", _addr(srcERC3643.token));
        console.log("    Protocol Contracts:");
        console.log("      ProtocolAccessManager  : %s", _addr(address(srcProtocol.accessManager)));
        console.log("      TransferIntentManager  : %s", _addr(address(srcProtocol.transferIntentManager)));
        console.log("      SettlementCoordinator  : %s", _addr(address(srcProtocol.settlementCoordinator)));
        console.log("      RuleEngineCompliance   : %s", _addr(address(srcProtocol.complianceProvider)));
        console.log("      ERC3643AssetAdapter    : %s", _addr(address(srcProtocol.assetAdapter)));
        console.log("      CCIPTransportProvider  : %s", _addr(address(srcProtocol.transportProvider)));
        console.log("      MockCCIPRouter         : %s", _addr(address(srcProtocol.router)));
        console.log("");
        console.log("  Destination Chain (ChainId=%d):", ChainId.unwrap(DEST_CHAIN));
        console.log("    ERC-3643 Infrastructure:");
        console.log("      TrustedIssuersRegistry : %s", _addr(dstERC3643.trustedIssuersRegistry));
        console.log("      ClaimTopicsRegistry    : %s", _addr(dstERC3643.claimTopicsRegistry));
        console.log("      IdentityRegistryStorage: %s", _addr(dstERC3643.identityRegistryStorage));
        console.log("      IdentityRegistry       : %s", _addr(dstERC3643.identityRegistry));
        console.log("      ModularCompliance      : %s", _addr(dstERC3643.modularCompliance));
        console.log("      ClaimIssuer            : %s", _addr(dstERC3643.claimIssuer));
        console.log("      Token                  : %s", _addr(dstERC3643.token));
        console.log("    Protocol Contracts:");
        console.log("      ProtocolAccessManager  : %s", _addr(address(dstProtocol.accessManager)));
        console.log("      TransferIntentManager  : %s", _addr(address(dstProtocol.transferIntentManager)));
        console.log("      SettlementCoordinator  : %s", _addr(address(dstProtocol.settlementCoordinator)));
        console.log("      RuleEngineCompliance   : %s", _addr(address(dstProtocol.complianceProvider)));
        console.log("      ERC3643AssetAdapter    : %s", _addr(address(dstProtocol.assetAdapter)));
        console.log("      CCIPTransportProvider  : %s", _addr(address(dstProtocol.transportProvider)));
        console.log("      MockCCIPRouter         : %s", _addr(address(dstProtocol.router)));
        console.log("");
        console.log("-- Investor Identities --");
        console.log("  Investor A: %s", _addr(INVESTOR_A));
        console.log("  Investor B: %s", _addr(INVESTOR_B));
        console.log("");
        console.log("-- ERC-3643 Token Balances --");
        console.log("  Source Token (%s):", _addr(srcERC3643.token));
        console.log("    Investor A: %d", ITokenVendor(srcERC3643.token).balanceOf(INVESTOR_A) / 1e18);
        console.log("  Dest Token (%s):", _addr(dstERC3643.token));
        console.log("    Investor B: %d", ITokenVendor(dstERC3643.token).balanceOf(INVESTOR_B) / 1e18);
        console.log("");
        console.log("-- Settlement Status --");
        ProtocolTypes.SettlementState srcState = srcProtocol.transferIntentManager.getSettlementState(
            keccak256(abi.encode(SOURCE_CHAIN, _nonce, INVESTOR_A, INVESTOR_B, TRANSFER_AMOUNT))
        );
        ProtocolTypes.SettlementState dstState = dstProtocol.transferIntentManager.getSettlementState(
            keccak256(abi.encode(SOURCE_CHAIN, _nonce, INVESTOR_A, INVESTOR_B, TRANSFER_AMOUNT))
        );
        console.log("  Source state: %s", _stateName(srcState));
        console.log("  Dest state:   %s", _stateName(dstState));
        console.log("");
        console.log("================================================================");
        console.log("  [OK] HAPPY-PATH SETTLEMENT COMPLETED SUCCESSFULLY");
        console.log("================================================================");
    }

    // =========================================================================
    // Helpers: Formatting
    // =========================================================================

    function _addr(address a) internal pure returns (string memory) {
        return vm.toString(a);
    }

    function _bytes32(bytes32 b) internal pure returns (string memory) {
        return vm.toString(b);
    }

    function _stateName(ProtocolTypes.SettlementState state) internal pure returns (string memory) {
        if (uint256(state) == 0) return "PENDING_VALIDATION";
        if (uint256(state) == 1) return "VALIDATED";
        if (uint256(state) == 2) return "RESERVED";
        if (uint256(state) == 3) return "SETTLED";
        if (uint256(state) == 4) return "REJECTED";
        if (uint256(state) == 5) return "EXPIRED";
        if (uint256(state) == 6) return "ROLLED_BACK";
        return "UNKNOWN";
    }

    function _deploy2(bytes memory bytecode, bytes32 salt) private returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "DeployLocal: CREATE2 failed");
    }
}
