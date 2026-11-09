// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAutoJob} from "../IAutoJob.sol";

/// @notice Minimal interface surface PeekPeak needs from a claimer. Any
///         Solidly-style gauge, MasterChef-style pool, or reward vault that
///         exposes a parameterless `harvest()`/`claim()` fits.
interface IHarvester {
    function harvest() external;
}

/// @title HarvestKeeper - thin harvest/claim `IAutoJob` template.
/// @notice Calls `harvest()` on a target on a fixed cadence - the simplest
///         useful automation: "claim my rewards every N hours". Deploy one
///         keeper per target; PeekPeak funds it via the registry escrow.
/// @dev `performJob` is restricted to the immutable `REGISTRY_ADDRESS` and
///      advances `nextRun` BEFORE the external call (SKILL.md rule 4), so a
///      reverting harvest can never be retried into a double-claim window -
///      the miss is recorded in the `Harvested` event and caught up at the
///      next interval.
contract HarvestKeeper is IAutoJob {
    address public immutable REGISTRY_ADDRESS;
    IHarvester public immutable harvester;
    uint256 public immutable interval;
    uint256 public nextRun;
    uint256 public harvestCount;

    event Harvested(uint256 indexed run, uint256 nextScheduled, bool ok);

    error NotRegistry();
    error IntervalOutOfBounds();

    /// @param registry Address of the deployed PeekRegistry that may call performJob.
    /// @param harvester_ Contract whose `harvest()` is called when due.
    /// @param interval_ Cadence in seconds (>= 1 minute, <= 1 year).
    constructor(address registry, address harvester_, uint256 interval_) {
        if (interval_ < 1 minutes || interval_ > 365 days) revert IntervalOutOfBounds();
        REGISTRY_ADDRESS = registry;
        harvester = IHarvester(harvester_);
        interval = interval_;
        nextRun = block.timestamp + interval_;
    }

    /// @notice Ready when the cadence has elapsed.
    function checkJob() external view returns (bool canExec, bytes memory) {
        return (block.timestamp >= nextRun, "");
    }

    /// @notice Harvest and reschedule. Only the registry may call.
    /// @dev Idempotent within an interval; a failing harvest still advances
    ///      the schedule (flagged `ok = false`) - never re-harvest the same
    ///      window on retry.
    function performJob(bytes calldata) external {
        if (msg.sender != REGISTRY_ADDRESS) revert NotRegistry();
        uint256 ts = nextRun;
        if (block.timestamp < ts) return; // idempotent: nothing due

        harvestCount += 1; // effect first
        nextRun = ts + interval; // schedule from the PLANNED run - no drift

        bool ok = false;
        // swallow-on-purpose: a failed harvest must not roll the schedule
        // back (no double-claim retry storm); the outcome is recorded in the
        // Harvested flags and caught up at the next interval.
        try harvester.harvest() {
            ok = true;
        } catch {
            ok = false;
        }

        emit Harvested(harvestCount, nextRun, ok);
    }
}
