// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {WeekendGuard} from "../src/WeekendGuard.sol";
import {IMorpho} from "../src/interfaces/IMorpho.sol";

/// Usage:
///   export ROBINHOOD_TESTNET_RPC=<rpc url>
///   export MORPHO_ADDRESS=<Morpho Blue address on Robinhood Chain testnet>
///   forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --interactive
/// `--interactive` asks for the deployer private key in the terminal, so it is never stored in a file.
contract Deploy is Script {
    function run() external returns (WeekendGuard guard) {
        address morpho = vm.envAddress("MORPHO_ADDRESS");
        require(morpho.code.length > 0, "MORPHO_ADDRESS has no code on this chain");

        vm.startBroadcast();
        guard = new WeekendGuard(IMorpho(morpho));
        vm.stopBroadcast();

        console2.log("WeekendGuard deployed at", address(guard));
    }
}
