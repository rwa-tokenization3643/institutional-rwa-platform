// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IProtocolAccessManager} from "../access/IProtocolAccessManager.sol";
import {IAssetAdapter} from "../interfaces/IAssetAdapter.sol";
import {ProtocolTypes, ChainId} from "../common/ProtocolTypes.sol";

// =============================================================================
// Vendor Compatibility Interfaces
// =============================================================================
//
// The vendored ERC-3643 (T-REX) contracts use the exact Solidity version
// `pragma solidity 0.8.17`. The protocol uses `pragma solidity ^0.8.30`.
// Solidity does not allow source files with different exact-pragma versions
// to be compiled together — the compiler selects a single version and rejects
// files that do not satisfy it.
//
// Because of this incompatibility, this adapter CANNOT import the vendor's
// `IToken.sol`, `IIdentityRegistry.sol`, or `IModularCompliance.sol`
// interfaces directly. Instead, it declares minimal compatibility interfaces
// below that include ONLY the functions this adapter actually calls.
//
// This is compliant with Extension Rule 4 ("Use Public Interfaces Only") —
// the adapter still calls vendor contracts through Solidity interfaces;
// it simply re-declares the relevant function signatures locally because
// the vendor's own interface files are not importable at compile time.
//
// If the vendor updates to a Solidity version compatible with the protocol,
// these local interfaces should be deleted and replaced with direct imports
// from `vendor/erc3643/contracts/token/IToken.sol` (and related files).
//
// References:
//   Vendor IToken interface:  vendor/erc3643/contracts/token/IToken.sol
//   Vendor IIdentityRegistry: vendor/erc3643/contracts/registry/interface/IIdentityRegistry.sol
//   Vendor IModularCompliance: vendor/erc3643/contracts/compliance/modular/IModularCompliance.sol
//   All use pragma solidity 0.8.17 (exact).
// =============================================================================

/// @notice Minimal ERC-3643 Token interface for use by this adapter.
/// @dev Declares only the functions the adapter calls on the Token contract.
///      Vendor `IToken.sol` (0.8.17) is not importable at protocol pragma.
interface IERC3643Token {
    /// @notice Mints `amount` tokens to `to`.
    /// @dev Agent-only on the Token contract. Reverts if the recipient is
    ///      not verified in the IdentityRegistry or if compliance forbids it.
    function mint(address to, uint256 amount) external;

    /// @notice Burns `amount` tokens from `account`.
    /// @dev Agent-only on the Token contract.
    function burn(address account, uint256 amount) external;

    /// @notice Returns the token balance of `account`.
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Minimal Identity Registry interface for use by this adapter.
/// @dev Vendor `IIdentityRegistry.sol` (0.8.17) is not importable.
interface IIdentityRegistryMinimal {
    /// @notice Returns whether a wallet has a verified identity.
    function isVerified(address userAddress) external view returns (bool);
}

/// @notice Minimal Modular Compliance interface for use by this adapter.
/// @dev Vendor `IModularCompliance.sol` (0.8.17) is not importable.
interface IModularComplianceMinimal {
    /// @notice Checks whether a transfer is compliant.
    function canTransfer(address from, address to, uint256 amount) external view returns (bool);
}

// =============================================================================
// Settlement Model Identifiers
// =============================================================================
//
// These constants identify the settlement strategy for an asset. The adapter
// dispatches settlement operations internally based on the model configured
// in AssetConfig.settlementModel.
//
// Only BURN_MINT is implemented in this version.
// =============================================================================

// Burn tokens on source, mint on destination (standard cross-chain).
bytes32 constant SETTLEMENT_MODEL_BURN_MINT = keccak256("BURN_MINT");
// Lock tokens on source, mint on destination (future).
bytes32 constant SETTLEMENT_MODEL_LOCK_MINT = keccak256("LOCK_MINT");
// Lock on source, unlock on destination (future).
bytes32 constant SETTLEMENT_MODEL_LOCK_UNLOCK = keccak256("LOCK_UNLOCK");
// Escrow on source, release on destination (future).
bytes32 constant SETTLEMENT_MODEL_ESCROW_RELEASE = keccak256("ESCROW_RELEASE");

// =============================================================================
// ERC3643AssetAdapter
// =============================================================================
//
// ── Role ──
//
// This adapter is an Asset Service. It translates the protocol's generic
// IAssetAdapter interface into concrete ERC-3643 (T-REX) operations. The
// SettlementCoordinator communicates ONLY through IAssetAdapter and never
// interacts with ERC-3643 contracts directly.
//
// ── What the adapter owns ──
//
//   * Asset configuration (token, registry, compliance addresses per chain)
//   * Vendor contract integration (ERC-3643, ONCHAINID via registries)
//   * Reservation strategy (temporary internal accounting)
//   * Settlement strategy (dispatch by settlement model)
//   * Recovery strategy (isolated helpers for future RecoveryManager reuse)
//
// ── What the adapter does NOT own ──
//
//   * Compliance policy (handled by ICompliancePolicyProvider)
//   * Settlement orchestration (handled by SettlementCoordinator)
//   * Cross-chain transport (handled by ITransportProvider)
//   * Transfer intent persistence (handled by ITransferIntentManager)
//
// ── Settlement Model Dispatch ──
//
// Each asset config specifies a settlementModel. The adapter dispatches
// mint/burn/reserve operations through internal helpers that switch on the
// model. Currently only BURN_MINT is implemented. Future models (LOCK_MINT,
// LOCK_UNLOCK, ESCROW_RELEASE) will be added without changing the public
// IAssetAdapter interface.
//
// ── Reservation Strategy ──
//
// ERC-3643 does not natively support token reservations or locks. The current
// reservation strategy uses internal accounting: an intentId-keyed mapping
// stores the sender, amount, and assetId. The sender's reserved balance is
// tracked globally per (assetId, account). No tokens are moved during
// reservation.
//
// This is a TEMPORARY reservation strategy. A future Reservation Extension
// contract should replace internal accounting with a dedicated lock vault or
// escrow contract. The Reservation types and helpers are designed so the
// strategy can be extracted into an independent contract without changing
// the adapter's public API.
//
// ── Recovery Strategy ──
//
// Recovery operations are isolated in private helpers (_recoverRollback,
// _recoverRelease). Future RecoveryManager code should call these helpers
// rather than duplicating the logic. The current design separates recovery
// from settlement so each can evolve independently.
//
// ── Multi-Chain Design ──
//
// Asset configs are keyed by (assetId, chainId). Each adapter deployment
// serves exactly one chain (the immutable _chainId). The same asset on
// two different chains requires two separate AssetConfig entries (one per
// chain), each pointing to the correct ERC-3643 token contract on that
// chain. This design supports future deployments where the same protocol
// asset uses different ERC-3643 token contracts on different chains.
//
// ── Access Control ──
//
// All settlement operations are gated to BRIDGE_ROLE. Asset configuration
// is gated to COMPLIANCE_ROLE. The adapter uses ProtocolAccessManager and
// does NOT use Ownable. The adapter itself must be granted AGENT_ROLE on
// each ERC-3643 Token contract it manages.
//
// ── Assumptions ──
//
//   * The ERC-3643 Token contract is deployed and configured with an
//     IdentityRegistry and Compliance contract.
//   * The adapter has been granted AGENT_ROLE on the Token contract.
//   * Recipient addresses are verified in the IdentityRegistry before
//     mintAssets is called (enforced by the Token itself).
//   * ERC-3643 does not support partitions. supportsPartition returns true
//     only for bytes32(0).
//   * All token amounts use the token's native base units (wei-equivalent).
//
// ── Limitations ──
//
//   * Reservation is NOT on-chain escrow. If the sender transfers tokens
//     via Token.transfer() or forcedTransfer() between reservation and burn,
//     the burn will revert with insufficient balance.
//   * The adapter does not verify identity or compliance — it relies on the
//     ERC-3643 Token's built-in checks.
//   * Only BURN_MINT settlement model is implemented.
// =============================================================================
contract ERC3643AssetAdapter is IAssetAdapter, ERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // Errors
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Replace with ProtocolErrors.sol

    /// @dev Zero address where a non-zero is required.
    error ERC3643Adapter__ZeroAddress();

    /// @dev Zero bytes32 where a non-zero is required.
    error ERC3643Adapter__ZeroAssetId();

    /// @dev The asset is not registered on the given chain.
    error ERC3643Adapter__AssetNotFound(bytes32 assetId, ChainId chainId);

    /// @dev The asset is already registered for the given chain.
    error ERC3643Adapter__AssetAlreadyRegistered(bytes32 assetId, ChainId chainId);

    /// @dev No reservation exists for the given intentId.
    error ERC3643Adapter__ReservationNotFound(bytes32 intentId);

    /// @dev The reservation data does not match the intent.
    error ERC3643Adapter__ReservationMismatch(bytes32 intentId);

    /// @dev The caller does not have the required role.
    error ERC3643Adapter__Unauthorized(address caller, bytes32 requiredRole);

    /// @dev The settlement model is not implemented or not recognised.
    error ERC3643Adapter__UnsupportedSettlementModel(bytes32 model);

    /// @dev The reservation strategy does not match the settlement model.
    error ERC3643Adapter__InvalidReservationState(bytes32 intentId);

    /// @dev An operation that is not yet implemented for the given model was called.
    error ERC3643Adapter__NotImplemented(bytes32 settlementModel, string operation);

    // ═══════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Replace with ProtocolEvents.sol

    /// @dev Emitted when an asset is configured on this adapter for a chain.
    event AssetConfigured(
        bytes32 indexed assetId,
        ChainId indexed chainId,
        address indexed token,
        bytes32 settlementModel
    );

    /// @dev Emitted when tokens are reserved for a transfer intent.
    event AssetReserved(
        bytes32 indexed intentId,
        address indexed sender,
        bytes32 indexed assetId,
        uint256 amount
    );

    /// @dev Emitted when a reservation is released without burn.
    event ReservationReleased(bytes32 indexed intentId);

    /// @dev Emitted when reserved tokens are burned after settlement ack.
    event ReservedBurnConfirmed(
        bytes32 indexed intentId,
        address indexed sender,
        uint256 amount
    );

    /// @dev Emitted when tokens are minted to a recipient.
    event MintConfirmed(
        bytes32 indexed intentId,
        address indexed recipient,
        uint256 amount
    );

    /// @dev Emitted when tokens are re-minted to the sender during rollback.
    event RollbackMintConfirmed(
        bytes32 indexed intentId,
        address indexed sender,
        uint256 amount
    );

    // ═══════════════════════════════════════════════════════════════════════
    // Types
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Full configuration for an asset on a specific chain.
    /// @dev Keyed by (assetId, chainId). Each chain requires a separate entry
    ///      because the same protocol asset may use different ERC-3643 token
    ///      contracts and registries on different chains.
    /// @param token           The ERC-3643 token contract address on this chain.
    /// @param identityRegistry The IdentityRegistry contract address linked
    ///                         to the token on this chain.
    /// @param compliance      The ModularCompliance contract address linked
    ///                        to the token on this chain.
    /// @param decimals        Token decimals (for off-chain display).
    /// @param assetType       Asset classification (e.g. keccak256("EQUITY"),
    ///                        keccak256("BOND"), keccak256("REAL_ESTATE")).
    /// @param settlementModel The settlement strategy identifier (e.g. BURN_MINT).
    /// @param vendorVersion   Vendor software version (e.g. keccak256("T-REX:4.1.6")).
    struct AssetConfig {
        address token;
        address identityRegistry;
        address compliance;
        uint8 decimals;
        bytes32 assetType;
        bytes32 settlementModel;
        bytes32 vendorVersion;
    }

    /// @notice A single reservation for a transfer intent.
    /// @dev Cleared after the reservation is burned or released.
    ///      This struct and its storage layout are designed so the reservation
    ///      strategy can be extracted into a standalone contract in the future.
    /// @param sender  The token holder whose tokens are reserved.
    /// @param amount  The amount of tokens reserved.
    /// @param assetId The protocol-level asset identifier.
    struct Reservation {
        address sender;
        uint256 amount;
        bytes32 assetId;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Version of this adapter implementation.
    bytes32 public constant ADAPTER_VERSION = keccak256("ERC3643AssetAdapter:1.0.0");

    /// @notice Unique identifier for this adapter type.
    bytes32 public constant ADAPTER_ID = keccak256("ERC3643AssetAdapter");

    // ═══════════════════════════════════════════════════════════════════════
    // Immutable State
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Protocol-wide access manager.
    IProtocolAccessManager private immutable _accessManager;

    /// @dev The chain this adapter deployment serves. Every config is keyed
    ///      by (assetId, _chainId).
    ChainId private immutable _chainId;

    // ═══════════════════════════════════════════════════════════════════════
    // Mutable State
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Asset configurations keyed by (assetId, chainId).
    mapping(bytes32 assetId => mapping(ChainId chainId => AssetConfig)) private _configs;

    /// @dev Reverse lookup: token address → assetId.
    mapping(address token => bytes32 assetId) private _tokenAssets;

    /// @dev Active reservations keyed by intentId.
    ///      TEMPORARY — will be replaced by a Reservation Extension contract.
    mapping(bytes32 intentId => Reservation) private _reservations;

    /// @dev Total reserved amount per (assetId, account).
    ///      Used to compute reservedBalance and availableBalance.
    mapping(bytes32 assetId => mapping(address account => uint256)) private _reservedBalances;

    // ═══════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Configures the adapter with the protocol access manager and
    ///         the chain this deployment serves.
    /// @dev The chainId is immutable — each adapter deployment serves exactly
    ///      one chain. All asset configs are keyed by this chainId internally.
    /// @param accessManager The protocol-wide access manager contract.
    /// @param chainId       The protocol-level identifier of the chain where
    ///                      this adapter is deployed.
    constructor(IProtocolAccessManager accessManager, ChainId chainId) {
        if (address(accessManager) == address(0)) {
            revert ERC3643Adapter__ZeroAddress();
        }
        _accessManager = accessManager;
        _chainId = chainId;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IERC165
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IAssetAdapter).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration (Non-Interface)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // These functions are NOT part of IAssetAdapter. They are adapter-specific
    // setup operations called during initial deployment and asset onboarding.
    // The SettlementCoordinator never calls them.
    //
    // Access: COMPLIANCE_ROLE (via ProtocolAccessManager).

    /// @notice Configures an asset for the chain this adapter serves.
    /// @dev Stores the full AssetConfig keyed by (assetId, _chainId).
    ///      Reverts if the asset is already configured for this chain.
    /// @param assetId         Protocol-level asset identifier.
    /// @param token           ERC-3643 token contract address on this chain.
    /// @param identityRegistry IdentityRegistry address linked to the token.
    /// @param compliance      ModularCompliance address linked to the token.
    /// @param decimals        Token decimals.
    /// @param assetType       Asset classification identifier.
    /// @param settlementModel Settlement model identifier (e.g. BURN_MINT).
    /// @param vendorVersion   Vendor software version identifier.
    function configureAsset(
        bytes32 assetId,
        address token,
        address identityRegistry,
        address compliance,
        uint8 decimals,
        bytes32 assetType,
        bytes32 settlementModel,
        bytes32 vendorVersion
    ) external {
        _onlyRole(_accessManager.COMPLIANCE_ROLE());

        if (assetId == bytes32(0)) revert ERC3643Adapter__ZeroAssetId();
        if (token == address(0)) revert ERC3643Adapter__ZeroAddress();
        if (identityRegistry == address(0)) revert ERC3643Adapter__ZeroAddress();
        if (compliance == address(0)) revert ERC3643Adapter__ZeroAddress();
        if (_configs[assetId][_chainId].token != address(0)) {
            revert ERC3643Adapter__AssetAlreadyRegistered(assetId, _chainId);
        }

        _configs[assetId][_chainId] = AssetConfig({
            token: token,
            identityRegistry: identityRegistry,
            compliance: compliance,
            decimals: decimals,
            assetType: assetType,
            settlementModel: settlementModel,
            vendorVersion: vendorVersion
        });

        _tokenAssets[token] = assetId;

        emit AssetConfigured(assetId, _chainId, token, settlementModel);
    }

    /// @notice Returns the full AssetConfig for a given asset on this chain.
    /// @param  assetId Protocol-level asset identifier.
    /// @return config  The asset configuration.
    function getAssetConfig(bytes32 assetId) external view returns (AssetConfig memory config) {
        config = _configs[assetId][_chainId];
        if (config.token == address(0)) {
            revert ERC3643Adapter__AssetNotFound(assetId, _chainId);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IAssetAdapter: Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAssetAdapter
    function assetExists(bytes32 assetId) external view override returns (bool exists) {
        return _configs[assetId][_chainId].token != address(0);
    }

    /// @inheritdoc IAssetAdapter
    function supportsPartition(
        bytes32 assetId,
        bytes32 partitionId
    ) external view override returns (bool supported) {
        // ERC-3643 does not natively support partitions. Return true only
        // for the default (zero) partition.
        return partitionId == bytes32(0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IAssetAdapter: Reservation
    // ═══════════════════════════════════════════════════════════════════════
    //
    // ── Reservation Strategy ──
    //
    // The current strategy uses internal accounting. It is TEMPORARY and will
    // be replaced by a dedicated Reservation Extension contract.
    //
    // Idempotency: reserveAssets is idempotent — calling it twice with the
    // same intentId returns true without double-reserving. releaseReservation
    // is safe to call on non-existent reservations (returns false).

    /// @inheritdoc IAssetAdapter
    function reserveAssets(
        ProtocolTypes.TransferIntent calldata intent
    ) external override returns (bool reserved) {
        _onlyRole(_accessManager.BRIDGE_ROLE());

        // ── Idempotency ──
        if (_reservations[intent.intentId].sender != address(0)) {
            return true;
        }

        AssetConfig storage config = _getConfig(intent.assetId);

        // ── Balance verification ──
        uint256 balance = IERC3643Token(config.token).balanceOf(intent.sender);
        if (balance < intent.amount) {
            return false;
        }

        // ── Reserve (internal accounting) ──
        _reservations[intent.intentId] = Reservation({
            sender: intent.sender,
            amount: intent.amount,
            assetId: intent.assetId
        });
        _reservedBalances[intent.assetId][intent.sender] += intent.amount;

        emit AssetReserved(intent.intentId, intent.sender, intent.assetId, intent.amount);
        return true;
    }

    /// @inheritdoc IAssetAdapter
    function releaseReservation(
        ProtocolTypes.TransferIntent calldata intent
    ) external override returns (bool released) {
        _onlyRole(_accessManager.BRIDGE_ROLE());

        Reservation storage r = _reservations[intent.intentId];
        if (r.sender == address(0)) {
            return false; // no-op for unknown reservations
        }

        // ── Release (internal accounting) ──
        _reservedBalances[r.assetId][r.sender] -= r.amount;
        delete _reservations[intent.intentId];

        emit ReservationReleased(intent.intentId);
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IAssetAdapter: Settlement
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Settlement dispatches internally based on the asset's settlementModel.
    // Only BURN_MINT is implemented. Each operation (mint, burn) is routed
    // through _settleMint / _settleBurn.

    /// @inheritdoc IAssetAdapter
    function burnReservedAssets(
        ProtocolTypes.TransferIntent calldata intent
    ) external override returns (bool burned) {
        _onlyRole(_accessManager.BRIDGE_ROLE());

        Reservation storage r = _reservations[intent.intentId];
        if (r.sender == address(0)) {
            revert ERC3643Adapter__ReservationNotFound(intent.intentId);
        }

        if (r.sender != intent.sender
            || r.amount != intent.amount
            || r.assetId != intent.assetId
        ) {
            revert ERC3643Adapter__ReservationMismatch(intent.intentId);
        }

        AssetConfig storage config = _getConfig(intent.assetId);

        // ── Clear reservation BEFORE external call (reentrancy defense) ──
        _reservedBalances[r.assetId][r.sender] -= r.amount;
        delete _reservations[intent.intentId];

        // ── Execute burn per settlement model ──
        _settleBurn(config, intent.sender, intent.amount);

        emit ReservedBurnConfirmed(intent.intentId, intent.sender, intent.amount);
        return true;
    }

    /// @inheritdoc IAssetAdapter
    function mintAssets(
        ProtocolTypes.TransferIntent calldata intent
    ) external override returns (bool minted) {
        _onlyRole(_accessManager.BRIDGE_ROLE());

        AssetConfig storage config = _getConfig(intent.assetId);

        // ── Execute mint per settlement model ──
        _settleMint(config, intent.recipient, intent.amount);

        emit MintConfirmed(intent.intentId, intent.recipient, intent.amount);
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IAssetAdapter: Recovery
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Recovery is isolated in private helpers so future RecoveryManager
    // code can reuse these functions without duplicating logic.

    /// @inheritdoc IAssetAdapter
    function rollbackReservation(
        ProtocolTypes.TransferIntent calldata intent
    ) external override returns (bool rolledBack) {
        _onlyRole(_accessManager.BRIDGE_ROLE());

        AssetConfig storage config = _getConfig(intent.assetId);

        // ── Re-mint to sender per settlement model ──
        _recoverRollback(config, intent.sender, intent.amount);

        emit RollbackMintConfirmed(intent.intentId, intent.sender, intent.amount);
        return true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IAssetAdapter: Queries
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAssetAdapter
    function balanceOf(
        bytes32 assetId,
        address account,
        bytes32 partitionId
    ) external view override returns (uint256 balance) {
        if (partitionId != bytes32(0)) return 0;
        address token = _getConfig(assetId).token;
        return IERC3643Token(token).balanceOf(account);
    }

    /// @inheritdoc IAssetAdapter
    function reservedBalance(
        bytes32 assetId,
        address account,
        bytes32 partitionId
    ) external view override returns (uint256 balance) {
        if (partitionId != bytes32(0)) return 0;
        return _reservedBalances[assetId][account];
    }

    /// @inheritdoc IAssetAdapter
    function availableBalance(
        bytes32 assetId,
        address account,
        bytes32 partitionId
    ) external view override returns (uint256 balance) {
        if (partitionId != bytes32(0)) return 0;
        address token = _getConfig(assetId).token;
        uint256 total = IERC3643Token(token).balanceOf(account);
        uint256 reserved = _reservedBalances[assetId][account];
        return total > reserved ? total - reserved : 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IAssetAdapter: Metadata
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAssetAdapter
    function assetId(address token) external view override returns (bytes32 id) {
        return _tokenAssets[token];
    }

    /// @inheritdoc IAssetAdapter
    function assetVersion() external pure override returns (bytes32 version) {
        return ADAPTER_VERSION;
    }

    /// @inheritdoc IAssetAdapter
    function adapterId() external pure override returns (bytes32 id) {
        return ADAPTER_ID;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Versioning (Non-Interface)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // These functions expose version metadata beyond what IAssetAdapter
    // requires. They are available for off-chain tooling and monitoring.

    /// @notice Returns the chain this adapter deployment serves.
    function adapterChain() external view returns (ChainId chainId) {
        return _chainId;
    }

    /// @notice Returns the vendor version for a given asset on this chain.
    /// @param  assetId Protocol-level asset identifier.
    /// @return version Vendor software version (e.g. keccak256("T-REX:4.1.6")).
    function vendorVersion(bytes32 assetId) external view returns (bytes32 version) {
        return _getConfig(assetId).vendorVersion;
    }

    /// @notice Returns the asset type classification for a given asset.
    /// @param  assetId Protocol-level asset identifier.
    /// @return type_   Asset classification identifier.
    function assetType(bytes32 assetId) external view returns (bytes32 type_) {
        return _getConfig(assetId).assetType;
    }

    /// @notice Returns the settlement model for a given asset on this chain.
    /// @param  assetId Protocol-level asset identifier.
    /// @return model   Settlement model identifier.
    function settlementModel(bytes32 assetId) external view returns (bytes32 model) {
        return _getConfig(assetId).settlementModel;
    }

    /// @notice Returns the IdentityRegistry address for a given asset.
    /// @param  assetId Protocol-level asset identifier.
    /// @return registry IdentityRegistry address.
    function identityRegistry(bytes32 assetId) external view returns (address registry) {
        return _getConfig(assetId).identityRegistry;
    }

    /// @notice Returns the Compliance address for a given asset.
    /// @param  assetId Protocol-level asset identifier.
    /// @return compliance_ ModularCompliance address.
    function compliance(bytes32 assetId) external view returns (address compliance_) {
        return _getConfig(assetId).compliance;
    }

    /// @notice Returns the decimals for a given asset.
    /// @param  assetId Protocol-level asset identifier.
    /// @return decimal Token decimals.
    function decimals(bytes32 assetId) external view returns (uint8 decimal) {
        return _getConfig(assetId).decimals;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Configuration
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Returns the AssetConfig for the given assetId on this chain.
    ///      Reverts if the asset is not configured.
    function _getConfig(bytes32 assetId) private view returns (AssetConfig storage config) {
        config = _configs[assetId][_chainId];
        if (config.token == address(0)) {
            revert ERC3643Adapter__AssetNotFound(assetId, _chainId);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Access Control
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Reverts if msg.sender does not have the given role.
    function _onlyRole(bytes32 role) private view {
        if (!_accessManager.hasRole(role, msg.sender)) {
            revert ERC3643Adapter__Unauthorized(msg.sender, role);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Settlement Dispatching
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Each settlement model defines how mint and burn are executed. The
    // dispatch functions below select the correct execution path based
    // on config.settlementModel.
    //
    // Future models:
    //   LOCK_MINT     - Token.forcedTransfer(sender, vault, amount) for
    //                   reserve; Token.mint(recipient, amount) for mint;
    //                   Token.burn(vault, amount) for burn.
    //   LOCK_UNLOCK   - Token.forcedTransfer(sender, vault, amount) for
    //                   reserve; Token.mint(recipient, amount) for mint;
    //                   Token.forcedTransfer(vault, sender, amount) for burn.
    //   ESCROW_RELEASE - Token.forcedTransfer(sender, escrow, amount) for
    //                    reserve; escrow.release(recipient, amount) for mint;
    //                    escrow.refund(sender, amount) for burn.

    /// @dev Executes a mint operation according to the asset's settlement model.
    function _settleMint(AssetConfig storage config, address recipient, uint256 amount) private {
        if (config.settlementModel == SETTLEMENT_MODEL_BURN_MINT) {
            IERC3643Token(config.token).mint(recipient, amount);
        } else {
            revert ERC3643Adapter__NotImplemented(config.settlementModel, "mint");
        }
    }

    /// @dev Executes a burn operation according to the asset's settlement model.
    function _settleBurn(AssetConfig storage config, address account, uint256 amount) private {
        if (config.settlementModel == SETTLEMENT_MODEL_BURN_MINT) {
            IERC3643Token(config.token).burn(account, amount);
        } else {
            revert ERC3643Adapter__NotImplemented(config.settlementModel, "burn");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Recovery
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Recovery helpers are separated from settlement so that:
    //   1. Future RecoveryManager code can call them through the adapter.
    //   2. Recovery logic can be tested independently.
    //   3. New settlement models add their recovery path here without
    //      touching the settlement dispatch.

    /// @dev Re-mints tokens to the sender during rollback recovery.
    ///      Dispatches by settlement model, mirroring the burn path.
    function _recoverRollback(AssetConfig storage config, address sender, uint256 amount) private {
        if (config.settlementModel == SETTLEMENT_MODEL_BURN_MINT) {
            IERC3643Token(config.token).mint(sender, amount);
        } else {
            revert ERC3643Adapter__NotImplemented(config.settlementModel, "rollback");
        }
    }
}
