// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IProtocolAccessManager} from "../../access/IProtocolAccessManager.sol";
import {ITransportProvider} from "../../interfaces/ITransportProvider.sol";
import {ISettlementCoordinator} from "../../interfaces/ISettlementCoordinator.sol";
import {ChainId, ProtocolTypes} from "../../common/ProtocolTypes.sol";

// =============================================================================
// CCIP Compatibility Interfaces
// =============================================================================
//
// These minimal interfaces declare only the CCIP Router functions and structs
// that this provider actually uses. No CCIP dependency is imported — this
// contract is compatible with any CCIP router that implements the standard
// `ccipSend`, `getFee`, and `ccipReceive` dispatcher pattern.
//
// If a CCIP SDK or `@chainlink/contracts` package is added to the project in
// the future, these inline interfaces should be deleted and replaced with
// imports from that package. Until then, they avoid adding a dependency for
// a single contract.
//
// References:
//   https://docs.chain.link/ccip/developer-guides/programmable-tokens
//   https://github.com/smartcontractkit/ccip-starter-kit-hardhat
// =============================================================================

/// @notice Minimal CCIP Router interface for sending messages.
/// @dev Declares only `ccipSend` and `getFee`. The full IRouterClient defines
///      additional functions not needed by this provider.
interface ICcipRouterClient {
    /// @notice Struct for a single token amount in CCIP messages.
    struct EVMTokenAmount {
        address token;
        uint256 amount;
    }

    /// @notice Struct for encoding a CCIP outbound message.
    /// @dev receiver must be ABI-encoded address of the destination receiver.
    ///      feeToken = address(0) means pay in native gas.
    struct EVM2AnyMessage {
        bytes receiver;
        bytes data;
        EVMTokenAmount[] tokenAmounts;
        address feeToken;
        bytes extraArgs;
    }

    /// @notice Sends a message to the destination chain through CCIP.
    /// @param destinationChainSelector CCIP chain selector for the destination.
    /// @param message The outbound message envelope.
    /// @return messageId CCIP-assigned unique message identifier.
    function ccipSend(
        uint64 destinationChainSelector,
        EVM2AnyMessage calldata message
    ) external payable returns (bytes32 messageId);

    /// @notice Returns the fee for sending a message to the destination chain.
    /// @param destinationChainSelector CCIP chain selector for the destination.
    /// @param message The outbound message envelope.
    /// @return fee Total fee in wei (native gas when feeToken = address(0)).
    function getFee(
        uint64 destinationChainSelector,
        EVM2AnyMessage calldata message
    ) external view returns (uint256 fee);
}

/// @notice Minimal CCIP Any2EVMMessage struct for the receiver callback.
/// @dev Represents an inbound message from a remote chain via CCIP.
struct Any2EVMMessage {
    bytes32 messageId;
    uint64 sourceChainSelector;
    bytes sender;
    bytes data;
    ICcipRouterClient.EVMTokenAmount[] destTokenAmounts;
}

/// @notice Minimal CCIP EVM2AnyMessage receiver interface.
/// @dev The real CCIP Router calls supportsInterface(0x81d17744) before
///      delivering messages. This interface must be supported.
interface IAny2EVMMessageReceiver {
    function ccipReceive(Any2EVMMessage calldata message) external;
}

/// @notice Minimal CCIP Receiver interface.
/// @dev The CCIP Router calls `ccipReceive` on the destination contract
///      after verifying the source chain and sender authenticity via its
///      own allowlist. This provider additionally authenticates the sender
///      address against its own per-chain allowlist.
interface ICcipReceiver {
    /// @notice Called by the CCIP Router when a message arrives.
    /// @param message The decoded inbound message.
    function ccipReceive(Any2EVMMessage calldata message) external;
}

// =============================================================================
// Default ExtraArgs for CCIP
// =============================================================================

/// @dev Default gas limit for CCIP message execution on the destination.
///      Encoded as EVMExtraArgsV1 in the outbound message. 500_000 is a safe
///      default for complex settlement messages; callers with different needs
///      should adjust this constant or make it configurable.
uint256 constant CCIP_DEFAULT_GAS_LIMIT = 500_000;

// =============================================================================
// CCIPTransportProvider
// =============================================================================
//
// ── Role ──
//
// This provider is the protocol's Chainlink CCIP transport adapter. It
// implements ITransportProvider by translating between the protocol's
// canonical TransportMessage envelope and CCIP's native message format.
//
// The SettlementCoordinator dispatches messages through this provider via
// the ITransportProvider interface and never interacts with CCIP-specific
// contracts directly.
//
// ── Responsibilities ──
//
//   * Encode TransportMessage → CCIP EVM2AnyMessage and send via Router
//   * Receive inbound CCIP Any2EVMMessage, authenticate, decode, deliver
//   * Estimate CCIP fees for outbound messages
//   * Report message delivery status
//   * Expose provider identity and capabilities
//
// ── What the provider does NOT do ──
//
//   * Settlement orchestration (delegated to SettlementCoordinator)
//   * Compliance evaluation (delegated to ICompliancePolicyProvider)
//   * Token minting, burning, or locking (delegated to IAssetAdapter)
//   * Intent lifecycle management (delegated to ITransferIntentManager)
//   * Message retry or recovery (future RecoveryManager concern)
//
// ── Inbound Authentication & Delivery Lifecycle ──
//
//   Three layers protect inbound messages:
//
//   1. Router identity check: `ccipReceive` verifies that `msg.sender`
//      is the immutable CCIP Router address. Only the Router can invoke
//      the receiver hook.
//
//   2. Per-chain sender allowlist: After decoding, the provider checks
//      that the decoded sender address is allowlisted via
//      `setAllowedSender(chainId, sender, true)`. Multiple senders per
//      chain are supported.
//
//   3. State-based replay protection: Each CCIP `messageId` has an
//      authoritative TransportStatus stored in `_messageStatus`. The
//      provider rejects messages whose status is PROCESSING or DELIVERED.
//      FAILED messages remain retryable — this enables future
//      RecoveryManager implementations to identify and replay failed
//      deliveries without provider changes.
//
//   ── Delivery Lifecycle ──
//
//   The inbound `ccipReceive` flow transitions through these states:
//
//       Router authentication
//              ↓
//       Sender authentication
//              ↓
//       Decode TransportMessage
//              ↓
//       Check _messageStatus[id]:
//         - PROCESSING or DELIVERED → revert (not retryable)
//         - FAILED → allow retry
//         - PENDING / unknown → proceed
//              ↓
//       _messageStatus[id] = PROCESSING
//              ↓
//       SettlementCoordinator.handleTransportMessage(...)
//              ↓
//       SUCCESS ? ──→ _messageStatus[id] = DELIVERED
//              ↓                       emit MessageDelivered
//           FAILURE
//              ↓
//       _messageStatus[id] = FAILED
//       emit MessageDeliveryFailed
//
//   Only DELIVERED messages are considered terminal. PROCESSING prevents
//   reentrancy within a single transaction. FAILED messages are not
//   terminal — they may be retried by a future RecoveryManager.
//
//   Using TransportStatus as the single source of truth (rather than a
//   separate boolean mapping) eliminates duplicated state and makes the
//   retry policy explicit at the type level. A RecoveryManager can query
//   getMessageStatus() to find FAILED messages and re-submit them via
//   the CCIP Router (which delivers them through ccipReceive again).
//
// ── Fee Payment ──
//
//   The provider must be pre-funded with native gas. The `sendMessage`
//   function computes the CCIP fee via `getFee` and forwards the exact
//   amount to the router. Anyone may deposit ETH via `receive()` or the
//   explicit `deposit()` function. An operator may sweep excess ETH via
//   a future recovery function.
//
// ── Security Assumptions ──
//
//   * The CCIP Router is trusted to verify on-chain message inclusion
//     on the source chain.
//   * The configured allowed sender on the source chain is a trusted
//     CCIPTransportProvider (or equivalent) that encodes messages
//     honestly.
//   * The SettlementCoordinator does not trust the transport layer for
//     settlement correctness — it validates message type, phase, and
//     intent state before acting.
// =============================================================================
contract CCIPTransportProvider is ITransportProvider, ERC165, ICcipReceiver {

    // ═══════════════════════════════════════════════════════════════════════
    // Errors
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Replace with ProtocolErrors.sol

    /// @dev Zero address where a non-zero is required.
    error CCIPProvider__ZeroAddress();

    /// @dev The caller is not the registered SettlementCoordinator.
    error CCIPProvider__UnauthorizedCoordinator(address caller);

    /// @dev The caller does not hold the required role.
    error CCIPProvider__UnauthorizedRole(address caller, bytes32 requiredRole);

    /// @dev The caller is not the CCIP Router.
    error CCIPProvider__UnauthorizedRouter(address caller);

    /// @dev The destination chain is not supported (no CCIP selector mapped).
    error CCIPProvider__ChainNotSupported(ChainId chainId);

    /// @dev The source chain has no allowed sender configured.
    error CCIPProvider__SenderNotAllowed(uint64 sourceChainSelector, address sender);

    /// @dev No remote receiver configured for the destination chain.
    error CCIPProvider__RemoteReceiverNotSet(ChainId destinationChain);

    /// @dev The inbound message payload could not be decoded.
    error CCIPProvider__InvalidPayload(bytes32 messageId);

    /// @dev The message is not retryable — it is currently processing or
    ///      already delivered. Only FAILED messages may be retried.
    error CCIPProvider__MessageNotRetryable(bytes32 messageId, ProtocolTypes.TransportStatus current);

    /// @dev The transport has no LINK allowance for the Router.
    error CCIPProvider__LinkAllowanceNotSet();

    // ═══════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Replace with ProtocolEvents.sol

    /// @dev A CCIP chain selector was mapped to a protocol chain ID.
    event ChainSelectorSet(ChainId indexed chainId, uint64 selector);

    /// @dev An allowed sender was configured (or removed) for a remote chain.
    event AllowedSenderSet(ChainId indexed chainId, address sender, bool allowed);

    /// @dev A remote receiver was configured for a destination chain.
    event RemoteReceiverSet(ChainId indexed chainId, address receiver);

    // ═══════════════════════════════════════════════════════════════════════
    // Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Unique identifier for this transport provider.
    bytes32 public constant TRANSPORT_ID = keccak256("CCIP");

    /// @notice Version of this provider implementation.
    bytes32 public constant PROVIDER_VERSION = keccak256("CCIPTransportProvider:1.0.0");

    // ═══════════════════════════════════════════════════════════════════════
    // Immutable State
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Protocol-wide access manager.
    IProtocolAccessManager private immutable _accessManager;

    /// @dev The CCIP Router contract.
    ICcipRouterClient private immutable _router;

    /// @dev The SettlementCoordinator that receives inbound messages.
    ISettlementCoordinator private immutable _coordinator;

    /// @dev Cached BRIDGE_ROLE identifier.
    bytes32 private immutable _bridgeRole;

    /// @dev LINK token address, or address(0) to pay fees in native gas.
    ///      When non-zero, the transport must have enough LINK balance and
    ///      Router allowance to cover outbound fees.
    address private immutable _linkToken;

    // ═══════════════════════════════════════════════════════════════════════
    // Mutable State
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Maps protocol chain IDs to CCIP chain selectors.
    mapping(ChainId chainId => uint64 selector) private _chainSelectors;

    /// @dev Reverse lookup: CCIP chain selector → protocol chain ID.
    mapping(uint64 selector => ChainId chainId) private _selectorChains;

    /// @dev Maps source chain → sender address → allowed flag.
    mapping(ChainId chainId => mapping(address sender => bool allowed)) private _allowedSenders;

    /// @dev Transport status per message ID.
    mapping(bytes32 messageId => ProtocolTypes.TransportStatus status) private _messageStatus;

    /// @dev Maps destination chain → remote transport receiver address.
    ///      The CCIP router on the destination chain delivers messages to this
    ///      address, which MUST implement ccipReceive (i.e., be a
    ///      CCIPTransportProvider or equivalent).
    mapping(ChainId destinationChain => address receiver) private _remoteReceivers;

    // ═══════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Configures the provider with its dependencies.
    /// @dev All addresses MUST be non-zero except linkToken (optional).
    /// @param accessManager  Protocol-wide access manager.
    /// @param router         CCIP Router contract.
    /// @param coordinator    SettlementCoordinator that processes inbound messages.
    /// @param linkToken      LINK token address, or address(0) to pay in native gas.
    constructor(
        IProtocolAccessManager accessManager,
        ICcipRouterClient router,
        ISettlementCoordinator coordinator,
        address linkToken
    ) {
        if (address(accessManager) == address(0)) revert CCIPProvider__ZeroAddress();
        if (address(router) == address(0)) revert CCIPProvider__ZeroAddress();
        if (address(coordinator) == address(0)) revert CCIPProvider__ZeroAddress();
        _accessManager = accessManager;
        _router = router;
        _coordinator = coordinator;
        _linkToken = linkToken;
        _bridgeRole = accessManager.BRIDGE_ROLE();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IERC165
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(ITransportProvider).interfaceId
            || interfaceId == type(ICcipReceiver).interfaceId
            || interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == 0x81d17744 // IAny2EVMMessageReceiver selector
            || super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration (Non-Interface)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // These functions are NOT part of ITransportProvider. They are
    // CCIP-specific setup operations called during deployment and chain
    // onboarding.
    //
    // Access: BRIDGE_ROLE (via ProtocolAccessManager).

    /// @notice Maps a protocol chain ID to a CCIP chain selector.
    /// @dev Reverts if the chainId or selector is already mapped to a
    ///      different value. Call this during deployment for each chain
    ///      the provider should support.
    /// @param chainId   Protocol-level chain identifier.
    /// @param selector  CCIP destination chain selector.
    function setChainSelector(ChainId chainId, uint64 selector) external {
        _onlyBridgeRole();
        if (_chainSelectors[chainId] != 0 && _chainSelectors[chainId] != selector) {
            revert CCIPProvider__ChainNotSupported(chainId);
        }
        if (ChainId.unwrap(_selectorChains[selector]) != 0
            && ChainId.unwrap(_selectorChains[selector]) != ChainId.unwrap(chainId)
        ) {
            revert CCIPProvider__ChainNotSupported(chainId);
        }
        _chainSelectors[chainId] = selector;
        _selectorChains[selector] = chainId;
        emit ChainSelectorSet(chainId, selector);
    }

    /// @notice Adds or removes a trusted sender address for a remote chain.
    /// @dev Only messages from allowlisted senders on the given chain
    ///      will be accepted. Reverts if the chain has no CCIP selector
    ///      mapped.
    /// @param chainId Protocol-level chain identifier.
    /// @param sender  Sender contract address on the remote chain.
    /// @param allowed True to allowlist, false to remove.
    function setAllowedSender(ChainId chainId, address sender, bool allowed) external {
        _onlyBridgeRole();
        if (_chainSelectors[chainId] == 0) revert CCIPProvider__ChainNotSupported(chainId);
        _allowedSenders[chainId][sender] = allowed;
        emit AllowedSenderSet(chainId, sender, allowed);
    }

    /// @notice Sets the remote transport address that will receive CCIP
    ///         messages on the destination chain.
    /// @dev The receiver MUST be a CCIPTransportProvider (or equivalent)
    ///      that implements ccipReceive. Reverts if the chain has no CCIP
    ///      selector mapped.
    /// @param chainId  Protocol-level destination chain identifier.
    /// @param receiver Address of the transport contract on the remote chain.
    function setRemoteReceiver(ChainId chainId, address receiver) external {
        _onlyBridgeRole();
        if (_chainSelectors[chainId] == 0) revert CCIPProvider__ChainNotSupported(chainId);
        if (receiver == address(0)) revert CCIPProvider__ZeroAddress();
        _remoteReceivers[chainId] = receiver;
        emit RemoteReceiverSet(chainId, receiver);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Native ETH Management
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Accepts ETH deposits to fund CCIP message fees.
    receive() external payable {}

    /// @notice Explicitly deposits ETH to fund CCIP message fees.
    function deposit() external payable {}

    /// @notice Approves the CCIP Router to spend the transport's LINK tokens
    ///         for fee payment. Call this after deployment and after each
    ///         LINK top-up if the Router's allowance was reset.
    /// @dev    Reverts if LINK is not configured (linkToken == address(0)).
    ///         Uses a large approval to avoid repeated approvals.
    function approveRouterLink() external {
        _onlyBridgeRole();
        if (_linkToken == address(0)) revert CCIPProvider__ZeroAddress();
        (bool ok,) = _linkToken.call(abi.encodeWithSelector(0x095ea7b3, address(_router), type(uint256).max));
        if (!ok) revert CCIPProvider__LinkAllowanceNotSet();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ITransportProvider: Sending
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ITransportProvider
    function sendMessage(
        ChainId destinationChain,
        ProtocolTypes.TransportMessage calldata message
    ) external override returns (bytes32 messageId) {
        _onlyBridgeRole();

        uint64 selector = _chainSelectors[destinationChain];
        if (selector == 0) revert CCIPProvider__ChainNotSupported(destinationChain);

        // ── Encode as CCIP EVM2AnyMessage ──
        ICcipRouterClient.EVM2AnyMessage memory ccipMessage = _buildCCIPMessage(message);

        // ── Compute fee and send via CCIP Router ──
        uint256 fee = _router.getFee(selector, ccipMessage);
        if (_linkToken != address(0)) {
            messageId = _router.ccipSend(selector, ccipMessage);
        } else {
            messageId = _router.ccipSend{value: fee}(selector, ccipMessage);
        }

        // ── Track status ──
        _messageStatus[messageId] = ProtocolTypes.TransportStatus.PENDING;

        emit MessageDispatched(messageId, destinationChain, message.intentId, msg.sender);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ITransportProvider: Validation
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ITransportProvider
    function supportsChain(ChainId chainId) external view override returns (bool supported) {
        return _chainSelectors[chainId] != 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ITransportProvider: Fee Estimation
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ITransportProvider
    function estimateFee(
        ChainId destinationChain,
        ProtocolTypes.TransportMessage calldata message
    ) external view override returns (uint256 fee) {
        uint64 selector = _chainSelectors[destinationChain];
        if (selector == 0) revert CCIPProvider__ChainNotSupported(destinationChain);

        ICcipRouterClient.EVM2AnyMessage memory ccipMessage = _buildCCIPMessage(message);

        return _router.getFee(selector, ccipMessage);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ITransportProvider: Status
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ITransportProvider
    function getMessageStatus(
        bytes32 messageId
    ) external view override returns (ProtocolTypes.TransportStatus status) {
        // Return the stored status. Unknown messageIds map to PENDING (value 0)
        // because uninitialized entries return the first enum value. This is
        // an accepted trade-off — the protocol does not define an UNKNOWN
        // status, and PENDING is the safest default for an unrecognized ID.
        return _messageStatus[messageId];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ITransportProvider: Capabilities
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ITransportProvider
    function getTransportId() external pure override returns (bytes32 transportId) {
        return TRANSPORT_ID;
    }

    /// @inheritdoc ITransportProvider
    function getCapabilities() external pure override returns (uint256 capabilities) {
        // FEE_ESTIMATION   = bit 0
        // MESSAGE_STATUS   = bit 1
        // PAYLOAD_VERIFICATION = bit 2
        return (1 << 0) | (1 << 1) | (1 << 2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ITransportProvider: Events (defined in interface)
    // ═══════════════════════════════════════════════════════════════════════
    //  - MessageDispatched
    //  - MessageDelivered
    //  - MessageDeliveryFailed
    //
    // Emitted by sendMessage and ccipReceive.

    // ═══════════════════════════════════════════════════════════════════════
    // ICcipReceiver: Inbound Message Handler
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Called by the CCIP Router when a cross-chain message arrives. This is
    // the only entry point for inbound messages.
    //
    // Authentication:
    //   1. The CCIP Router verifies the source chain and on-chain inclusion
    //      proof before calling this function.
    //   2. This function checks the sender address against the per-chain
    //      allowlist configured via setAllowedSender().

    /// @notice Receives an inbound CCIP message and delivers it to the
    ///         SettlementCoordinator.
    /// @dev Reverts if the sender is not allowlisted, the caller is not
    ///      the CCIP Router, or the message is not retryable (PROCESSING
    ///      or DELIVERED). FAILED messages may be retried.
    /// @param message The inbound CCIP Any2EVMMessage.
    function ccipReceive(Any2EVMMessage calldata message) external override {
        // ── Authenticate caller: only the CCIP Router ──
        if (msg.sender != address(_router)) {
            revert CCIPProvider__UnauthorizedRouter(msg.sender);
        }

        // ── Replay protection (state-based) ──
        ProtocolTypes.TransportStatus status = _messageStatus[message.messageId];
        if (status == ProtocolTypes.TransportStatus.PROCESSING) {
            revert CCIPProvider__MessageNotRetryable(message.messageId, status);
        }
        if (status == ProtocolTypes.TransportStatus.DELIVERED) {
            revert CCIPProvider__MessageNotRetryable(message.messageId, status);
        }
        // FAILED and PENDING (including unknown → PENDING) proceed.

        // ── Decode sender ──
        address sender = abi.decode(message.sender, (address));
        ChainId sourceChain = _selectorChains[message.sourceChainSelector];
        if (ChainId.unwrap(sourceChain) == 0) {
            revert CCIPProvider__ChainNotSupported(sourceChain);
        }

        // ── Authenticate sender ──
        if (!_allowedSenders[sourceChain][sender]) {
            revert CCIPProvider__SenderNotAllowed(message.sourceChainSelector, sender);
        }

        // ── Mark as processing (prevents reentrancy) ──
        _messageStatus[message.messageId] = ProtocolTypes.TransportStatus.PROCESSING;

        // ── Decode TransportMessage ──
        ProtocolTypes.TransportMessage memory transportMessage = abi.decode(
            message.data, (ProtocolTypes.TransportMessage)
        );

        // ── Override messageId with CCIP's authoritative ID ──
        transportMessage.messageId = message.messageId;

        // ── Deliver to SettlementCoordinator (handle failure gracefully) ──
        try _coordinator.handleTransportMessage(sourceChain, message.messageId, transportMessage) {
            _messageStatus[message.messageId] = ProtocolTypes.TransportStatus.DELIVERED;
            emit MessageDelivered(message.messageId, sourceChain, transportMessage.intentId);
        } catch (bytes memory reason) {
            _messageStatus[message.messageId] = ProtocolTypes.TransportStatus.FAILED;
            emit MessageDeliveryFailed(message.messageId, transportMessage.intentId, reason);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Queries (Non-Interface)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the CCIP chain selector for a protocol chain ID.
    /// @param  chainId Protocol-level chain identifier.
    /// @return selector CCIP chain selector, or 0 if not configured.
    function getChainSelector(ChainId chainId) external view returns (uint64 selector) {
        return _chainSelectors[chainId];
    }

    /// @notice Returns the protocol chain ID for a CCIP chain selector.
    /// @param  selector CCIP chain selector.
    /// @return chainId Protocol-level chain identifier, or ChainId.wrap(0)
    ///                 if not configured.
    function getChainId(uint64 selector) external view returns (ChainId chainId) {
        return _selectorChains[selector];
    }

    /// @notice Returns whether a sender is allowlisted for a remote chain.
    /// @param  chainId Protocol-level chain identifier.
    /// @param  sender  Sender address to query.
    /// @return allowed True if the sender is allowlisted.
    function isAllowedSender(ChainId chainId, address sender) external view returns (bool allowed) {
        return _allowedSenders[chainId][sender];
    }

    /// @notice Returns the remote transport receiver for a destination chain.
    /// @param  chainId Protocol-level destination chain identifier.
    /// @return receiver Address of the transport on the remote chain, or
    ///                  address(0) if not configured.
    function getRemoteReceiver(ChainId chainId) external view returns (address receiver) {
        return _remoteReceivers[chainId];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Message Encoding
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Builds a CCIP EVM2AnyMessage from a protocol TransportMessage.
    ///      Shared by sendMessage and estimateFee.
    ///      The receiver is the remote transport address configured for the
    ///      destination chain via setRemoteReceiver().
    function _buildCCIPMessage(
        ProtocolTypes.TransportMessage calldata message
    ) private view returns (ICcipRouterClient.EVM2AnyMessage memory) {
        address receiver = _remoteReceivers[ChainId.wrap(message.destinationChainId)];
        if (receiver == address(0)) {
            revert CCIPProvider__RemoteReceiverNotSet(ChainId.wrap(message.destinationChainId));
        }
        return ICcipRouterClient.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: abi.encode(message),
            tokenAmounts: new ICcipRouterClient.EVMTokenAmount[](0),
            feeToken: _linkToken,
            extraArgs: abi.encodeWithSelector(0x97a657c9, uint256(CCIP_DEFAULT_GAS_LIMIT))
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Access Control
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Reverts if msg.sender does not hold BRIDGE_ROLE.
    function _onlyBridgeRole() private view {
        if (!_accessManager.hasRole(_bridgeRole, msg.sender)) {
            revert CCIPProvider__UnauthorizedRole(msg.sender, _bridgeRole);
        }
    }
}
