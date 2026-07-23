// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {ICcipRouterClient} from "../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {DeployBase} from "./DeployBase.sol";
import {Config} from "./Config.sol";

// =============================================================================
// DeployFuji - Deploy full protocol stack on Avalanche Fuji
// =============================================================================
//
// Usage:
//   forge script script/DeployFuji.s.sol \
//     --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
//     --broadcast --private-key <YOUR_KEY>
//
// =============================================================================

contract DeployFuji is DeployBase {

    // -- Chain Configuration --
    function _chainId() internal pure override returns (ChainId) {
        return Config.DEST_CHAIN;
    }

    function _ccipRouter() internal view override returns (ICcipRouterClient) {
        return ICcipRouterClient(Config.FUJI_ROUTER);
    }

    function _linkToken() internal view override returns (address) {
        return Config.FUJI_LINK;
    }

    function _chainLabel() internal pure override returns (string memory) {
        return "Fuji";
    }

    function _remoteChainId() internal pure override returns (ChainId) {
        return Config.SOURCE_CHAIN;
    }

    function _remoteChainLabel() internal pure override returns (string memory) {
        return "Sepolia";
    }

    function _ccipSelector() internal pure override returns (uint64) {
        return Config.FUJI_CHAIN_SELECTOR;
    }

    function _remoteCcipSelector() internal pure override returns (uint64) {
        return Config.SEPOLIA_CHAIN_SELECTOR;
    }

    function _remoteTransportAddress() internal view override returns (address) {
        // Set env SEPOLIA_TRANSPORT before deployment, or override in subclass
        try vm.envAddress("SEPOLIA_TRANSPORT") returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }

    function _getTokenAdminRegistry() internal view override returns (address) {
        return 0x4228f81c3af0857e717B981BfB1874f4c0b39EF1;
    }

    function run() external {
        _runDeployment();
    }
}
