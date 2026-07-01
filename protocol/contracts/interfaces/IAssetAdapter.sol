// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProtocolTypes} from "../common/ProtocolTypes.sol";

/// @title Asset Adapter Interface
/// @notice Token-standard-agnostic abstraction over every asset operation the
///         settlement protocol requires.
/// @dev The SettlementCoordinator interacts ONLY with this interface for all
///      asset-related operations. It MUST never call ERC-3643, ERC-1400,
///      ERC-20, or any vendor token contract directly.
///
///      Concrete implementations translate these business-level operations
///      into vendor-specific calls. For example:
///
///        - `burnReservedAssets` → `Token.burn(sender, amount)`
///        - `mintAssets`         → `Token.mint(recipient, amount)`
///        - `reserveAssets`      → `Token.operatorTransfer(...)` or a
///                                  custom lock mapping
///
///      ── Responsibilities ──
///
///      The AssetAdapter is responsible for:
///        * Validating that an asset exists and partitions are supported.
///        * Reserving assets after destination approval (Phase 2) to
///          prevent double-spending between reservation and burn.
///        * Releasing reservations when settlement fails or rollback
///          recovery is needed.
///        * Burning reserved assets on the source chain during Phase 2.
///        * Minting assets to recipients on the destination chain.
///        * Re-minting assets on the source chain during rollback recovery.
///        * Reporting balances (total, reserved, available) for an account
///          across partitions.
///        * Mapping between token contract addresses and protocol-level
///          asset identifiers.
///
///      It MUST NOT:
///        * Perform compliance evaluation.
///        * Perform cross-chain transport.
///        * Manage settlement state or TransferIntent lifecycle.
///        * Manage identities or evaluate policy.
///        * Define access control or authorization logic.
///
///      ── Token-Standard Agnostic ──
///
///      The interface uses business-language function names rather than
///      vendor-specific API names. This ensures the SettlementCoordinator
///      works unchanged with ERC-3643, ERC-1400, ERC-20, or future token
///      standards.
///
///      No vendor-specific types (e.g. ONCHAINID identity contracts,
///      ERC-3643-specific structs) appear anywhere in this interface.
///
///      ── Invariants ──
///
///      1. `reserveAssets` MUST be idempotent within the same intent:
///         calling it twice MUST NOT double-reserve.
///      2. `releaseReservation` MUST succeed even if the reservation was
///         never created (no-op for unknown intents).
///      3. `burnReservedAssets` MUST revert if the requested amount is not
///         available (not reserved or reserved for a different intent).
///      4. `mintAssets` MUST mint exactly `amount` tokens to `recipient`
///         or revert entirely.
///      5. `rollbackReservation` MUST re-mint `amount` tokens to `sender`
///         when the destination mint failed and the source burn already
///         executed.
///      6. `balanceOf` >= `reservedBalance` + `availableBalance` for every
///         account.
///      7. The adapter MUST treat `partitionId == bytes32(0)` as a request
///         for the total across all partitions (the "default partition").
///
///      ── Events ──
///
///      Asset lifecycle events will be centralized in ProtocolEvents.sol.
///      They are intentionally absent from this interface.
///
///      ── Errors ──
///
///      Asset-related errors will be centralized in ProtocolErrors.sol.
///      They are intentionally absent from this interface.
///
///      Implementations MUST support ERC-165 for interface detection.
///
///      The SettlementCoordinator MUST never know which concrete adapter
///      implements this interface.
interface IAssetAdapter is IERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns whether an asset is registered and recognised by
    ///         this adapter.
    /// @param  assetId Protocol-level asset identifier (matches
    ///         `TransferIntent.assetId`).
    /// @return exists  True if the asset is known to this adapter.
    function assetExists(bytes32 assetId) external view returns (bool exists);

    /// @notice Returns whether a specific partition exists for an asset.
    /// @param  assetId     Protocol-level asset identifier.
    /// @param  partitionId Partition identifier (`bytes32(0)` represents
    ///                     the default partition, which MUST always be
    ///                     supported).
    /// @return supported   True if the partition is recognised.
    function supportsPartition(
        bytes32 assetId,
        bytes32 partitionId
    ) external view returns (bool supported);

    // ═══════════════════════════════════════════════════════════════════════
    // Reservation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Reserves an amount of an asset for a transfer intent during
    ///         Phase 2 settlement, preventing double-spending between
    ///         reservation and burn.
    /// @dev    Reservation happens only after the destination chain has
    ///         approved the intent (both sides agree), reducing lock
    ///         contention during Phase 1 validation. MUST be idempotent —
    ///         calling twice with the same intent MUST NOT double-reserve.
    ///         Implementations SHOULD store a reservation per `intentId`
    ///         so they can later release or burn the exact reserved quantity.
    /// @param  intent  The transfer intent requiring a reservation.
    /// @return reserved True if the reservation was created or already
    ///                  existed (idempotent).
    function reserveAssets(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bool reserved);

    /// @notice Releases a previously created asset reservation.
    /// @dev    MUST succeed as a no-op if the reservation does not exist
    ///         (e.g. already released, never created). Called when Phase 2
    ///         settlement fails after reservation but before burn, or when
    ///         recovery rollback is needed.
    /// @param  intent   The transfer intent whose reservation to release.
    /// @return released True if a reservation was released, false if no
    ///                  reservation existed (no-op).
    function releaseReservation(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bool released);

    // ═══════════════════════════════════════════════════════════════════════
    // Settlement
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Burns the reserved tokens for a confirmed transfer intent
    ///         during Phase 2 settlement.
    /// @dev    MUST revert if the tokens are not reserved or if the
    ///         reservation references a different asset or amount than
    ///         the intent specifies. After burning, the reserved amount
    ///         is deducted from both the total supply and the sender's
    ///         balance.
    /// @param  intent The confirmed transfer intent authorising the burn.
    /// @return burned True if the burn was executed successfully.
    function burnReservedAssets(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bool burned);

    /// @notice Mints tokens to the recipient on the destination chain
    ///         during Phase 2 settlement.
    /// @dev    MUST mint exactly `intent.amount` tokens to `intent.recipient`
    ///         for the asset identified by `intent.assetId`. If the full
    ///         amount cannot be minted, the function MUST revert entirely
    ///         (no partial mints).
    /// @param  intent The settlement intent specifying whom to mint,
    ///                how much, and for which asset/partition.
    /// @return minted True if the mint was executed successfully.
    function mintAssets(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bool minted);

    // ═══════════════════════════════════════════════════════════════════════
    // Recovery
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Rolls back a settlement by re-minting tokens to the original
    ///         sender after a destination-side mint failure.
    /// @dev    Called during the recovery path when Phase 2 mint on the
    ///         destination chain failed but the source burn already executed.
    ///         The adapter MUST re-mint `intent.amount` tokens to
    ///         `intent.sender` for the asset identified by `intent.assetId`.
    /// @param  intent       The failed transfer intent to roll back.
    /// @return rolledBack   True if the rollback mint was executed.
    function rollbackReservation(
        ProtocolTypes.TransferIntent calldata intent
    ) external returns (bool rolledBack);

    // ═══════════════════════════════════════════════════════════════════════
    // Queries
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the total token balance for an account, optionally
    ///         filtered by partition.
    /// @param  assetId     Protocol-level asset identifier.
    /// @param  account     The account to query.
    /// @param  partitionId Partition filter (`bytes32(0)` for total across
    ///                     all partitions).
    /// @return balance     Total balance of the account.
    function balanceOf(
        bytes32 assetId,
        address account,
        bytes32 partitionId
    ) external view returns (uint256 balance);

    /// @notice Returns the amount currently reserved for active intents.
    /// @param  assetId     Protocol-level asset identifier.
    /// @param  account     The account to query.
    /// @param  partitionId Partition filter (`bytes32(0)` for total across
    ///                     all partitions).
    /// @return balance     Reserved (locked) balance of the account.
    function reservedBalance(
        bytes32 assetId,
        address account,
        bytes32 partitionId
    ) external view returns (uint256 balance);

    /// @notice Returns the balance available for new transfers or
    ///         reservations.
    /// @dev    MUST equal `balanceOf(...) - reservedBalance(...)`.
    /// @param  assetId     Protocol-level asset identifier.
    /// @param  account     The account to query.
    /// @param  partitionId Partition filter (`bytes32(0)` for total across
    ///                     all partitions).
    /// @return balance     Available (unreserved) balance of the account.
    function availableBalance(
        bytes32 assetId,
        address account,
        bytes32 partitionId
    ) external view returns (uint256 balance);

    // ═══════════════════════════════════════════════════════════════════════
    // Metadata
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Resolves a token contract address to its protocol-level
    ///         asset identifier.
    /// @param  token The address of the token contract.
    /// @return id    The protocol-level asset identifier.
    function assetId(address token) external view returns (bytes32 id);

    /// @notice Returns the version identifier of this adapter
    ///         implementation.
    /// @return version Version identifier (e.g. semantic version hash or
    ///                 content-addressed digest).
    function assetVersion() external view returns (bytes32 version);

    /// @notice Returns the unique identifier of this adapter.
    /// @dev    MUST be a stable identifier that distinguishes this adapter
    ///         from others (e.g. `keccak256("ERC3643AssetAdapter")`).
    /// @return id Bytes32 adapter identifier.
    function adapterId() external view returns (bytes32 id);
}
