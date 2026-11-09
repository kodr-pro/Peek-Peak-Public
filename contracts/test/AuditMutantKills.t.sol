// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {PeekRegistry} from "src/PeekRegistry.sol";
import {CoveragePool} from "src/CoveragePool.sol";
import {HarvestKeeper} from "src/adapters/HarvestKeeper.sol";
import {PharaohEpochKeeper} from "src/adapters/PharaohEpochKeeper.sol";
import {MockGauge} from "test/helpers/TestContracts.sol";
import {MockJob} from "src/mocks/MockJob.sol";

/// @title AuditMutantKills — HACVSP stage-9 survivor triage (test-gap class).
/// Each test kills specific surviving mutants from
/// artifacts/mutation-report.json; ids referenced per test.
contract AuditMutantKills is Test {
    address owner = makeAddr("owner");
    address payable treasury = payable(makeAddr("treasury"));
    address sponsor = makeAddr("sponsor");

    // ------------------------------------------------------------------
    // CoveragePool
    // ------------------------------------------------------------------

    /// kills #43 (setPricePerDay zero-chain guard)
    function test_Kill43_Reverts_SetPricePerDay_ZeroChainId() public {
        CoveragePool pool = new CoveragePool(owner, treasury);
        vm.prank(owner);
        vm.expectRevert(CoveragePool.ZeroChainId.selector);
        pool.setPricePerDay(0, 0.1 ether);
    }

    /// kills #48 (setTreasury zero-address guard)
    function test_Kill48_Reverts_SetTreasury_ZeroAddress() public {
        CoveragePool pool = new CoveragePool(owner, treasury);
        vm.prank(owner);
        vm.expectRevert(CoveragePool.InvalidTreasury.selector);
        pool.setTreasury(payable(address(0)));
    }

    /// kills #40 (sponsor's treasury-forward failure path)
    function test_Kill40_Reverts_Sponsor_WhenTreasuryRejectsEth() public {
        RejectingTreasury bad = new RejectingTreasury();
        CoveragePool pool = new CoveragePool(owner, payable(address(bad)));
        vm.prank(owner);
        pool.setPricePerDay(55555, 0.1 ether);
        vm.deal(sponsor, 1 ether);
        vm.prank(sponsor);
        vm.expectRevert(CoveragePool.TransferFailed.selector);
        pool.sponsor{value: 0.1 ether}(55555);
    }

    // ------------------------------------------------------------------
    // PeekRegistry
    // ------------------------------------------------------------------

    /// kills #114 (jobNonce increment — re-registration must yield a new id)
    function test_Kill114_RegisteringTwice_YieldsDistinctJobIds() public {
        vm.deal(sponsor, 5 ether);
        PeekRegistry registry = new PeekRegistry(owner, treasury, 50_000, 0.005 ether);
        address target = makeAddr("target");
        vm.prank(sponsor);
        bytes32 a = registry.registerJob{value: 1 ether}(target, 200_000, 50);
        vm.prank(sponsor);
        bytes32 b = registry.registerJob{value: 1 ether}(target, 200_000, 50);
        vm.prank(sponsor);
        bytes32 c = registry.registerJob{value: 1 ether}(target, 200_000, 50);
        assertFalse(a == b, "jobNonce did not advance (mutant #114)");
        assertFalse(b == c, "jobNonce stuck (mutant #114): 3rd id collided with 2nd");
    }

    /// kills #271 (setMaxConsecutiveReverts stores the given bound)
    function test_Kill271_SetMaxConsecutiveReverts_Readback() public {
        vm.prank(owner);
        PeekRegistry registry = new PeekRegistry(owner, treasury, 50_000, 0.005 ether);
        vm.prank(owner);
        registry.setMaxConsecutiveReverts(7);
        assertEq(registry.maxConsecutiveReverts(), 7, "bound not stored (mutant #271)");
    }

    /// kills #273 (setPaused(false) actually unpauses)
    function test_Kill273_SetPaused_False_Unpauses() public {
        vm.deal(sponsor, 5 ether);
        PeekRegistry registry = new PeekRegistry(owner, treasury, 50_000, 0.005 ether);
        vm.prank(owner);
        registry.setPaused(true);
        vm.prank(owner);
        registry.setPaused(false);
        // if the mutant forced pause-on, registration now reverts Paused
        vm.prank(sponsor);
        registry.registerJob{value: 1 ether}(makeAddr("t2"), 200_000, 50);
    }

    /// kills #210, #243 (gas-cost arithmetic: modulo/constant-1 cost must
    /// not pass — escrow must drain by tip + a REAL measured gas cost)
    function test_Kill210_243_EscrowDrainsByRealGasCost() public {
        vm.deal(sponsor, 5 ether);
        PeekRegistry registry = new PeekRegistry(owner, treasury, 50_000, 0.005 ether);
        MockJob job = new MockJob(address(registry));
        job.setReady(true);
        job.setGasToBurn(2_000_000);
        vm.prank(sponsor);
        bytes32 id = registry.registerJob{value: 1 ether}(address(job), 2_400_000, 50);
        vm.prank(owner);
        registry.setExecutor(sponsor, true);
        vm.txGasPrice(1 gwei);
        uint128 before_ = registry.escrows(id);
        vm.prank(sponsor);
        registry.executeJob(id, "");
        uint128 delta = before_ - registry.escrows(id);
        uint128 tip = registry.keeperTip();
        // real cost: (>=2M gasUsed + 50k buffer) * 1gwei >= 0.002 ether;
        // modulo mutants stay under ~0.0005 ether, constant-1 under 1 wei.
        assertGt(delta, tip + 0.001 ether, "charge too small (mutant #210)");
        assertLt(delta, tip + 0.05 ether, "charge nonsensically large");
        // direct push refund to the EOA executor carries the measured cost
        assertGt(sponsor.balance, 0.001 ether, "refund ~0 (mutant #243)");
    }

    /// kills #237 (consecutiveReverts resets on success — consecutive, not
    /// cumulative, deactivation semantics)
    function test_Kill237_ConsecutiveRevertsResetOnSuccess() public {
        vm.deal(sponsor, 5 ether);
        PeekRegistry registry = new PeekRegistry(owner, treasury, 50_000, 0.005 ether);
        MockJob job = new MockJob(address(registry));
        vm.prank(sponsor);
        bytes32 id = registry.registerJob{value: 1 ether}(address(job), 200_000, 50);
        vm.prank(owner);
        registry.setExecutor(sponsor, true);
        vm.prank(owner);
        registry.setMaxConsecutiveReverts(2);
        vm.txGasPrice(1 gwei);
        job.setReady(false);
        vm.startPrank(sponsor);
        registry.executeJob(id, ""); // revert #1
        job.setReady(true);
        registry.executeJob(id, ""); // success -> counter resets
        job.setReady(false);
        registry.executeJob(id, ""); // revert (consecutive again 1)
        vm.stopPrank();
        (, , bool isActive, , , ) = registry.jobs(id);
        assertTrue(isActive, "counter is cumulative, not consecutive (mutant #237)");
    }

    /// kills #245 (treasury transfer failure during execution charge)
    function test_Kill245_Reverts_WhenTreasuryRejectsExecutionTip() public {
        vm.deal(sponsor, 5 ether);
        RejectingTreasury bad = new RejectingTreasury();
        PeekRegistry registry = new PeekRegistry(owner, payable(address(bad)), 50_000, 0.005 ether);
        MockJob job = new MockJob(address(registry));
        job.setReady(true);
        vm.prank(sponsor);
        bytes32 id = registry.registerJob{value: 1 ether}(address(job), 200_000, 50);
        vm.prank(owner);
        registry.setExecutor(sponsor, true);
        vm.txGasPrice(1 gwei);
        vm.prank(sponsor);
        vm.expectRevert(PeekRegistry.TreasuryTransferFailed.selector);
        registry.executeJob(id, "");
    }

    /// kills #251 (pull() transfer failure to a rejecting executor)
    function test_Kill251_Reverts_PullToRejectingExecutor() public {
        vm.deal(sponsor, 5 ether);
        PeekRegistry registry = new PeekRegistry(owner, treasury, 50_000, 0.005 ether);
        MockJob job = new MockJob(address(registry));
        job.setReady(true);
        vm.prank(sponsor);
        bytes32 id = registry.registerJob{value: 1 ether}(address(job), 200_000, 50);
        RejectingTreasury executor = new RejectingTreasury();
        vm.prank(owner);
        registry.setExecutor(address(executor), true);
        vm.txGasPrice(1 gwei);
        vm.prank(address(executor));
        registry.executeJob(id, ""); // push refund fails -> pendingPull accrues
        assertGt(
            registry.pendingPull(address(executor)),
            0.00005 ether, // real cost ~0.00008e here; mutant accrues 1 wei
            "fallback accrual ~0 (mutant #243)"
        );
        vm.prank(address(executor));
        vm.expectRevert(PeekRegistry.TransferFailed.selector);
        registry.pull();
    }

    // ------------------------------------------------------------------
    // Keepers — success-leg event flags (deletion/flip mutants)
    // ------------------------------------------------------------------

    /// kills #328, #329 (Harvested(..., ok=true) on the success leg)
    function test_Kill328_329_HarvestSuccessFlagAsserted() public {
        address registry = makeAddr("registry");
        MockGauge gauge = new MockGauge();
        HarvestKeeper keeper = new HarvestKeeper(registry, address(gauge), 6 hours);
        vm.warp(vm.getBlockTimestamp() + 6 hours);
        vm.expectEmit(false, false, false, true, address(keeper));
        emit Harvested(1, vm.getBlockTimestamp() + 6 hours, true);
        vm.prank(registry);
        keeper.performJob("");
    }

    /// kills #354, #355, #360, #361 (EpochRolled success flags on both legs)
    function test_Kill354_361_EpochSuccessFlagsAsserted() public {
        address registry = makeAddr("registry");
        uint256 firstEpoch = 1_700_000_000;
        // voter + gauge mocks from the test helpers; reusing MockGauge for the
        // voter slot requires a distribute() — build via the existing mocks.
        // (constructed inline to keep this file self-contained on the import)
        MockVoterLike voter = new MockVoterLike();
        MockGauge gauge = new MockGauge();
        PharaohEpochKeeper keeper =
            new PharaohEpochKeeper(registry, address(voter), address(gauge), firstEpoch);
        vm.warp(firstEpoch);
        vm.expectEmit(false, false, false, true, address(keeper));
        emit EpochRolled(firstEpoch + 1 weeks, true, true);
        vm.prank(registry);
        keeper.performJob("");
    }

    event Harvested(uint256 indexed run, uint256 nextScheduled, bool ok);
    event EpochRolled(uint256 newEpochTimestamp, bool voterOk, bool gaugeOk);
}

contract RejectingTreasury {
    receive() external payable {
        revert("no eth for you");
    }
}

contract MockVoterLike {
    function distribute() external {}
}
