// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PeekPeakScript} from "./PeekPeak.s.sol";
import {PeekRegistry} from "../src/PeekRegistry.sol";
import {DemoHeartbeat} from "../src/DemoHeartbeat.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploys the public hourly demo job and registers it on a deployed
///         PeekRegistry. Runbook: docs/demo-job.md.
///         Env: REGISTRY, GAS_LIMIT (default 300_000 - observed ticks use
///         ~120k), MAX_GAS_PRICE_GWEI (default 25 - the registry floor),
///         DEPOSIT_WEI (default 1 AVAX ~ 185 hourly ticks at the 0.005 tip).
///         Broadcast: `--account <foundry-keystore-name>` (the dedicated
///         demo-owner wallet; the key never appears in a command line).
contract DeployDemoHeartbeat is PeekPeakScript {
    function run() external {
        PeekRegistry registry = PeekRegistry(vm.envAddress("REGISTRY"));
        uint32 gasLimit = uint32(vm.envOr("GAS_LIMIT", uint256(300_000)));
        uint64 ceiling = uint64(vm.envOr("MAX_GAS_PRICE_GWEI", uint256(25)));
        uint256 deposit = vm.envOr("DEPOSIT_WEI", uint256(1 ether));

        _broadcast();
        DemoHeartbeat demo = new DemoHeartbeat(address(registry));
        bytes32 jobId = registry.registerJob{value: deposit}(address(demo), gasLimit, ceiling);
        vm.stopBroadcast();

        _recordChainJson("DemoHeartbeat", address(demo));
        console2.log("jobId:");
        console2.logBytes32(jobId);
    }
}
