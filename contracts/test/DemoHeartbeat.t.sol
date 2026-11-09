// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DemoHeartbeat} from "../src/DemoHeartbeat.sol";

contract DemoHeartbeatTest is Test {
    address internal registry = makeAddr("registry");
    address internal attacker = makeAddr("attacker");

    DemoHeartbeat internal demo;

    function setUp() public {
        demo = new DemoHeartbeat(registry);
    }

    function test_CheckJob_FlipsFalseToTrueWhenDue() public {
        (bool canExec,) = demo.checkJob();
        assertFalse(canExec); // not due in the deploy block
        vm.warp(vm.getBlockTimestamp() + 1 hours - 1);
        (canExec,) = demo.checkJob();
        assertFalse(canExec);
        vm.warp(vm.getBlockTimestamp() + 1);
        (canExec,) = demo.checkJob();
        assertTrue(canExec); // due after the hour
    }

    function test_CheckJob_PayloadCarriesTheDemoNote() public {
        (, bytes memory payload) = demo.checkJob();
        assertEq(payload, bytes(demo.NOTE())); // the URL rides in the executeJob calldata
    }

    function test_PerformJob_FromMockRegistryTicksAndResets() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        // read BEFORE the prank: an external call would consume it
        string memory note = demo.NOTE();
        vm.prank(registry);
        vm.expectEmit(false, false, false, true, address(demo));
        emit DemoTick(1, vm.getBlockTimestamp() + 1 hours, note);
        demo.performJob("");
        assertEq(demo.runCount(), 1);
        assertEq(demo.nextRun(), vm.getBlockTimestamp() + 1 hours);
        (bool canExec,) = demo.checkJob();
        assertFalse(canExec); // false on the very next block (RULE-12)
    }

    function test_PerformJob_RevertsForNonRegistry() public {
        vm.prank(attacker);
        vm.expectRevert(DemoHeartbeat.NotRegistry.selector);
        demo.performJob("");
    }

    function test_PerformJob_IdempotentWithinTheHour() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.startPrank(registry);
        demo.performJob("");
        demo.performJob(""); // concurrent executor lost the race: quiet no-op
        vm.stopPrank();
        assertEq(demo.runCount(), 1);
    }

    function test_PerformJob_ScheduleHasNoDrift() public {
        // a tick that lands 7 minutes late still schedules on the hour grid
        uint256 first = demo.nextRun();
        vm.warp(first + 7 minutes);
        vm.prank(registry);
        demo.performJob("");
        assertEq(demo.nextRun(), first + 1 hours);
    }

    event DemoTick(uint256 indexed run, uint256 nextTick, string note);
}
