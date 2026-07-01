// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProtocolAccessManager} from "../../../contracts/access/ProtocolAccessManager.sol";
import {IProtocolAccessManager} from "../../../contracts/access/IProtocolAccessManager.sol";
import {ProtocolTypes, ChainId} from "../../../contracts/common/ProtocolTypes.sol";
import {ITransportProvider} from "../../../contracts/interfaces/ITransportProvider.sol";
import {ISettlementCoordinator} from "../../../contracts/interfaces/ISettlementCoordinator.sol";
import {CCIPTransportProvider, ICcipRouterClient, Any2EVMMessage, ICcipReceiver} from "../../../contracts/extensions/bridge/CCIPTransportProvider.sol";

// =============================================================================
// Mocks
// =============================================================================

contract MockCCIPRouter is ICcipRouterClient {
    bytes32 private _nextMessageId;
    uint64 public lastDestChainSelector;
    bytes public lastReceiver;
    bytes public lastData;
    uint256 public lastMsgValue;
    uint256 public mockFee = 0.01 ether;

    CCIPTransportProvider public provider;

    function setProvider(CCIPTransportProvider _provider) external {
        provider = _provider;
    }

    function setNextMessageId(bytes32 id) external {
        _nextMessageId = id;
    }

    function setMockFee(uint256 fee) external {
        mockFee = fee;
    }

    function ccipSend(
        uint64 destinationChainSelector,
        ICcipRouterClient.EVM2AnyMessage calldata message
    ) external payable returns (bytes32 messageId) {
        lastDestChainSelector = destinationChainSelector;
        lastReceiver = message.receiver;
        lastData = message.data;
        lastMsgValue = msg.value;
        messageId = _nextMessageId;
    }

    function getFee(
        uint64,
        ICcipRouterClient.EVM2AnyMessage calldata
    ) external view returns (uint256 fee) {
        return mockFee;
    }

    function deliver(Any2EVMMessage calldata message) external {
        provider.ccipReceive(message);
    }
}

contract MockSettlementCoordinator {
    ChainId public lastSourceChain;
    bytes32 public lastMessageId;
    bytes32 public lastIntentId;
    bool public shouldRevert;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function handleTransportMessage(
        ChainId sourceChain,
        bytes32 messageId,
        ProtocolTypes.TransportMessage calldata message
    ) external {
        if (shouldRevert) {
            revert("Coordinator: delivery failed");
        }
        lastSourceChain = sourceChain;
        lastMessageId = messageId;
        lastIntentId = message.intentId;
    }
}

// =============================================================================
// CCIPTransportProvider Test
// =============================================================================

contract CCIPTransportProviderTest is Test {
    ProtocolAccessManager private accessManager;
    MockCCIPRouter private router;
    MockSettlementCoordinator private coordinator;
    CCIPTransportProvider private provider;

    address private admin = address(0xA11CE);
    address private bridge = address(0xB0B0B);
    address private unauthorized = address(0xE4E);

    ChainId private constant CHAIN_A = ChainId.wrap(1);
    ChainId private constant CHAIN_B = ChainId.wrap(2);
    uint64 private constant SELECTOR_A = 15971525489660198786;
    uint64 private constant SELECTOR_B = 5009297550715157269;

    bytes32 private constant INTENT_ID = keccak256("TEST_INTENT");
    bytes32 private constant TRANSPORT_ID = keccak256("CCIP");
    bytes32 private _bridgeRole;

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _transportMessage() internal pure returns (ProtocolTypes.TransportMessage memory) {
        return ProtocolTypes.TransportMessage({
            messageVersion: 1,
            transportId: TRANSPORT_ID,
            messageType: ProtocolTypes.MessageType.TRANSFER_INTENT,
            phase: ProtocolTypes.SettlementPhase.VALIDATION_REQUEST,
            messageId: bytes32(0),
            intentId: INTENT_ID,
            sourceChainId: CHAIN_A,
            destinationChainId: CHAIN_B,
            expiresAt: 0,
            sender: address(0xAA),
            recipient: address(0xBB),
            payloadHash: bytes32(0),
            payload: bytes("")
        });
    }

    function _any2EVMMessage(
        uint64 sourceChainSelector,
        address sender,
        bytes memory data,
        bytes32 messageId
    ) internal pure returns (Any2EVMMessage memory) {
        return Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: sourceChainSelector,
            sender: abi.encode(sender),
            data: data,
            destTokenAmounts: new address[](0),
            destTokenAmountsValues: new uint256[](0)
        });
    }

    // ── Setup ────────────────────────────────────────────────────────────────

    function setUp() public {
        accessManager = new ProtocolAccessManager(admin);
        router = new MockCCIPRouter();
        coordinator = new MockSettlementCoordinator();

        vm.startPrank(admin);
        accessManager.grantRole(accessManager.BRIDGE_ROLE(), bridge);
        vm.stopPrank();

        _bridgeRole = accessManager.BRIDGE_ROLE();

        provider = new CCIPTransportProvider(accessManager, router, ISettlementCoordinator(address(coordinator)));

        router.setProvider(provider);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Constructor & ERC165
    // ═══════════════════════════════════════════════════════════════════════

    function test_ConstructorSetsImmutables() public view {
        assertEq(provider.getTransportId(), TRANSPORT_ID);
    }

    function test_ConstructorRevertsWhenAccessManagerZero() public {
        vm.expectRevert(CCIPTransportProvider.CCIPProvider__ZeroAddress.selector);
        new CCIPTransportProvider(IProtocolAccessManager(address(0)), router, ISettlementCoordinator(address(coordinator)));
    }

    function test_ConstructorRevertsWhenRouterZero() public {
        vm.expectRevert(CCIPTransportProvider.CCIPProvider__ZeroAddress.selector);
        new CCIPTransportProvider(accessManager, ICcipRouterClient(address(0)), ISettlementCoordinator(address(coordinator)));
    }

    function test_ConstructorRevertsWhenCoordinatorZero() public {
        vm.expectRevert(CCIPTransportProvider.CCIPProvider__ZeroAddress.selector);
        new CCIPTransportProvider(accessManager, router, ISettlementCoordinator(address(0)));
    }

    function test_SupportsITransportProvider() public view {
        assertTrue(provider.supportsInterface(type(ITransportProvider).interfaceId));
    }

    function test_SupportsICcipReceiver() public view {
        assertTrue(provider.supportsInterface(type(ICcipReceiver).interfaceId));
    }

    function test_SupportsERC165() public view {
        assertTrue(provider.supportsInterface(type(IERC165).interfaceId));
    }

    function test_DoesNotSupportUnknownInterface() public view {
        assertFalse(provider.supportsInterface(bytes4(0xFFFFFFFF)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // setChainSelector
    // ═══════════════════════════════════════════════════════════════════════

    function test_SetChainSelector() public {
        vm.prank(bridge);
        vm.expectEmit(true, true, false, true, address(provider));
        emit CCIPTransportProvider.ChainSelectorSet(CHAIN_A, SELECTOR_A);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);

        assertEq(provider.getChainSelector(CHAIN_A), SELECTOR_A);
        assertEq(ChainId.unwrap(provider.getChainId(SELECTOR_A)), ChainId.unwrap(CHAIN_A));
    }

    function test_SetChainSelectorReverseLookup() public {
        vm.prank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);

        assertEq(ChainId.unwrap(provider.getChainId(SELECTOR_A)), ChainId.unwrap(CHAIN_A));
    }

    function test_SetChainSelectorIdempotentSameMapping() public {
        vm.startPrank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        vm.stopPrank();

        assertEq(provider.getChainSelector(CHAIN_A), SELECTOR_A);
    }

    function test_SetChainSelectorRevertsWhenDuplicateDifferentChain() public {
        vm.prank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPTransportProvider.CCIPProvider__ChainNotSupported.selector, CHAIN_A)
        );
        provider.setChainSelector(CHAIN_A, SELECTOR_B);
    }

    function test_SetChainSelectorRevertsWhenDuplicateDifferentSelector() public {
        vm.prank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPTransportProvider.CCIPProvider__ChainNotSupported.selector, CHAIN_B)
        );
        provider.setChainSelector(CHAIN_B, SELECTOR_A);
    }

    function test_SetChainSelectorRevertsWhenNotBridgeRole() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTransportProvider.CCIPProvider__UnauthorizedRole.selector,
                unauthorized,
                _bridgeRole
            )
        );
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
    }

    function test_GetChainSelectorReturnsZeroForUnknownChain() public view {
        assertEq(provider.getChainSelector(CHAIN_A), 0);
    }

    function test_GetChainIdReturnsZeroForUnknownSelector() public view {
        assertEq(ChainId.unwrap(provider.getChainId(SELECTOR_A)), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // setAllowedSender
    // ═══════════════════════════════════════════════════════════════════════

    function test_SetAllowedSender() public {
        vm.prank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);

        vm.prank(bridge);
        vm.expectEmit(true, true, false, true, address(provider));
        emit CCIPTransportProvider.AllowedSenderSet(CHAIN_A, bridge, true);
        provider.setAllowedSender(CHAIN_A, bridge, true);

        assertTrue(provider.isAllowedSender(CHAIN_A, bridge));
    }

    function test_SetAllowedSenderCanRemove() public {
        vm.startPrank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        provider.setAllowedSender(CHAIN_A, bridge, true);
        vm.stopPrank();

        assertTrue(provider.isAllowedSender(CHAIN_A, bridge));

        vm.prank(bridge);
        provider.setAllowedSender(CHAIN_A, bridge, false);
        assertFalse(provider.isAllowedSender(CHAIN_A, bridge));
    }

    function test_SetAllowedSenderSupportsMultipleSenders() public {
        vm.startPrank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        provider.setAllowedSender(CHAIN_A, address(0xAA), true);
        provider.setAllowedSender(CHAIN_A, address(0xBB), true);
        vm.stopPrank();

        assertTrue(provider.isAllowedSender(CHAIN_A, address(0xAA)));
        assertTrue(provider.isAllowedSender(CHAIN_A, address(0xBB)));
        assertFalse(provider.isAllowedSender(CHAIN_A, address(0xCC)));
    }

    function test_SetAllowedSenderRevertsWhenChainNotSupported() public {
        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPTransportProvider.CCIPProvider__ChainNotSupported.selector, CHAIN_A)
        );
        provider.setAllowedSender(CHAIN_A, bridge, true);
    }

    function test_SetAllowedSenderRevertsWhenNotBridgeRole() public {
        vm.startPrank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTransportProvider.CCIPProvider__UnauthorizedRole.selector,
                unauthorized,
                _bridgeRole
            )
        );
        provider.setAllowedSender(CHAIN_A, bridge, true);
    }

    function test_IsAllowedSenderReturnsFalseForUnconfiguredChain() public view {
        assertFalse(provider.isAllowedSender(CHAIN_A, bridge));
    }

    function test_IsAllowedSenderReturnsFalseForUnallowedSender() public {
        vm.startPrank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        provider.setAllowedSender(CHAIN_A, address(0xDEAD), true);
        vm.stopPrank();

        assertFalse(provider.isAllowedSender(CHAIN_A, bridge));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // supportsChain
    // ═══════════════════════════════════════════════════════════════════════

    function test_SupportsChainReturnsTrueForConfigured() public {
        vm.prank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);

        assertTrue(provider.supportsChain(CHAIN_A));
    }

    function test_SupportsChainReturnsFalseForUnconfigured() public view {
        assertFalse(provider.supportsChain(CHAIN_A));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // sendMessage
    // ═══════════════════════════════════════════════════════════════════════

    function _configureChainB() internal {
        vm.prank(bridge);
        provider.setChainSelector(CHAIN_B, SELECTOR_B);
    }

    function test_SendMessage() public {
        _configureChainB();

        router.setNextMessageId(keccak256("msg-1"));

        ProtocolTypes.TransportMessage memory tm = _transportMessage();
        vm.deal(address(provider), 1 ether);

        vm.prank(bridge);
        bytes32 messageId = provider.sendMessage(CHAIN_B, tm);

        assertEq(messageId, keccak256("msg-1"));
        assertEq(router.lastDestChainSelector(), SELECTOR_B);
        assertEq(uint256(provider.getMessageStatus(messageId)), uint256(ProtocolTypes.TransportStatus.PENDING));
    }

    function test_SendMessageEmitsEvent() public {
        _configureChainB();

        router.setNextMessageId(keccak256("msg-event"));

        ProtocolTypes.TransportMessage memory tm = _transportMessage();
        vm.deal(address(provider), 1 ether);

        vm.prank(bridge);
        vm.expectEmit(true, true, true, true, address(provider));
        emit ITransportProvider.MessageDispatched(keccak256("msg-event"), CHAIN_B, INTENT_ID, bridge);
        provider.sendMessage(CHAIN_B, tm);
    }

    function test_SendMessageFundsFromProviderBalance() public {
        _configureChainB();

        router.setNextMessageId(keccak256("msg-funded"));

        ProtocolTypes.TransportMessage memory tm = _transportMessage();
        vm.deal(address(provider), 1 ether);

        vm.prank(bridge);
        provider.sendMessage(CHAIN_B, tm);

        assertEq(router.lastMsgValue(), router.mockFee());
    }

    function test_SendMessageRevertsWhenChainNotSupported() public {
        ProtocolTypes.TransportMessage memory tm = _transportMessage();

        vm.prank(bridge);
        vm.expectRevert(
            abi.encodeWithSelector(CCIPTransportProvider.CCIPProvider__ChainNotSupported.selector, CHAIN_B)
        );
        provider.sendMessage(CHAIN_B, tm);
    }

    function test_SendMessageRevertsWhenNotBridgeRole() public {
        _configureChainB();

        ProtocolTypes.TransportMessage memory tm = _transportMessage();

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTransportProvider.CCIPProvider__UnauthorizedRole.selector,
                unauthorized,
                _bridgeRole
            )
        );
        provider.sendMessage(CHAIN_B, tm);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // estimateFee
    // ═══════════════════════════════════════════════════════════════════════

    function test_EstimateFee() public {
        _configureChainB();

        ProtocolTypes.TransportMessage memory tm = _transportMessage();
        uint256 fee = provider.estimateFee(CHAIN_B, tm);

        assertEq(fee, router.mockFee());
    }

    function test_EstimateFeeRevertsWhenChainNotSupported() public {
        ProtocolTypes.TransportMessage memory tm = _transportMessage();

        vm.expectRevert(
            abi.encodeWithSelector(CCIPTransportProvider.CCIPProvider__ChainNotSupported.selector, CHAIN_B)
        );
        provider.estimateFee(CHAIN_B, tm);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // getMessageStatus
    // ═══════════════════════════════════════════════════════════════════════

    function test_GetMessageStatusReturnsPendingForUnknown() public view {
        assertEq(
            uint256(provider.getMessageStatus(keccak256("unknown"))),
            uint256(ProtocolTypes.TransportStatus.PENDING)
        );
    }

    function test_GetMessageStatusReturnsPendingAfterSend() public {
        _configureChainB();

        router.setNextMessageId(keccak256("msg-status"));

        ProtocolTypes.TransportMessage memory tm = _transportMessage();
        vm.deal(address(provider), 1 ether);

        vm.prank(bridge);
        bytes32 messageId = provider.sendMessage(CHAIN_B, tm);

        assertEq(
            uint256(provider.getMessageStatus(messageId)),
            uint256(ProtocolTypes.TransportStatus.PENDING)
        );
    }

    function _configureChainAWithSender() internal {
        vm.startPrank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        provider.setAllowedSender(CHAIN_A, bridge, true);
        vm.stopPrank();
    }

    function test_GetMessageStatusReturnsDeliveredAfterReceive() public {
        _configureChainAWithSender();

        bytes32 msgId = keccak256("inbound-msg");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();
        tm.messageId = msgId;

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            msgId
        );

        router.deliver(ccipMsg);

        assertEq(
            uint256(provider.getMessageStatus(msgId)),
            uint256(ProtocolTypes.TransportStatus.DELIVERED)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // getTransportId
    // ═══════════════════════════════════════════════════════════════════════

    function test_GetTransportId() public view {
        assertEq(provider.getTransportId(), TRANSPORT_ID);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // getCapabilities
    // ═══════════════════════════════════════════════════════════════════════

    function test_GetCapabilities() public view {
        uint256 caps = provider.getCapabilities();

        assertEq((caps >> uint256(ProtocolTypes.TransportCapability.FEE_ESTIMATION)) & 1, 1);
        assertEq((caps >> uint256(ProtocolTypes.TransportCapability.MESSAGE_STATUS)) & 1, 1);
        assertEq((caps >> uint256(ProtocolTypes.TransportCapability.PAYLOAD_VERIFICATION)) & 1, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ccipReceive — Inbound Message Handling
    // ═══════════════════════════════════════════════════════════════════════

    function test_CcipReceiveDeliversToCoordinator() public {
        _configureChainAWithSender();

        bytes32 msgId = keccak256("inbound-1");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();
        tm.messageId = msgId;

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            msgId
        );

        router.deliver(ccipMsg);

        assertEq(ChainId.unwrap(coordinator.lastSourceChain()), ChainId.unwrap(CHAIN_A));
        assertEq(coordinator.lastMessageId(), msgId);
        assertEq(coordinator.lastIntentId(), INTENT_ID);
    }

    function test_CcipReceiveEmitsMessageDelivered() public {
        _configureChainAWithSender();

        bytes32 msgId = keccak256("inbound-event");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();
        tm.messageId = msgId;

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            msgId
        );

        vm.expectEmit(true, true, true, true, address(provider));
        emit ITransportProvider.MessageDelivered(msgId, CHAIN_A, INTENT_ID);
        router.deliver(ccipMsg);
    }

    function test_CcipReceiveOverridesMessageIdWithCCIPId() public {
        _configureChainAWithSender();

        bytes32 ccipMsgId = keccak256("ccip-authoritative-id");
        bytes32 wrongId = keccak256("wrong-id");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();
        tm.messageId = wrongId;

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            ccipMsgId
        );

        router.deliver(ccipMsg);

        assertEq(coordinator.lastMessageId(), ccipMsgId);
    }

    function test_CcipReceiveRevertsWhenChainNotSupported() public {
        bytes32 msgId = keccak256("inbound-unknown-chain");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            msgId
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTransportProvider.CCIPProvider__ChainNotSupported.selector,
                ChainId.wrap(0)
            )
        );
        router.deliver(ccipMsg);
    }

    function test_CcipReceiveRevertsWhenSenderNotAllowed() public {
        vm.startPrank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        provider.setAllowedSender(CHAIN_A, address(0xDEAD), true);
        vm.stopPrank();

        bytes32 msgId = keccak256("inbound-unauth");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            msgId
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTransportProvider.CCIPProvider__SenderNotAllowed.selector,
                SELECTOR_A,
                bridge
            )
        );
        router.deliver(ccipMsg);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ccipReceive — Router Authentication
    // ═══════════════════════════════════════════════════════════════════════

    function test_CcipReceiveRevertsWhenNotCalledByRouter() public {
        _configureChainAWithSender();

        bytes32 msgId = keccak256("inbound-noauth");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            msgId
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTransportProvider.CCIPProvider__UnauthorizedRouter.selector,
                address(this)
            )
        );
        provider.ccipReceive(ccipMsg);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ccipReceive — State-Based Replay Protection
    // ═══════════════════════════════════════════════════════════════════════

    function test_CcipReceiveRevertsWhenAlreadyDelivered() public {
        _configureChainAWithSender();

        bytes32 msgId = keccak256("inbound-delivered");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            msgId
        );

        router.deliver(ccipMsg);

        assertEq(
            uint256(provider.getMessageStatus(msgId)),
            uint256(ProtocolTypes.TransportStatus.DELIVERED)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CCIPTransportProvider.CCIPProvider__MessageNotRetryable.selector,
                msgId,
                ProtocolTypes.TransportStatus.DELIVERED
            )
        );
        router.deliver(ccipMsg);
    }

    function test_CcipReceiveSucceedsOnRetryAfterFailure() public {
        _configureChainAWithSender();

        bytes32 msgId = keccak256("inbound-retry-fail");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            msgId
        );

        // First delivery: coordinator reverts → FAILED
        coordinator.setShouldRevert(true);
        router.deliver(ccipMsg);

        assertEq(
            uint256(provider.getMessageStatus(msgId)),
            uint256(ProtocolTypes.TransportStatus.FAILED)
        );

        // Second delivery: coordinator succeeds → DELIVERED
        coordinator.setShouldRevert(false);
        router.deliver(ccipMsg);

        assertEq(
            uint256(provider.getMessageStatus(msgId)),
            uint256(ProtocolTypes.TransportStatus.DELIVERED)
        );
        assertEq(coordinator.lastMessageId(), msgId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ccipReceive — Coordinator Failure → FAILED Status
    // ═══════════════════════════════════════════════════════════════════════

    function test_CcipReceiveMarksFailedWhenCoordinatorReverts() public {
        _configureChainAWithSender();

        coordinator.setShouldRevert(true);

        bytes32 msgId = keccak256("inbound-fail");
        ProtocolTypes.TransportMessage memory tm = _transportMessage();

        Any2EVMMessage memory ccipMsg = _any2EVMMessage(
            SELECTOR_A,
            bridge,
            abi.encode(tm),
            msgId
        );

        vm.expectEmit(true, true, true, true, address(provider));
        emit ITransportProvider.MessageDeliveryFailed(msgId, INTENT_ID, abi.encodeWithSignature("Error(string)", "Coordinator: delivery failed"));
        router.deliver(ccipMsg);

        assertEq(
            uint256(provider.getMessageStatus(msgId)),
            uint256(ProtocolTypes.TransportStatus.FAILED)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Queries
    // ═══════════════════════════════════════════════════════════════════════

    function test_GetChainSelectorReturnsConfiguredSelector() public {
        vm.prank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);

        assertEq(provider.getChainSelector(CHAIN_A), SELECTOR_A);
    }

    function test_GetChainIdReturnsConfiguredChain() public {
        vm.prank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);

        assertEq(ChainId.unwrap(provider.getChainId(SELECTOR_A)), ChainId.unwrap(CHAIN_A));
    }

    function test_IsAllowedSenderReturnsConfiguredSender() public {
        vm.startPrank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        provider.setAllowedSender(CHAIN_A, bridge, true);
        vm.stopPrank();

        assertTrue(provider.isAllowedSender(CHAIN_A, bridge));
    }

    function test_IsAllowedSenderReturnsFalseAfterRemove() public {
        vm.startPrank(bridge);
        provider.setChainSelector(CHAIN_A, SELECTOR_A);
        provider.setAllowedSender(CHAIN_A, bridge, true);
        provider.setAllowedSender(CHAIN_A, bridge, false);
        vm.stopPrank();

        assertFalse(provider.isAllowedSender(CHAIN_A, bridge));
    }
}
