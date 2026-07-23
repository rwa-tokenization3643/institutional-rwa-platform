// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {VendorBytecode} from "../test/utils/VendorBytecode.sol";

contract ComputeAddrs is Script {
    address constant DEPLOYER = 0x837171DCE4161927795c61524E92260b0BDaeB70;

    function run() external {
        // DeployAll scripts use _salt(label) = keccak256(abi.encode(label, uint256(chainId)))
        // where chainId=1 for Sepolia (LOCAL in DeployAllSepolia = ChainId.wrap(1))
        // and   chainId=2 for Fuji   (LOCAL in DeployAllFuji   = ChainId.wrap(2))

        // ===== SEPOLIA (seed/chainId=1) =====
        _compute("Sepolia ClaimTopicsRegistry", VendorBytecode.CLAIM_TOPICS_REGISTRY, keccak256(abi.encode("ctr", uint256(1))));
        _compute("Sepolia ClaimIssuer",         abi.encodePacked(VendorBytecode.CLAIM_ISSUER, abi.encode(DEPLOYER, false)), keccak256(abi.encode("ci", uint256(1))));
        _compute("Sepolia IdentityRegistry",    VendorBytecode.IDENTITY_REGISTRY, keccak256(abi.encode("ir", uint256(1))));
        _compute("Sepolia ModularCompliance",   VendorBytecode.MODULAR_COMPLIANCE, keccak256(abi.encode("mc", uint256(1))));

        console.log("");

        // ===== FUJI (seed/chainId=2) =====
        _compute("Fuji ClaimTopicsRegistry", VendorBytecode.CLAIM_TOPICS_REGISTRY, keccak256(abi.encode("ctr", uint256(2))));
        _compute("Fuji ClaimIssuer",         abi.encodePacked(VendorBytecode.CLAIM_ISSUER, abi.encode(DEPLOYER, false)), keccak256(abi.encode("ci", uint256(2))));
        _compute("Fuji IdentityRegistry",    VendorBytecode.IDENTITY_REGISTRY, keccak256(abi.encode("ir", uint256(2))));
        _compute("Fuji ModularCompliance",   VendorBytecode.MODULAR_COMPLIANCE, keccak256(abi.encode("mc", uint256(2))));
    }

    function _compute(string memory label, bytes memory initCode, bytes32 salt) internal pure {
        address addr = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), DEPLOYER, salt, keccak256(initCode)
        )))));
        console.log("%s: %s", label, vm.toString(addr));
    }
}
