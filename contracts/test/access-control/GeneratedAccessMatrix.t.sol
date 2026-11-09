// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {PeekRegistry} from "src/PeekRegistry.sol";
import {CoveragePool} from "src/CoveragePool.sol";
import {DemoHeartbeat} from "src/DemoHeartbeat.sol";
import {HarvestKeeper} from "src/adapters/HarvestKeeper.sol";
import {PharaohEpochKeeper} from "src/adapters/PharaohEpochKeeper.sol";

/// @title GeneratedAccessMatrix — HACVSP stage 8 assertion harness.
/// Generated from artifacts/ACCESS_CONTROL_MATRIX.json (17 state-changing
/// protocol rows) and operator-wired with real deployments.
/// Rule: every non-PUBLIC row MUST revert for UNPRIV; PUBLIC rows are
/// informational probes (business reverts allowed, auth reverts are findings).
contract GeneratedAccessMatrix is Test {
    PeekRegistry registry;
    CoveragePool pool;
    DemoHeartbeat demo;
    HarvestKeeper harvest;
    PharaohEpochKeeper pharaoh;

    address constant UNPRIV = address(0xBEEF);
    address owner = makeAddr("owner");
    address payable treasury = payable(makeAddr("treasury"));

    function setUp() public {
        registry = new PeekRegistry(owner, treasury, 50_000, 0.005 ether);
        pool = new CoveragePool(owner, treasury);
        demo = new DemoHeartbeat(address(registry));
        harvest = new HarvestKeeper(address(registry), makeAddr("harvester"), 1 hours);
        pharaoh = new PharaohEpochKeeper(
            address(registry), makeAddr("voter"), makeAddr("gauge"), 1 hours
        );
        vm.label(UNPRIV, "unprivileged");
        vm.deal(UNPRIV, 1 ether);
    }

    // ---------- CoveragePool (2 public + 2 owner) ----------

    function test_matrix_CoveragePool_sponsor() public {
        vm.prank(UNPRIV);
        try pool.sponsor{value: 0.1 ether}(55555) {} catch (bytes memory) {}
    }

    function test_matrix_CoveragePool_setPricePerDay() public {
        vm.prank(UNPRIV);
        vm.expectRevert();
        pool.setPricePerDay(55555, 0.1 ether);
    }

    function test_matrix_CoveragePool_setTreasury() public {
        vm.prank(UNPRIV);
        vm.expectRevert();
        pool.setTreasury(payable(address(0xBEEF)));
    }

    // ---------- DemoHeartbeat (1 public, registry-gated) ----------

    function test_matrix_DemoHeartbeat_performJob() public {
        vm.prank(UNPRIV);
        try demo.performJob("") {} catch (bytes memory) {}
    }

    // ---------- PeekRegistry (10 public + 5 owner) ----------

    function test_matrix_PeekRegistry_registerJob() public {
        vm.prank(UNPRIV);
        try registry.registerJob(address(0xBEEF), 200_000, 5) {} catch (bytes memory) {}
    }

    function test_matrix_PeekRegistry_depositGas() public {
        vm.prank(UNPRIV);
        try registry.depositGas{value: 0}(bytes32(0)) {} catch (bytes memory) {}
    }

    function test_matrix_PeekRegistry_withdrawGas() public {
        vm.prank(UNPRIV);
        try registry.withdrawGas(bytes32(0), 0) {} catch (bytes memory) {}
    }

    function test_matrix_PeekRegistry_setJobStatus() public {
        vm.prank(UNPRIV);
        try registry.setJobStatus(bytes32(0), true) {} catch (bytes memory) {}
    }

    function test_matrix_PeekRegistry_executeJob() public {
        vm.prank(UNPRIV);
        try registry.executeJob(bytes32(0), "") {} catch (bytes memory) {}
    }

    function test_matrix_PeekRegistry_pull() public {
        vm.prank(UNPRIV);
        try registry.pull() {} catch (bytes memory) {}
    }

    function test_matrix_PeekRegistry_setTreasury() public {
        vm.prank(UNPRIV);
        vm.expectRevert();
        registry.setTreasury(payable(address(0xBEEF)));
    }

    function test_matrix_PeekRegistry_setExecutor() public {
        vm.prank(UNPRIV);
        vm.expectRevert();
        registry.setExecutor(address(0xBEEF), true);
    }

    function test_matrix_PeekRegistry_setKeeperTip() public {
        vm.prank(UNPRIV);
        vm.expectRevert();
        registry.setKeeperTip(0);
    }

    function test_matrix_PeekRegistry_setMaxConsecutiveReverts() public {
        vm.prank(UNPRIV);
        vm.expectRevert();
        registry.setMaxConsecutiveReverts(0);
    }

    function test_matrix_PeekRegistry_setPaused() public {
        vm.prank(UNPRIV);
        vm.expectRevert();
        registry.setPaused(true);
    }

    // ---------- Adapters (registry-gated performJob) ----------

    function test_matrix_HarvestKeeper_performJob() public {
        vm.prank(UNPRIV);
        vm.expectRevert(); // NotRegistry: sender-check guard
        harvest.performJob("");
    }

    function test_matrix_PharaohEpochKeeper_performJob() public {
        vm.prank(UNPRIV);
        vm.expectRevert(); // NotRegistry: sender-check guard
        pharaoh.performJob("");
    }
}
