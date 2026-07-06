// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICcipRouterClient} from "../../contracts/extensions/bridge/CCIPTransportProvider.sol";

/// @title MockCCIPRouter
/// @notice Minimal Chainlink CCIP Router mock for testing the protocol's
///         CCIPTransportProvider. Supports configurable fee mock and
///         deterministic messageId generation.
contract MockCCIPRouter is ICcipRouterClient {
    uint256 public mockFee = 0.01 ether;

    function setMockFee(uint256 f) external { mockFee = f; }

    function ccipSend(
        uint64,
        ICcipRouterClient.EVM2AnyMessage calldata
    ) external payable returns (bytes32 messageId) {
        messageId = keccak256(abi.encode(block.timestamp, msg.data));
    }

    function getFee(
        uint64,
        ICcipRouterClient.EVM2AnyMessage calldata
    ) external view returns (uint256 fee) {
        return mockFee;
    }

    receive() external payable {}
}
