// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HarvestKeeper} from "../src/adapters/HarvestKeeper.sol";
import {FailingGauge, MockGauge} from "./helpers/TestContracts.sol";

contract HarvestKeeperTest is Test {
    address internal registry = makeAddr("registry");
    address internal attacker = makeAddr("attacker");

    MockGauge internal gauge;
    HarvestKeeper internal keeper;

    function setUp() public {
        gauge = new MockGauge();
        keeper = new HarvestKeeper(registry, address(gauge), 6 hours);
    }

    function test_CheckJob_FlipsFalseToTrueWhenDue() public {
        (bool canExec,) = keeper.checkJob();
        assertFalse(canExec); // not due initially
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        (canExec,) = keeper.checkJob();
        assertTrue(canExec); // due after the interval
    }

    function test_PerformJob_FromMockRegistryHarvestsAndResets() public {
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        vm.prank(registry);
        keeper.performJob("");
        assertEq(gauge.harvestCount(), 1);
        assertEq(keeper.harvestCount(), 1);
        assertEq(keeper.nextRun(), vm.getBlockTimestamp() + 6 hours);
        (bool canExec,) = keeper.checkJob();
        assertFalse(canExec); // false on the very next block (RULE-12)
    }

    function test_PerformJob_RevertsForNonRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(HarvestKeeper.NotRegistry.selector);
        keeper.performJob("");
    }

    function test_PerformJob_IdempotentWithinInterval() public {
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        vm.prank(registry);
        keeper.performJob("");
        vm.prank(registry);
        keeper.performJob(""); // quiet no-op
        assertEq(gauge.harvestCount(), 1);
    }

    function test_PerformJob_FailingHarvestDoesNotRollBackSchedule() public {
        FailingGauge failing = new FailingGauge();
        HarvestKeeper broken = new HarvestKeeper(registry, address(failing), 6 hours);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        vm.prank(registry);
        vm.expectEmit(false, false, false, true, address(broken));
        emit Harvested(1, vm.getBlockTimestamp() + 6 hours, false);
        broken.performJob("");
        assertEq(broken.nextRun(), vm.getBlockTimestamp() + 6 hours); // advanced despite the failure
        (bool canExec,) = broken.checkJob();
        assertFalse(canExec); // no retry storm: window never re-opens
    }

    function test_Constructor_RevertsForOutOfBoundsInterval() public {
        vm.expectRevert(HarvestKeeper.IntervalOutOfBounds.selector);
        new HarvestKeeper(registry, address(gauge), 30 seconds);
        vm.expectRevert(HarvestKeeper.IntervalOutOfBounds.selector);
        new HarvestKeeper(registry, address(gauge), 366 days);
    }

    event Harvested(uint256 indexed run, uint256 nextScheduled, bool ok);
}
