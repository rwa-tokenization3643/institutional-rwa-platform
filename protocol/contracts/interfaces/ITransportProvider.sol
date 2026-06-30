// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ChainId, ProtocolTypes} from "../common/ProtocolTypes.sol";

/// @title Transport Provider Interface
/// @notice Transport-agnostic interface for cross-chain message delivery.
/// @dev Every transport provider (CCIP, LayerZero, Hyperlane, Axelar, future
///      providers) implements this interface. The SettlementCoordinator sends
///      and tracks messages through this interface without knowing the
///      underlying transport.
///
///      A TransportProvider is responsible ONLY for transport. It MUST NOT
///      perform compliance, identity, settlement, minting, burning, or
///      policy evaluation.
///
///      Transport-level errors should be defined in ProtocolErrors.sol once
///      that shared library exists. Until then, implementers should define
///      their own errors following the naming convention
///      `TransportProvider__<ErrorName>`.
///
///      ── Inbound Message Delivery ──
///
///      When a message arrives from a remote chain, the transport provider's
///      receiver hook decodes the native message, extracts the
///      `TransportMessage`, and delivers it to the registered destination
///      contract. The delivery model is:
///
///      1. The provider authenticates the source (chain + sender) using its
///         native security model (e.g. CCIP `allowedSenders`, LayerZero
///         `onlyRemote`).
///
///      2. The provider calls a single, fixed dispatch function on the
///         receiver contract. The receiver address MUST be known to the
///         provider at configuration time — it is NEVER passed inside the
///         `TransportMessage` itself (doing so would allow an attacker to
///         redirect delivery).
///
///      3. The dispatch function signature MUST be:
///
///         ```solidity
///         function handleMessage(
///             ChainId sourceChain,
///             bytes32 messageId,
///             ProtocolTypes.TransportMessage calldata message
///         ) external;
///         ```
///
///      The SettlementCoordinator (or another authorized contract) implements
///      this handler and is registered with the provider during deployment.
///      The `handleMessage` function is NOT part of this interface — it is the
///      receiver-side counterpart that each protocol integration contract
///      provides.
///
///      Implementations MUST support ERC-165 for interface detection.
///
///      The SettlementCoordinator MUST never know which concrete provider
///      implements this interface.
interface ITransportProvider is IERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // Sending
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Dispatches a cross-chain message through the transport provider.
    /// @dev The provider encodes the TransportMessage into its native format,
    ///      pays any required fees, and submits it for transport.
    ///
    ///      The destination receiver MUST be pre-configured in the provider
    ///      (e.g. during deployment or via access-controlled configuration).
    ///      It is NOT passed here to prevent callers from redirecting messages
    ///      to arbitrary destinations.
    /// @param destinationChain Target chain identifier.
    /// @param message          The canonical TransportMessage to transport.
    /// @return messageId       Provider-assigned unique message identifier.
    ///                         Used for subsequent status queries.
    function sendMessage(
        ChainId destinationChain,
        ProtocolTypes.TransportMessage calldata message
    ) external returns (bytes32 messageId);

    // ═══════════════════════════════════════════════════════════════════════
    // Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns whether this provider supports message transport to
    ///         the given chain.
    /// @param chainId Chain identifier to query.
    /// @return supported True if the provider can deliver messages to the chain.
    function supportsChain(ChainId chainId) external view returns (bool supported);

    // ═══════════════════════════════════════════════════════════════════════
    // Fee Estimation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Estimates the transport fee for dispatching a message.
    /// @dev The returned fee is an estimate. The actual fee charged at
    ///      `sendMessage` time may differ.
    /// @param destinationChain Target chain identifier.
    /// @param message          The message to estimate fees for.
    /// @return fee             Estimated native token cost of transport.
    function estimateFee(
        ChainId destinationChain,
        ProtocolTypes.TransportMessage calldata message
    ) external view returns (uint256 fee);

    // ═══════════════════════════════════════════════════════════════════════
    // Status
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the delivery status of a previously sent message.
    /// @param messageId Provider-assigned message identifier.
    /// @return status   Current transport-level delivery status.
    function getMessageStatus(bytes32 messageId) external view returns (ProtocolTypes.TransportStatus status);

    // ═══════════════════════════════════════════════════════════════════════
    // Capabilities
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the unique identifier of this transport provider.
    /// @dev MUST match the `transportId` field in `TransportMessage` so the
    ///      SettlementCoordinator can correlate inbound messages with the
    ///      originating provider.
    /// @return transportId Bytes32 identifier (e.g. `keccak256("CCIP")`).
    function getTransportId() external view returns (bytes32 transportId);

    /// @notice Returns a bitmask of supported capabilities.
    /// @dev Each bit corresponds to a `TransportCapability` enum value.
    ///      Consumers check support with
    ///      `(capabilities >> uint256(TransportCapability.XXX)) & 1 == 1`.
    /// @return capabilities Bitmask of supported capabilities.
    function getCapabilities() external view returns (uint256 capabilities);

    // ═══════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a message is dispatched through the provider.
    /// @param messageId         Provider-assigned message identifier.
    /// @param destinationChain  Target chain identifier.
    /// @param intentId          Intent the message relates to (`bytes32(0)`
    ///                          for non-transfer messages).
    /// @param sender            Address that initiated the dispatch.
    event MessageDispatched(
        bytes32 indexed messageId,
        ChainId indexed destinationChain,
        bytes32 indexed intentId,
        address sender
    );

    /// @notice Emitted when a message delivery is confirmed on the
    ///         destination chain.
    /// @param messageId     Provider-assigned message identifier.
    /// @param sourceChain   Source chain identifier.
    /// @param intentId      Intent the message relates to.
    event MessageDelivered(
        bytes32 indexed messageId,
        ChainId indexed sourceChain,
        bytes32 indexed intentId
    );

    /// @notice Emitted when a message delivery fails permanently.
    /// @param messageId     Provider-assigned message identifier.
    /// @param intentId      Intent the message relates to.
    /// @param reason        Transport-specific failure reason.
    event MessageDeliveryFailed(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        bytes reason
    );
}
