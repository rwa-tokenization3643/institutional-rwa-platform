// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {ChainId, ProtocolTypes} from "../contracts/common/ProtocolTypes.sol";
import {ICcipRouterClient} from "../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {DeployBase} from "./DeployBase.sol";
import {Config} from "./Config.sol";

// =============================================================================
// DeploySepolia - Deploy full protocol stack on Ethereum Sepolia
// =============================================================================
//
// Usage:
//   forge script script/DeploySepolia.s.sol \
//     --rpc-url https://sepolia.infura.io/v3/<YOUR_KEY> \
//     --broadcast --private-key <YOUR_KEY>
//
// =============================================================================

contract DeploySepolia is DeployBase {

    // -- Chain Configuration --
    function _chainId() internal pure override returns (ChainId) {
        return Config.SOURCE_CHAIN;
    }

    function _ccipRouter() internal view override returns (ICcipRouterClient) {
        return ICcipRouterClient(Config.SEPOLIA_ROUTER);
    }

    function _linkToken() internal view override returns (address) {
        return Config.SEPOLIA_LINK;
    }

    function _chainLabel() internal pure override returns (string memory) {
        return "Sepolia";
    }

    function _remoteChainId() internal pure override returns (ChainId) {
        return Config.DEST_CHAIN;
    }

    function _remoteChainLabel() internal pure override returns (string memory) {
        return "Fuji";
    }

    function _ccipSelector() internal pure override returns (uint64) {
        return Config.SEPOLIA_CHAIN_SELECTOR;
    }

    function _remoteCcipSelector() internal pure override returns (uint64) {
        return Config.FUJI_CHAIN_SELECTOR;
    }

    function _remoteTransportAddress() internal view override returns (address) {
        // Set env FUJI_TRANSPORT before deployment, or override in subclass
        try vm.envAddress("FUJI_TRANSPORT") returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }

    function _getTokenAdminRegistry() internal view override returns (address) {
        return 0x9a9F2ccbFE2936223f312400DB614737f817c855;
    }

    function run() external {
        _runDeployment();
    }
}
