// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {CCIPTransportProvider} from "../contracts/extensions/bridge/CCIPTransportProvider.sol";
import {ChainId} from "../contracts/common/ProtocolTypes.sol";
import {Config} from "./Config.sol";

/// @notice One-shot script to configure the Sepolia transport with the
///         Fuji remote transport address.
///
///   REMOTE_TRANSPORT=0x1D28767d8e0Cd01A05EC23f80b977fe39C62892d \
///     forge script script/ConfigureSepoliaTransport.s.sol \
///     --rpc-url https://ethereum-sepolia.publicnode.com \
///     --broadcast --private-key $PK -vvv
contract ConfigureSepoliaTransport is Script {
    // New Sepolia transport (deployed by RedeployAdapter)
    address constant SEP_TRANSPORT = 0x40BBD60d3952f9C5C0654cbA6bb9f0c99fCb3C4a;

    function run() external {
        address remoteTransport = vm.envOr("REMOTE_TRANSPORT", address(0));
        if (remoteTransport == address(0)) {
            revert("Set REMOTE_TRANSPORT env var");
        }

        CCIPTransportProvider transport = CCIPTransportProvider(payable(SEP_TRANSPORT));

        console.log("=== Configuring Sepolia transport ===");
        console.log("Remote transport: %s", vm.toString(remoteTransport));

        vm.startBroadcast();
        // Sepolia is SOURCE_CHAIN (1). Fuji is DEST_CHAIN (2).
        // On Sepolia, Fuji is the remote chain (DEST_CHAIN).
        transport.setAllowedSender(Config.DEST_CHAIN, remoteTransport, true);
        transport.setRemoteReceiver(Config.DEST_CHAIN, remoteTransport);
        vm.stopBroadcast();

        console.log("Sepolia transport configured.");
    }
}
