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
import {IERC3643TokenMinimal} from "../test/mocks/IERC3643TokenMinimal.sol";
import {VendorBytecode} from "../test/utils/VendorBytecode.sol";
import {Config} from "./Config.sol";

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
    ICcipRouterClient router;
}

// =============================================================================
// DeployBase - Shared deployment logic for testnet deployments
// =============================================================================
//
// Deploys the full protocol stack (ERC-3643 + Protocol) using real CCIP router.
// Subclasses (DeploySepolia, DeployFuji) provide chain-specific config.
// =============================================================================

abstract contract DeployBase is Script {

    // -- Abstract: chain-specific configuration --
    function _chainId() internal pure virtual returns (ChainId);
    function _ccipRouter() internal view virtual returns (ICcipRouterClient);
    function _linkToken() internal view virtual returns (address);
    function _chainLabel() internal pure virtual returns (string memory);
    function _remoteChainId() internal pure virtual returns (ChainId);
    function _remoteChainLabel() internal pure virtual returns (string memory);

    // -- Storage --
    ERC3643Stack internal erc3643;
    ProtocolStack internal protocol;
    address internal deployer;

    // =========================================================================
    // Entry Point
    // =========================================================================

    function _runDeployment() internal {
        deployer = msg.sender;

        console.log("+============================================================+");
        console.log("|  %s Deployment", _chainLabel());
        console.log("+============================================================+");
        console.log("");

        // -- Phase 1: Deploy ERC-3643 --
        _printPhaseHeader("PHASE 1", "Deploy & Configure ERC-3643 Ecosystem");
        erc3643 = _deployERC3643Stack();

        // -- Phase 2: Deploy Protocol --
        _printPhaseHeader("PHASE 2", "Deploy & Wire Protocol Contracts");
        protocol = _deployProtocolStack();

        // -- Phase 3: Configure --
        _printPhaseHeader("PHASE 3", "Configure Assets, Compliance & Transport");
        _configureProtocol();

        // -- Phase 4: Register Token Admin for CCIP --
        _printPhaseHeader("PHASE 4", "Register Token Admin for CCIP");
        _registerTokenAdmin();

        // -- Phase 5: Fund Transport with LINK --
        _printPhaseHeader("PHASE 5", "Fund TransportProvider with LINK");
        _fundTransportWithLINK();

        // -- Summary --
        _printSummary();
    }

    // =========================================================================
    // Phase 1: ERC-3643 Deployment
    // =========================================================================

    function _deployERC3643Stack() internal returns (ERC3643Stack memory stack) {
        console.log("-- Deploying %s ERC-3643 Stack --", _chainLabel());

        bytes32 chainSeed = bytes32(uint256(ChainId.unwrap(_chainId())));

        bytes32 saltTir = keccak256(abi.encode("erc3643-tir", chainSeed));
        bytes32 saltCtr = keccak256(abi.encode("erc3643-ctr", chainSeed));
        bytes32 saltIrs = keccak256(abi.encode("erc3643-irs", chainSeed));
        bytes32 saltIr  = keccak256(abi.encode("erc3643-ir",  chainSeed));
        bytes32 saltMc  = keccak256(abi.encode("erc3643-mc",  chainSeed));
        bytes32 saltCi  = keccak256(abi.encode("erc3643-ci",  chainSeed));
        bytes32 saltTok = keccak256(abi.encode("erc3643-tok", chainSeed));

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

        // ClaimIssuer (ONCHAINID)
        bytes memory ciArgs = abi.encode(deployer, false);
        bytes memory ciBytecode = abi.encodePacked(VendorBytecode.CLAIM_ISSUER, ciArgs);
        stack.claimIssuer = _deploy2(ciBytecode, saltCi);
        address signer = vm.addr(Config.CLAIM_SIGNER_SK);
        vm.prank(deployer);
        IClaimIssuer(stack.claimIssuer).addKey(keccak256(abi.encode(signer)), 3, 1);
        console.log("  ClaimIssuer:            %s", _addr(stack.claimIssuer));

        // ERC-3643 Token
        stack.token = _deploy2(VendorBytecode.TOKEN, saltTok);
        vm.prank(deployer);
        ITokenVendor(stack.token).init(
            stack.identityRegistry,
            stack.modularCompliance,
            "RWA",
            "RWA",
            18,
            address(0)
        );
        console.log("  Token:                  %s", _addr(stack.token));

        // Configure: add claim topic
        vm.prank(deployer);
        ICTR(stack.claimTopicsRegistry).addClaimTopic(Config.CLAIM_TOPIC);

        // Configure: add trusted issuer
        uint256[] memory topics = new uint256[](1);
        topics[0] = Config.CLAIM_TOPIC;
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

        // Unpause the token
        vm.prank(deployer);
        ITokenVendor(stack.token).unpause();

        stack.claimTopic = Config.CLAIM_TOPIC;

        // Create & register investor identities
        _createAndRegisterInvestor(stack, Config.INVESTOR_A, 840, "Investor A");
        _createAndRegisterInvestor(stack, Config.INVESTOR_B, 276, "Investor B");

        // Mint tokens to Investor A
        vm.prank(deployer);
        ITokenVendor(stack.token).mint(Config.INVESTOR_A, Config.TOKEN_SUPPLY);
        console.log("  Minted %d RWA tokens to Investor A", Config.TOKEN_SUPPLY / 1e18);
        console.log("");

        return stack;
    }

    function _createAndRegisterInvestor(
        ERC3643Stack memory stack,
        address investor,
        uint16 country,
        string memory label
    ) internal {
        bytes32 salt = keccak256(abi.encode("investor", investor, ChainId.unwrap(_chainId())));
        bytes memory idArgs = abi.encode(deployer, false);
        bytes memory idBytecode = abi.encodePacked(VendorBytecode.IDENTITY, idArgs);
        address identity = _deploy2(idBytecode, salt);

        vm.prank(deployer);
        IIdentityVendor(identity).addKey(keccak256(abi.encode(vm.addr(Config.CLAIM_SIGNER_SK))), 3, 1);

        _issueClaim(stack, identity);

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

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(Config.CLAIM_SIGNER_SK, prefixedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(deployer);
        IIdentityVendor(investorIdentity).addClaim(topic, 1, issuer, signature, data, "");
    }

    // =========================================================================
    // Phase 2: Protocol Deployment
    // =========================================================================

    function _deployProtocolStack() internal returns (ProtocolStack memory stack) {
        console.log("-- Deploying Protocol Stack (ChainId=%d) --", ChainId.unwrap(_chainId()));

        stack.router = _ccipRouter();
        uint256 nonceStart = vm.getNonce(deployer);

        // -- 1. ProtocolAccessManager (offset +0) --
        vm.startBroadcast(deployer);
        stack.accessManager = new ProtocolAccessManager(Config.ADMIN);
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
            _chainId()
        );
        vm.stopBroadcast();
        console.log("  ERC3643AssetAdapter:   %s", _addr(address(stack.assetAdapter)));

        // -- 5. Predict SettlementCoordinator address (offset +5) --
        // CCIPTransportProvider is at nonceStart + 4 (real router, not MockCCIPRouter)
        // SettlementCoordinator is at nonceStart + 5
        address predictedCoordinator = vm.computeCreateAddress(deployer, nonceStart + 5);

        // -- 6. CCIPTransportProvider (offset +4) --
        vm.startBroadcast(deployer);
        stack.transportProvider = new CCIPTransportProvider(
            IProtocolAccessManager(address(stack.accessManager)),
            ICcipRouterClient(address(stack.router)),
            ISettlementCoordinator(predictedCoordinator),
            address(0)
        );
        vm.stopBroadcast();
        console.log("  CCIPTransportProvider: %s", _addr(address(stack.transportProvider)));

        // -- 7. SettlementCoordinator (offset +5) --
        vm.startBroadcast(deployer);
        stack.settlementCoordinator = new SettlementCoordinator(
            IProtocolAccessManager(address(stack.accessManager)),
            _chainId(),
            ITransferIntentManager(address(stack.transferIntentManager)),
            ICompliancePolicyProvider(address(stack.complianceProvider)),
            IAssetAdapter(address(stack.assetAdapter)),
            ITransportProvider(address(stack.transportProvider))
        );
        vm.stopBroadcast();
        console.log("  SettlementCoordinator: %s", _addr(address(stack.settlementCoordinator)));

        // -- 8. Grant protocol roles --
        bytes32 bridgeRole = stack.accessManager.BRIDGE_ROLE();
        bytes32 complianceRole = stack.accessManager.COMPLIANCE_ROLE();
        vm.prank(Config.ADMIN);
        stack.accessManager.grantRole(bridgeRole, Config.BRIDGE_OP);
        vm.prank(Config.ADMIN);
        stack.accessManager.grantRole(bridgeRole, address(stack.settlementCoordinator));
        vm.prank(Config.ADMIN);
        stack.accessManager.grantRole(complianceRole, Config.COMPLIANCE_OP);
        console.log("  Roles granted: BRIDGE->%s, COMPLIANCE->%s, COORDINATOR->BRIDGE",
            _addr(Config.BRIDGE_OP), _addr(Config.COMPLIANCE_OP));

        console.log("");
        return stack;
    }

    // =========================================================================
    // Phase 3: Configure Protocol
    // =========================================================================

    function _configureProtocol() internal {
        console.log("-- Configuring Protocol --");

        // Grant asset adapter agent role on ERC-3643 token
        vm.prank(deployer);
        IERC3643TokenMinimal(erc3643.token).addAgent(address(protocol.assetAdapter));

        // Configure asset
        vm.prank(Config.COMPLIANCE_OP);
        protocol.assetAdapter.configureAsset(
            Config.ASSET_ID,
            erc3643.token,
            18,
            Config.ASSET_TYPE,
            Config.BURN_MINT,
            keccak256("T-REX:4.1.3")
        );
        console.log("  Asset configured: %s", _bytes32(Config.ASSET_ID));

        // Configure compliance
        vm.startPrank(Config.COMPLIANCE_OP);

        protocol.complianceProvider.setAllowedAsset(Config.ASSET_ID, true);
        protocol.complianceProvider.setAllowedAction(ProtocolTypes.IntentAction.TRANSFER, true);

        // Set chain jurisdictions
        protocol.complianceProvider.setChainJurisdiction(_chainId(), Config.JURISDICTION_US);
        protocol.complianceProvider.setChainJurisdiction(_remoteChainId(), Config.JURISDICTION_EU);

        // Set investor classifications (INSTITUTIONAL = 3)
        bytes32 senderHash = keccak256(abi.encode(Config.INVESTOR_A));
        bytes32 recipientHash = keccak256(abi.encode(Config.INVESTOR_B));
        protocol.complianceProvider.setInvestorClassification(senderHash, RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL);
        protocol.complianceProvider.setInvestorClassification(recipientHash, RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL);
        protocol.complianceProvider.setMinimumClassification(RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL);

        // Set generous limits
        protocol.complianceProvider.setMaxTransferAmount(Config.ASSET_ID, 100_000 ether);
        protocol.complianceProvider.setMaxHolding(Config.ASSET_ID, 1_000_000 ether);

        // Set policy version
        protocol.complianceProvider.setPolicyVersion(keccak256("POLICY:v1"));

        vm.stopPrank();
        console.log("  Compliance configured");

        // Configure transport
        _configureTransport();
        console.log("");
    }

    function _configureTransport() internal {
        address remoteTransport = _remoteTransportAddress();

        vm.startPrank(Config.BRIDGE_OP);

        protocol.transportProvider.setChainSelector(_chainId(), _ccipSelector());
        protocol.transportProvider.setChainSelector(_remoteChainId(), _remoteCcipSelector());

        if (remoteTransport != address(0)) {
            protocol.transportProvider.setAllowedSender(_remoteChainId(), remoteTransport, true);
            protocol.transportProvider.setRemoteReceiver(_remoteChainId(), remoteTransport);
        }

        vm.stopPrank();
        console.log("  Transport configured: chain selectors + remote receiver");
    }

    function _ccipSelector() internal pure virtual returns (uint64);
    function _remoteCcipSelector() internal pure virtual returns (uint64);
    function _remoteTransportAddress() internal view virtual returns (address);

    // =========================================================================
    // Phase 4: Register Token Admin for CCIP
    // =========================================================================

    function _registerTokenAdmin() internal {
        console.log("-- Registering Token Admin for CCIP --");

        // Approve LINK token for CCIP Router spending
        address linkToken = _linkToken();
        if (linkToken != address(0)) {
            vm.prank(deployer);
            _approveLINK(linkToken, address(_ccipRouter()), type(uint256).max);
            console.log("  LINK approved for Router: %s", _addr(address(_ccipRouter())));
        }

        // Register adapter as token admin in TokenAdminRegistry
        address tokenAdminRegistry = _getTokenAdminRegistry();
        if (tokenAdminRegistry != address(0)) {
            vm.prank(deployer);
            _registerAsAdmin(tokenAdminRegistry, erc3643.token, address(protocol.assetAdapter));
            console.log("  Adapter registered as token admin");
        }

        console.log("");
    }

    // =========================================================================
    // Phase 5: Fund TransportProvider with LINK
    // =========================================================================

    function _fundTransportWithLINK() internal {
        console.log("-- Funding TransportProvider with LINK --");

        address linkToken = _linkToken();
        if (linkToken != address(0)) {
            vm.prank(deployer);
            _transferLINK(linkToken, address(protocol.transportProvider), Config.LINK_FUND_AMOUNT);
            console.log("  Transferred %d LINK to TransportProvider", Config.LINK_FUND_AMOUNT / 1e18);
        }

        // Also fund with ETH for native gas
        vm.deal(address(protocol.transportProvider), 1 ether);
        console.log("  Funded TransportProvider with 1 ETH for native gas");

        console.log("");
    }

    // =========================================================================
    // Helpers: LINK Token Interactions
    // =========================================================================

    function _approveLINK(address linkToken, address spender, uint256 amount) internal {
        (bool success, ) = linkToken.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        require(success, "LINK approve failed");
    }

    function _transferLINK(address linkToken, address to, uint256 amount) internal {
        (bool success, ) = linkToken.call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(success, "LINK transfer failed");
    }

    function _getTokenAdminRegistry() internal view virtual returns (address) {
        // TokenAdminRegistry: Sepolia=0x9A9f2ccbfE2936223f312400dB614737F817c855
        //                     Fuji=0x4228F81c3AF0857E717B981bfb1874F4C0B39eF1
        return address(0); // Override in subclass
    }

    function _registerAsAdmin(address registry, address token, address admin) internal {
        (bool success, ) = registry.call(
            abi.encodeWithSignature("registerAdminViaRegister(address,address)", token, admin)
        );
        require(success, "Token admin registration failed");
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

    function _deploy2(bytes memory bytecode, bytes32 salt) private returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "DeployBase: CREATE2 failed");
    }

    function _printPhaseHeader(string memory phase, string memory title) internal pure {
        console.log("+============================================================+");
        console.log("|  %s: %s", phase, title);
        console.log("+============================================================+");
        console.log("");
    }

    function _printSummary() internal {
        console.log("+============================================================+");
        console.log("|  DEPLOYMENT SUMMARY: %s", _chainLabel());
        console.log("+============================================================+");
        console.log("");
        console.log("-- Deployed Addresses --");
        console.log("");
        console.log("  ERC-3643 Infrastructure:");
        console.log("    TrustedIssuersRegistry : %s", _addr(erc3643.trustedIssuersRegistry));
        console.log("    ClaimTopicsRegistry    : %s", _addr(erc3643.claimTopicsRegistry));
        console.log("    IdentityRegistryStorage: %s", _addr(erc3643.identityRegistryStorage));
        console.log("    IdentityRegistry       : %s", _addr(erc3643.identityRegistry));
        console.log("    ModularCompliance      : %s", _addr(erc3643.modularCompliance));
        console.log("    ClaimIssuer            : %s", _addr(erc3643.claimIssuer));
        console.log("    Token (RWA)            : %s", _addr(erc3643.token));
        console.log("");
        console.log("  Protocol Contracts:");
        console.log("    ProtocolAccessManager  : %s", _addr(address(protocol.accessManager)));
        console.log("    TransferIntentManager  : %s", _addr(address(protocol.transferIntentManager)));
        console.log("    SettlementCoordinator  : %s", _addr(address(protocol.settlementCoordinator)));
        console.log("    RuleEngineCompliance   : %s", _addr(address(protocol.complianceProvider)));
        console.log("    ERC3643AssetAdapter    : %s", _addr(address(protocol.assetAdapter)));
        console.log("    CCIPTransportProvider  : %s", _addr(address(protocol.transportProvider)));
        console.log("    CCIP Router            : %s", _addr(address(protocol.router)));
        console.log("");
        console.log("  Chain Selector: %d", ChainId.unwrap(_chainId()));
        console.log("  Remote Chain:   %s (ChainId=%d)", _remoteChainLabel(), ChainId.unwrap(_remoteChainId()));
        console.log("");
        console.log("  Investor A: %s", _addr(Config.INVESTOR_A));
        console.log("  Investor B: %s", _addr(Config.INVESTOR_B));
        console.log("");
        console.log("  RWA Token Balance (Investor A): %d",
            ITokenVendor(erc3643.token).balanceOf(Config.INVESTOR_A) / 1e18);
        console.log("");
        console.log("================================================================");
        console.log("  DEPLOYMENT COMPLETE: %s", _chainLabel());
        console.log("================================================================");
    }
}
