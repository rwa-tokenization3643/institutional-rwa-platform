// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {ProtocolAccessManager} from "../contracts/access/ProtocolAccessManager.sol";
import {IProtocolAccessManager} from "../contracts/access/IProtocolAccessManager.sol";
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
import {IERC3643TokenMinimal} from "../test/mocks/IERC3643TokenMinimal.sol";
import {VendorBytecode} from "../test/utils/VendorBytecode.sol";
import {Config} from "./Config.sol";

interface ITIR { function init() external; function addTrustedIssuer(address,uint256[] memory) external; }
interface ICTR { function init() external; function addClaimTopic(uint256) external; }
interface IIRS { function init() external; function bindIdentityRegistry(address) external; }
interface IIR { function init(address,address,address) external; function registerIdentity(address,address,uint16) external; function addAgent(address) external; }
interface IMC { function init() external; }
interface IClaimIssuer { function addKey(bytes32,uint256,uint256) external; }
interface ITokenVendor { function init(address,address,string memory,string memory,uint8,address) external; function addAgent(address) external; function unpause() external; function mint(address,uint256) external; }
interface IIdentityVendor { function addKey(bytes32,uint256,uint256) external; function addClaim(uint256,uint256,address,bytes memory,bytes memory,string memory) external; }

contract DeployAllFuji is Script {
    address constant ROUTER = 0xF694E193200268f9a4868e4Aa017A0118C9a8177;
    address constant LINK   = 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846;
    address constant TAR    = 0x4228f81c3af0857e717B981BfB1874f4c0b39EF1;
    address constant TOKEN  = 0xf66ab3981E0479Be90866dBEB19a9662Eea8bba8;
    ChainId constant LOCAL  = ChainId.wrap(2);
    ChainId constant REMOTE = ChainId.wrap(1);

    address deployer;

    function run() external {
        deployer = msg.sender;
        console.log("=== Fuji ===");
        address token = _erc3643();
        (ProtocolAccessManager pam, SettlementCoordinator coord, CCIPTransportProvider transport, ERC3643AssetAdapter adapter, RuleEngineComplianceProvider comp) = _protocol();
        _configure(pam, coord, transport, adapter, comp, token);
        _fund(address(transport));
        console.log("Done");
    }

    function _create2(bytes memory code, bytes32 s) internal returns (address a) {
        assembly { a := create2(0, add(code, 0x20), mload(code), s) }
        require(a != address(0), "C2");
    }
    function _salt(string memory label) internal view returns (bytes32) {
        return keccak256(abi.encode(label, uint256(2)));
    }

    function _erc3643() internal returns (address token) {
        address tir; address ctr; address irs; address ir; address mc; address ci;

        vm.startBroadcast(deployer); tir = _create2(VendorBytecode.TRUSTED_ISSUERS_REGISTRY, _salt("tir")); ITIR(tir).init(); vm.stopBroadcast();
        vm.startBroadcast(deployer); ctr = _create2(VendorBytecode.CLAIM_TOPICS_REGISTRY, _salt("ctr")); ICTR(ctr).init(); vm.stopBroadcast();
        vm.startBroadcast(deployer); irs = _create2(VendorBytecode.IDENTITY_REGISTRY_STORAGE, _salt("irs")); IIRS(irs).init(); vm.stopBroadcast();
        vm.startBroadcast(deployer); ir = _create2(VendorBytecode.IDENTITY_REGISTRY, _salt("ir")); IIR(ir).init(tir, ctr, irs); vm.stopBroadcast();
        vm.startBroadcast(deployer); mc = _create2(VendorBytecode.MODULAR_COMPLIANCE, _salt("mc")); IMC(mc).init(); vm.stopBroadcast();
        vm.startBroadcast(deployer); ci = _create2(abi.encodePacked(VendorBytecode.CLAIM_ISSUER, abi.encode(deployer, false)), _salt("ci")); IClaimIssuer(ci).addKey(keccak256(abi.encode(vm.addr(Config.CLAIM_SIGNER_SK))), 3, 1); vm.stopBroadcast();

        token = TOKEN;
        vm.startBroadcast(deployer);
        ICTR(ctr).addClaimTopic(Config.CLAIM_TOPIC);
        uint256[] memory topics = new uint256[](1); topics[0] = Config.CLAIM_TOPIC;
        ITIR(tir).addTrustedIssuer(ci, topics); IIRS(irs).bindIdentityRegistry(ir);
        ITokenVendor(token).init(ir, mc, "RWA", "RWA", 18, address(0));
        ITokenVendor(token).addAgent(deployer); IIR(ir).addAgent(deployer); ITokenVendor(token).unpause();
        vm.stopBroadcast();

        _identity(ir, ci, Config.INVESTOR_A, 840);
        _identity(ir, ci, Config.INVESTOR_B, 276);
        vm.startBroadcast(deployer); ITokenVendor(token).mint(Config.INVESTOR_A, Config.TOKEN_SUPPLY); vm.stopBroadcast();
    }

    function _identity(address ir, address ci, address user, uint16 country) internal {
        bytes32 s = keccak256(abi.encode("inv", user, uint256(2)));
        vm.startBroadcast(deployer);
        address id = _create2(abi.encodePacked(VendorBytecode.IDENTITY, abi.encode(deployer, false)), s);
        IIdentityVendor(id).addKey(keccak256(abi.encode(vm.addr(Config.CLAIM_SIGNER_SK))), 3, 1);
        bytes32 dh = keccak256(abi.encode(id, Config.CLAIM_TOPIC, ""));
        bytes32 ph = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dh));
        (uint8 v, bytes32 r, bytes32 s2) = vm.sign(Config.CLAIM_SIGNER_SK, ph);
        IIdentityVendor(id).addClaim(Config.CLAIM_TOPIC, 1, ci, abi.encodePacked(r, s2, v), "", "");
        IIR(ir).registerIdentity(user, id, country);
        vm.stopBroadcast();
    }

    function _protocol() internal returns (ProtocolAccessManager pam, SettlementCoordinator coord, CCIPTransportProvider transport, ERC3643AssetAdapter adapter, RuleEngineComplianceProvider comp) {
        uint256 nonce = vm.getNonce(deployer);
        vm.startBroadcast(deployer); pam = new ProtocolAccessManager(deployer); vm.stopBroadcast();
        vm.startBroadcast(deployer); TransferIntentManager tim = new TransferIntentManager(IProtocolAccessManager(address(pam))); vm.stopBroadcast();
        vm.startBroadcast(deployer); comp = new RuleEngineComplianceProvider(IProtocolAccessManager(address(pam))); vm.stopBroadcast();
        vm.startBroadcast(deployer); adapter = new ERC3643AssetAdapter(IProtocolAccessManager(address(pam)), LOCAL); vm.stopBroadcast();
        address predicted = vm.computeCreateAddress(deployer, nonce + 5);
        vm.startBroadcast(deployer); transport = new CCIPTransportProvider(IProtocolAccessManager(address(pam)), ICcipRouterClient(ROUTER), ISettlementCoordinator(predicted), address(0)); vm.stopBroadcast();
        vm.startBroadcast(deployer); coord = new SettlementCoordinator(IProtocolAccessManager(address(pam)), LOCAL, ITransferIntentManager(address(tim)), ICompliancePolicyProvider(address(comp)), IAssetAdapter(address(adapter)), ITransportProvider(address(transport))); vm.stopBroadcast();

        bytes32 bridge = pam.BRIDGE_ROLE(); bytes32 compRole = pam.COMPLIANCE_ROLE();
        vm.startBroadcast(deployer);
        pam.grantRole(bridge, Config.BRIDGE_OP); pam.grantRole(bridge, address(coord)); pam.grantRole(bridge, deployer);
        pam.grantRole(compRole, Config.COMPLIANCE_OP); pam.grantRole(compRole, deployer);
        vm.stopBroadcast();
    }

    function _configure(ProtocolAccessManager pam, SettlementCoordinator coord, CCIPTransportProvider transport, ERC3643AssetAdapter adapter, RuleEngineComplianceProvider comp, address token) internal {
        vm.startBroadcast(deployer);
        IERC3643TokenMinimal(token).addAgent(address(adapter));
        adapter.configureAsset(Config.ASSET_ID, token, 18, Config.ASSET_TYPE, Config.BURN_MINT, keccak256("T-REX:4.1.3"));
        vm.stopBroadcast();

        vm.startBroadcast(deployer);
        comp.setAllowedAsset(Config.ASSET_ID, true);
        comp.setAllowedAction(ProtocolTypes.IntentAction.TRANSFER, true);
        comp.setChainJurisdiction(LOCAL, Config.JURISDICTION_EU);
        comp.setChainJurisdiction(REMOTE, Config.JURISDICTION_US);
        comp.setInvestorClassification(keccak256(abi.encode(Config.INVESTOR_A)), RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL);
        comp.setInvestorClassification(keccak256(abi.encode(Config.INVESTOR_B)), RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL);
        comp.setMinimumClassification(RuleEngineComplianceProvider.InvestorClassification.INSTITUTIONAL);
        comp.setMaxTransferAmount(Config.ASSET_ID, 100_000 ether);
        comp.setMaxHolding(Config.ASSET_ID, 1_000_000 ether);
        comp.setPolicyVersion(keccak256("POLICY:v1"));
        vm.stopBroadcast();

        vm.startBroadcast(deployer);
        transport.setChainSelector(LOCAL, Config.FUJI_CHAIN_SELECTOR);
        transport.setChainSelector(REMOTE, Config.SEPOLIA_CHAIN_SELECTOR);
        address remoteTransport;
        try vm.envAddress("SEPOLIA_TRANSPORT") returns (address addr) {
            remoteTransport = addr;
        } catch {
            remoteTransport = address(0);
        }
        if (remoteTransport != address(0)) {
            transport.setAllowedSender(REMOTE, remoteTransport, true);
            transport.setRemoteReceiver(REMOTE, remoteTransport);
        }
        vm.stopBroadcast();

        vm.startBroadcast(deployer);
        (bool ok,) = LINK.call(abi.encodeWithSignature("approve(address,uint256)", ROUTER, type(uint256).max)); require(ok, "app LINK");
        (ok,) = TAR.call(abi.encodeWithSignature("registerAdminViaRegister(address,address)", token, address(adapter))); require(ok, "reg admin");
        vm.stopBroadcast();
    }

    function _fund(address transport) internal {
        vm.startBroadcast(deployer);
        (bool ok,) = LINK.call(abi.encodeWithSignature("transfer(address,uint256)", transport, Config.LINK_FUND_AMOUNT)); require(ok, "LINK xfer");
        (ok,) = payable(transport).call{value: 0.5 ether}(""); require(ok, "AVAX xfer");
        vm.stopBroadcast();
    }
}
