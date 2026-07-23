// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {VendorBytecode} from "../test/utils/VendorBytecode.sol";

interface IToken {
    function mint(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IIdentityRegistry {
    function registerIdentity(address user, address identity, uint16 country) external;
    function identity(address user) external view returns (address);
}

interface IIdentity {
    function addKey(bytes32 key, uint256 purpose, uint256 type_) external;
    function addClaim(uint256 topic, uint256 scheme, address issuer, bytes memory signature, bytes memory data, string memory uri) external;
}

contract MintTokens is Script {
    address constant TARGET       = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    address constant DEPLOYER     = 0x837171DCE4161927795c61524E92260b0BDaeB70;
    uint256 constant CLAIM_SIGNER_SK = 0xA11CE;
    uint256 constant CLAIM_TOPIC = 1;
    uint256 constant MINT_AMOUNT = 1_000 ether;

    // Deployed addresses (from DeployAll broadcasts)
    address constant SEPOLIA_TOKEN     = 0x9DbEB1bC4eB090a653F19d166eDE17A5BFFc896d;
    address constant SEPOLIA_IR        = 0x8F57bA9590ce0548003F49833572AF22dfc607C3;
    address constant SEPOLIA_CI        = 0x79226ED17cC1C909bc7BC097b236994A35a94667;
    uint256 constant SEPOLIA_SEED      = 1;

    address constant FUJI_TOKEN        = 0xf66ab3981E0479Be90866dBEB19a9662Eea8bba8;
    address constant FUJI_IR           = 0x4A17f653bdedF31fa8805B3A307E8F51B94e5268;
    address constant FUJI_CI           = 0xa698f1B58593066Efcc8Bc35Dc74E708E6Ce2edb;
    uint256 constant FUJI_SEED         = 2;

    function run() external {
        string memory chainLabel = vm.envString("CHAIN");

        address token;
        address identityRegistry;
        address claimIssuer;
        uint256 seed;

        if (keccak256(bytes(chainLabel)) == keccak256(bytes("sepolia"))) {
            token = SEPOLIA_TOKEN;
            identityRegistry = SEPOLIA_IR;
            claimIssuer = SEPOLIA_CI;
            seed = SEPOLIA_SEED;
        } else if (keccak256(bytes(chainLabel)) == keccak256(bytes("fuji"))) {
            token = FUJI_TOKEN;
            identityRegistry = FUJI_IR;
            claimIssuer = FUJI_CI;
            seed = FUJI_SEED;
        } else {
            revert(string.concat("Unknown chain: ", chainLabel));
        }

        console.log("=== %s ===", chainLabel);
        console.log("Token: %s", vm.toString(token));
        console.log("Target: %s", vm.toString(TARGET));

        // Check / register identity
        address existing = IIdentityRegistry(identityRegistry).identity(TARGET);
        if (existing != address(0)) {
            console.log("Identity exists: %s", vm.toString(existing));
        } else {
            console.log("No identity found - registering...");
            _registerIdentity(identityRegistry, claimIssuer, seed);
        }

        // Mint
        uint256 before = IToken(token).balanceOf(TARGET);
        console.log("Balance before: %d", before / 1e18);

        vm.broadcast();
        IToken(token).mint(TARGET, MINT_AMOUNT);

        uint256 balanceAfter = IToken(token).balanceOf(TARGET);
        console.log("Balance after: %d", balanceAfter / 1e18);
        console.log("[OK] Done");
    }

    function _registerIdentity(address identityRegistry, address claimIssuer, uint256 seed) internal {
        bytes32 salt = keccak256(abi.encode("inv", TARGET, seed));

        // Deploy identity ONCHAINID contract
        vm.broadcast();
        address identity;
        bytes memory idCode = abi.encodePacked(VendorBytecode.IDENTITY, abi.encode(DEPLOYER, false));
        assembly {
            identity := create2(0, add(idCode, 0x20), mload(idCode), salt)
        }
        console.log("Identity: %s", vm.toString(identity));
        require(identity != address(0), "CREATE2 failed");

        // Add claim signer key
        vm.broadcast();
        IIdentity(identity).addKey(keccak256(abi.encode(vm.addr(CLAIM_SIGNER_SK))), 3, 1);

        // Issue claim
        bytes32 dh = keccak256(abi.encode(identity, CLAIM_TOPIC, ""));
        bytes32 ph = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dh));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CLAIM_SIGNER_SK, ph);
        bytes memory sig = abi.encodePacked(r, s, v);

        console.log("ClaimIssuer: %s", vm.toString(claimIssuer));

        vm.broadcast();
        IIdentity(identity).addClaim(CLAIM_TOPIC, 1, claimIssuer, sig, "", "");

        // Register identity
        vm.broadcast();
        IIdentityRegistry(identityRegistry).registerIdentity(TARGET, identity, 840);
    }
}
