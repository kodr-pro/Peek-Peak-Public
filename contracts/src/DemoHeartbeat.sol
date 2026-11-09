// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAutoJob} from "./IAutoJob.sol";

/// @title DemoHeartbeat - PeekPeak's public hourly demo job.
/// @notice A self-running showcase: one autonomous tick per hour, forever,
///         each one leaving two human-readable traces on-chain -
///         a `DemoTick` event and the demo URL inside the `executeJob`
///         calldata (the `execPayload` below is forwarded verbatim by the
///         registry, so it is visible in the transaction input on the
///         explorer). Deployed behind the C-Chain registry, verified, and
///         funded from a dedicated owner wallet.
/// @dev `performJob` makes NO external calls - there is nothing to re-enter,
///      nothing to fail mid-flight, and the escrow spend per tick is exactly
///      gas + the flat keeper tip. The state flip happens BEFORE anything
///      else (SKILL.md rule 4): `checkJob` is false on the very next block.
contract DemoHeartbeat is IAutoJob {
    uint256 public constant INTERVAL = 1 hours;

    /// @notice Carried into every `executeJob` transaction's calldata.
    string public constant NOTE = "PeekPeak autonomous demo - runs itself every hour - peekpeak.app/start";

    address public immutable REGISTRY_ADDRESS;
    uint256 public nextRun;
    uint256 public runCount;

    event DemoTick(uint256 indexed run, uint256 nextTick, string note);

    error NotRegistry();

    /// @param registry Address of the deployed PeekRegistry that may call performJob.
    constructor(address registry) {
        REGISTRY_ADDRESS = registry;
        nextRun = block.timestamp + INTERVAL; // first public tick ~1h after deploy
    }

    /// @notice Ready exactly when the hour has elapsed.
    function checkJob() external view returns (bool canExec, bytes memory) {
        return (block.timestamp >= nextRun, bytes(NOTE));
    }

    /// @notice Record the tick and schedule the next one. Registry only.
    /// @dev Idempotent: a second call inside the same hour returns quietly.
    function performJob(bytes calldata) external {
        if (msg.sender != REGISTRY_ADDRESS) revert NotRegistry();
        uint256 ts = nextRun;
        if (block.timestamp < ts) return; // not due: concurrent executor lost the race

        runCount += 1; // effect first
        nextRun = ts + INTERVAL; // schedule from the PLANNED tick, not `now` - no drift

        emit DemoTick(runCount, nextRun, NOTE);
    }
}
