// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ProtocolTypes, ChainId} from "../../contracts/common/ProtocolTypes.sol";
import {ITransferIntentManager} from "../../contracts/interfaces/ITransferIntentManager.sol";
import {CCIPTransportProvider, Any2EVMMessage} from "../../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {MockCCIPRouter} from "../mocks/MockCCIPRouter.sol";
import {ProtocolFixture, ProtocolFixtureBase} from "../utils/ProtocolFixture.sol";

abstract contract ConformanceBase is ProtocolFixtureBase {
    ChainId internal constant SOURCE_CHAIN = ChainId.wrap(1);
    ChainId internal constant DEST_CHAIN = ChainId.wrap(2);
    uint64 internal constant CCIP_SOURCE_SELECTOR = 15971525489660198786;
    uint64 internal constant CCIP_DEST_SELECTOR = 5009297550715157269;

    bytes32 internal constant ASSET_ID = keccak256("RWA_TOKEN");
    bytes32 internal constant ASSET_TYPE = keccak256("BOND");
    bytes32 internal constant BURN_MINT = keccak256("BURN_MINT");
    bytes32 internal constant JURISDICTION_US = keccak256("US");
    bytes32 internal constant JURISDICTION_EU = keccak256("EU");

    uint256 internal constant TOKEN_SUPPLY = 10_000 ether;
    uint256 internal constant TRANSFER_AMOUNT = 1_000 ether;

    address internal admin = address(0xA11CE);
    address internal complianceOp = address(0xCAFE);
    address internal bridgeOp = address(0xB0B0B);
    address internal sender = address(0xAAA);
    address internal recipient = address(0xBBB);

    uint64 internal _nonce;

    function _nextNonce() internal returns (uint64) {
        return ++_nonce;
    }

    function _createIntent()
        internal
        returns (ProtocolTypes.TransferIntent memory intent)
    {
        uint64 nonce = _nextNonce();
        bytes32 intentId = keccak256(
            abi.encode(SOURCE_CHAIN, nonce, sender, recipient, TRANSFER_AMOUNT)
        );
        intent = ProtocolTypes.TransferIntent({
            intentId: intentId,
            action: ProtocolTypes.IntentAction.TRANSFER,
            sender: sender,
            recipient: recipient,
            senderIdentityHash: bytes32(uint256(1)),
            recipientIdentityHash: bytes32(uint256(2)),
            assetId: ASSET_ID,
            partitionId: bytes32(0),
            sourceChainId: SOURCE_CHAIN,
            destinationChainId: DEST_CHAIN,
            amount: TRANSFER_AMOUNT,
            policyDecisionHash: bytes32(0),
            messageHash: bytes32(0),
            nonce: nonce,
            expiresAt: uint64(block.timestamp + 1 hours)
        });
    }

    function _assertIntentState(
        ITransferIntentManager manager,
        bytes32 intentId,
        ProtocolTypes.SettlementState expectedState,
        string memory label
    ) internal view {
        assertEq(
            uint256(manager.getSettlementState(intentId)),
            uint256(expectedState),
            label
        );
    }

    function _outboundMessage(
        bytes32 messageId,
        uint64 ccipSourceSelector,
        address senderAddress,
        bytes memory payload
    ) internal pure returns (Any2EVMMessage memory) {
        address[] memory emptyAddrs;
        uint256[] memory emptyUints;
        return Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: ccipSourceSelector,
            sender: abi.encode(senderAddress),
            data: payload,
            destTokenAmounts: emptyAddrs,
            destTokenAmountsValues: emptyUints
        });
    }

    function _deliverTo(
        CCIPTransportProvider provider,
        MockCCIPRouter router,
        uint64 ccipSourceSelector,
        address sourceTransportAddress,
        bytes32 messageId,
        bytes memory payload
    ) internal {
        Any2EVMMessage memory ccipMsg = _outboundMessage(
            messageId, ccipSourceSelector, sourceTransportAddress, payload
        );
        vm.prank(address(router));
        provider.ccipReceive(ccipMsg);
    }

    function _deliverPhaseMessage(
        CCIPTransportProvider destProvider,
        MockCCIPRouter destRouter_,
        uint64 ccipSourceSelector,
        address sourceTransportAddress,
        CCIPTransportProvider sourceProvider,
        bytes32 intentId,
        ChainId sourceChain,
        ChainId destChain,
        uint64 expiresAt,
        bytes32 msgId,
        ProtocolTypes.MessageType messageType,
        ProtocolTypes.SettlementPhase phase,
        bytes memory payload
    ) internal {
        ProtocolTypes.TransportMessage memory tm = ProtocolTypes.TransportMessage({
            messageVersion: 1,
            transportId: sourceProvider.TRANSPORT_ID(),
            messageType: messageType,
            phase: phase,
            messageId: bytes32(0),
            intentId: intentId,
            sourceChainId: sourceChain,
            destinationChainId: destChain,
            expiresAt: expiresAt,
            sender: address(0),
            recipient: address(0),
            payloadHash: keccak256(payload),
            payload: payload
        });
        _deliverTo(
            destProvider, destRouter_,
            ccipSourceSelector, sourceTransportAddress,
            msgId, abi.encode(tm)
        );
    }

    function _configureAssetAndCompliance(ProtocolFixture memory fixture) internal {
        configureAsset(fixture, ASSET_ID, address(fixture.token), 18, ASSET_TYPE, BURN_MINT);
        ChainId[] memory chains = new ChainId[](2);
        chains[0] = SOURCE_CHAIN;
        chains[1] = DEST_CHAIN;
        bytes32[] memory jurisdictions = new bytes32[](2);
        jurisdictions[0] = JURISDICTION_US;
        jurisdictions[1] = JURISDICTION_EU;
        configureCompliance(fixture, ASSET_ID, ProtocolTypes.IntentAction.TRANSFER, chains, jurisdictions);
    }

    function _configureTransport(ProtocolFixture memory source_, ProtocolFixture memory dest_) internal {
        vm.startPrank(bridgeOp);
        source_.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        source_.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        source_.transportProvider.setAllowedSender(DEST_CHAIN, address(dest_.transportProvider), true);
        dest_.transportProvider.setChainSelector(SOURCE_CHAIN, CCIP_SOURCE_SELECTOR);
        dest_.transportProvider.setChainSelector(DEST_CHAIN, CCIP_DEST_SELECTOR);
        dest_.transportProvider.setAllowedSender(SOURCE_CHAIN, address(source_.transportProvider), true);
        vm.stopPrank();
    }

    function _mintSenderTokens(ProtocolFixture memory fixture) internal {
        fixture.token.mint(sender, TOKEN_SUPPLY);
    }
}
