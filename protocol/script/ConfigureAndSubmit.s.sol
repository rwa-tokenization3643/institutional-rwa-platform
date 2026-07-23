// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {Config} from "./Config.sol";

interface ITransportConfig {
    function setRemoteReceiver(ChainId chainId, address receiver) external;
    function setAllowedSender(ChainId chainId, address sender, bool allowed) external;
    function estimateFee(ChainId destinationChain, ProtocolTypes.TransportMessage calldata message) external view returns (uint256);
}

interface IComplianceConfig {
    function setInvestorClassification(bytes32 identityHash, uint8 classification) external;
}

interface ISettlement {
    function submitTransfer(ProtocolTypes.TransferIntent calldata intent) external returns (bytes32);
}

interface IToken {
    function balanceOf(address) external view returns (uint256);
}

contract ConfigureAndSubmit is Script {
    address constant WALLET = 0x837171DCE4161927795c61524E92260b0BDaeB70;

    // Sepolia
    address constant SEPOLIA_TRANSPORT = 0x43047aF394581c49516c35020E01D7E3966750aA;
    address constant SEPOLIA_SETTLEMENT = 0xB794860a84400bc71a069C216dDD2c4F8Fb3a42a;
    address constant SEPOLIA_COMPLIANCE = 0x7a237aC13E0Df03Fae5d21025C2265C97ec436De;
    address constant SEPOLIA_TOKEN = 0x9DbEB1bC4eB090a653F19d166eDE17A5BFFc896d;

    // Fuji
    address constant FUJI_TRANSPORT = 0xa0633079CeB2df8543B5a1e715d87949344BB7D2;
    address constant FUJI_SETTLEMENT = 0x1D4483E5D293B25Ea95fF97d8f49D278eC6596b9;
    address constant FUJI_COMPLIANCE = 0xdBA28eC39075d67a56bbF0B4ed3fc6a11f9370e5;
    address constant FUJI_TOKEN = 0xf66ab3981E0479Be90866dBEB19a9662Eea8bba8;

    function run() external {
        string memory chain = vm.envString("CHAIN");

        bytes32 identityHash = keccak256(abi.encode(WALLET));
        uint8 institutional = 3;

        if (keccak256(bytes(chain)) == keccak256(bytes("sepolia"))) {
            _configureSepolia(identityHash, institutional);
        } else if (keccak256(bytes(chain)) == keccak256(bytes("fuji"))) {
            _configureFuji(identityHash, institutional);
        } else {
            revert(string.concat("Unknown chain: ", chain));
        }
    }

    function _configureSepolia(bytes32 identityHash, uint8 institutional) internal {
        console.log("=== Sepolia: Configure + Submit ===");

        vm.startBroadcast();

        // 1. Configure transport for Fuji
        ITransportConfig(SEPOLIA_TRANSPORT).setRemoteReceiver(Config.DEST_CHAIN, FUJI_TRANSPORT);
        ITransportConfig(SEPOLIA_TRANSPORT).setAllowedSender(Config.DEST_CHAIN, FUJI_TRANSPORT, true);

        // 2. Classify wallet
        IComplianceConfig(SEPOLIA_COMPLIANCE).setInvestorClassification(identityHash, institutional);

        // 3. Submit transfer intent
        uint256 amount = 100 ether;
        uint64 nonce = 4;
        bytes32 intentId = keccak256(abi.encode(Config.SOURCE_CHAIN, nonce, WALLET, WALLET, amount));

        ProtocolTypes.TransferIntent memory intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: WALLET,
            recipient: WALLET,
            senderIdentityHash: identityHash,
            recipientIdentityHash: identityHash,
            assetId: Config.ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: ChainId.unwrap(Config.SOURCE_CHAIN),
            destinationChainId: ChainId.unwrap(Config.DEST_CHAIN),
            amount: amount,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });

        ISettlement(SEPOLIA_SETTLEMENT).submitTransfer(intent);

        vm.stopBroadcast();

        console.log("Transport configured (remoteReceiver + allowedSender)");
        console.log("Wallet classified as INSTITUTIONAL");
        console.log("Transfer submitted: %d RWA, intentId=%s", amount / 1e18, vm.toString(intentId));

        uint256 bal = IToken(SEPOLIA_TOKEN).balanceOf(WALLET);
        console.log("Sepolia RWA balance: %d", bal / 1e18);
    }

    function _configureFuji(bytes32 identityHash, uint8 institutional) internal {
        console.log("=== Fuji: Configure ===");

        vm.startBroadcast();

        // 1. Configure transport for Sepolia
        ITransportConfig(FUJI_TRANSPORT).setRemoteReceiver(Config.SOURCE_CHAIN, SEPOLIA_TRANSPORT);
        ITransportConfig(FUJI_TRANSPORT).setAllowedSender(Config.SOURCE_CHAIN, SEPOLIA_TRANSPORT, true);

        // 2. Classify wallet
        IComplianceConfig(FUJI_COMPLIANCE).setInvestorClassification(identityHash, institutional);

        vm.stopBroadcast();

        console.log("Transport configured (remoteReceiver + allowedSender)");
        console.log("Wallet classified as INSTITUTIONAL");

        uint256 bal = IToken(FUJI_TOKEN).balanceOf(WALLET);
        console.log("Fuji RWA balance: %d", bal / 1e18);
    }
}
