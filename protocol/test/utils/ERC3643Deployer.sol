// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {VendorBytecode} from "./VendorBytecode.sol";

interface ITIR {
    function init() external;
    function addTrustedIssuer(address _trustedIssuer, uint256[] memory _claimTopics) external;
}

interface ICTR {
    function init() external;
    function addClaimTopic(uint256 topic) external;
}

interface IIdentityRegistryStorage {
    function init() external;
}

interface IIR {
    function init(address tir, address ctr, address irs) external;
    function registerIdentity(address user, address identity, uint16 country) external;
}

interface IMC {
    function init() external;
}

interface IClaimIssuer {
    function addKey(bytes32 key, uint256 purpose, uint256 type_) external;
    function addAgent(address agent) external;
}

interface ITokenVendor {
    function init(address ir, address comp, string memory name, string memory symbol, uint8 decimals, address tre) external;
}

interface IIdentityVendor {
    function addKey(bytes32 key, uint256 purpose, uint256 type_) external;
    function addClaim(uint256 topic, uint256 scheme, address issuer, bytes memory signature, bytes memory data, string memory uri) external;
}

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

contract ERC3643Deployer is Test {
    uint256 constant CLAIM_SIGNER_SK = 0xA11CE;
    uint256 constant CLAIM_TOPIC = 1;

    function deployERC3643Stack() internal returns (ERC3643Stack memory stack) {
        return deployERC3643StackWithName("Protocol Token", "PTK", 18);
    }

    function deployERC3643StackWithName(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) internal returns (ERC3643Stack memory stack) {
        bytes32 saltTir = keccak256("erc3643-tir");
        bytes32 saltCtr = keccak256("erc3643-ctr");
        bytes32 saltIrs = keccak256("erc3643-irs");
        bytes32 saltIr  = keccak256("erc3643-ir");
        bytes32 saltMc  = keccak256("erc3643-mc");
        bytes32 saltCi  = keccak256("erc3643-ci");
        bytes32 saltTok = keccak256("erc3643-tok");

        stack.trustedIssuersRegistry = _deploy2(VendorBytecode.TRUSTED_ISSUERS_REGISTRY, saltTir);
        ITIR(stack.trustedIssuersRegistry).init();

        stack.claimTopicsRegistry = _deploy2(VendorBytecode.CLAIM_TOPICS_REGISTRY, saltCtr);
        ICTR(stack.claimTopicsRegistry).init();

        stack.identityRegistryStorage = _deploy2(VendorBytecode.IDENTITY_REGISTRY_STORAGE, saltIrs);
        IIdentityRegistryStorage(stack.identityRegistryStorage).init();

        stack.identityRegistry = _deploy2(VendorBytecode.IDENTITY_REGISTRY, saltIr);
        IIR(stack.identityRegistry).init(
            address(stack.trustedIssuersRegistry),
            address(stack.claimTopicsRegistry),
            address(stack.identityRegistryStorage)
        );

        stack.modularCompliance = _deploy2(VendorBytecode.MODULAR_COMPLIANCE, saltMc);
        IMC(stack.modularCompliance).init();

        bytes memory ciArgs = abi.encode(address(this), false);
        bytes memory ciBytecode = abi.encodePacked(VendorBytecode.CLAIM_ISSUER, ciArgs);
        stack.claimIssuer = _deploy2(ciBytecode, saltCi);

        address signer = vm.addr(CLAIM_SIGNER_SK);
        IClaimIssuer(stack.claimIssuer).addKey(keccak256(abi.encode(signer)), 3, 1);

        stack.token = _deploy2(VendorBytecode.TOKEN, saltTok);
        ITokenVendor(stack.token).init(
            address(stack.identityRegistry),
            address(stack.modularCompliance),
            name,
            symbol,
            decimals,
            address(0)
        );

        ICTR(stack.claimTopicsRegistry).addClaimTopic(CLAIM_TOPIC);
        IClaimIssuer(stack.claimIssuer).addAgent(address(this));

        stack.claimTopic = CLAIM_TOPIC;
    }

    function createAndRegisterInvestor(
        ERC3643Stack memory stack,
        address investorAddress,
        uint16 country
    ) internal returns (address investorIdentity) {
        bytes32 salt = keccak256(abi.encode("investor", investorAddress, block.timestamp));
        bytes memory idArgs = abi.encode(address(this), false);
        bytes memory idBytecode = abi.encodePacked(VendorBytecode.IDENTITY, idArgs);
        investorIdentity = _deploy2(idBytecode, salt);

        IIdentityVendor(investorIdentity).addKey(keccak256(abi.encode(address(this))), 3, 1);

        _issueClaim(stack, investorIdentity);

        IIR(stack.identityRegistry).registerIdentity(investorAddress, address(investorIdentity), country);
    }

    function _issueClaim(ERC3643Stack memory stack, address investor) internal {
        address issuer = stack.claimIssuer;
        uint256 topic = stack.claimTopic;
        bytes memory data = "";

        bytes32 dataHash = keccak256(abi.encode(investor, topic, data));
        bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dataHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CLAIM_SIGNER_SK, prefixedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        IIdentityVendor(investor).addClaim(topic, 1, issuer, signature, data, "");
    }

    function _deploy2(bytes memory bytecode, bytes32 salt) private returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "ERC3643Deployer: create2 failed");
    }
}
