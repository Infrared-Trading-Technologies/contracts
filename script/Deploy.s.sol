// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { Router } from "../src/Router.sol";

/// @notice Dev-only non-deterministic deployer. Deploys a fresh ExecutionProxy + Router and wires
///         them together in a single broadcast (setPendingExecutor + acceptExecutor) so local
///         integration tests can swap without extra operator steps. Production deploys must use
///         DeployCreate3 (CREATE3, deterministic, multi-chain).
contract DeployScript is Script {
    function run() public {
        uint256 chainId = block.chainid;

        vm.startBroadcast();

        Router router = new Router(msg.sender, msg.sender);
        ExecutionProxy proxy = new ExecutionProxy(address(router));
        router.setPendingExecutor(address(proxy));
        router.acceptExecutor();

        console2.log("Chain ID:", chainId);
        console2.log("ExecutionProxy deployed at:", address(proxy));
        console2.log("Router deployed at:", address(router));

        vm.stopBroadcast();
    }
}
