// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ChainId} from "../contracts/common/ProtocolTypes.sol";

/// @title Config
/// @notice Shared constants for cross-chain deployment scripts.
library Config {
    // ── CCIP Chain Selectors (verified on-chain) ──
    uint64 internal constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
    uint64 internal constant FUJI_CHAIN_SELECTOR = 14767482510784806043;

    // ── CCIP Router Addresses (verified on-chain) ──
    address internal constant SEPOLIA_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;
    address internal constant FUJI_ROUTER = 0xF694E193200268f9a4868e4Aa017A0118C9a8177;

    // ── LINK Token Addresses ──
    address internal constant SEPOLIA_LINK = 0x779877A7B0D9E8603169DdbD7836e478b4624789;
    address internal constant FUJI_LINK = 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846;

    // ── Protocol Chain IDs (internal identifiers, not EVM chain IDs) ──
    ChainId internal constant SOURCE_CHAIN = ChainId.wrap(1);
    ChainId internal constant DEST_CHAIN = ChainId.wrap(2);

    // ── Fixed Protocol Addresses ──
    address internal constant ADMIN = address(0xA11CE);
    address internal constant COMPLIANCE_OP = address(0xCAFE);
    address internal constant BRIDGE_OP = address(0xB0B0B);
    address internal constant INVESTOR_A = address(0xAAA);
    address internal constant INVESTOR_B = address(0xBBB);

    // ── Asset Configuration ──
    bytes32 internal constant ASSET_ID = keccak256("RWA_TOKEN");
    bytes32 internal constant ASSET_TYPE = keccak256("BOND");
    bytes32 internal constant BURN_MINT = keccak256("BURN_MINT");
    bytes32 internal constant JURISDICTION_US = keccak256("US");
    bytes32 internal constant JURISDICTION_EU = keccak256("EU");

    // ── Token Configuration ──
    uint256 internal constant TOKEN_SUPPLY = 10_000 ether;
    uint256 internal constant TRANSFER_AMOUNT = 1_000 ether;

    // ── Claim Signer ──
    uint256 internal constant CLAIM_SIGNER_SK = 0xA11CE;
    uint256 internal constant CLAIM_TOPIC = 1;

    // ── LINK Funding Amount (for CCIP fees) ──
    uint256 internal constant LINK_FUND_AMOUNT = 5 ether;
}
