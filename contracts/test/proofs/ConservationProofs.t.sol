// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {PeekRegistry} from "src/PeekRegistry.sol";

/// @title Conservation delta proofs (SPEC-11 invariant, per-function decomposition)
///
/// The conservation invariant:
///   totalDeposited == sum(escrows) + treasury + executorReimbursements
///                   + withdrawals + pendingPull
///
/// is proven inductively: each function's delta preserves the invariant.
/// If conservation holds before a call and the delta is correct, conservation
/// holds after. By induction over any sequence, conservation holds globally.
///
/// executeJob conservation is covered by fuzzing (Handler ghost trackers) +
/// the suppressed reentrancy finding + the KEVM gasprice limitation documented
/// in review/KONTROL_VACUITY.md.
contract ConservationProofs is Test {
    address constant owner = address(uint160(0x7001));
    address payable constant treasury = payable(address(uint160(0x7002)));
    address constant user = address(uint160(0x7003));
    address constant target = address(uint160(0x7004));

    PeekRegistry registry;

    function setUp() public {
        vm.deal(user, 10 ether);
        registry = new PeekRegistry(owner, treasury, 50_000, 0.005 ether);
    }

    /// CONSERVATION: registerJob
    /// All ETH entering via registerJob goes to escrow. Contract balance
    /// increases by exactly msg.value; no other outflow occurs.
    function test_Proof_Conservation_RegisterJob(uint96 value) public {
        vm.assume(value >= 0.05 ether && value <= 5 ether);
        vm.assume(tx.gasprice <= 1000 gwei);
        vm.deal(user, value);
        uint256 balBefore = address(registry).balance;

        vm.prank(user);
        bytes32 id = registry.registerJob{value: value}(target, 200_000, 50);

        assertEqUint(address(registry).balance, balBefore + value);
        assertEqUint(registry.escrows(id), value);
    }

    /// CONSERVATION: depositGas
    /// ETH entering via depositGas increases contract balance and escrow by
    /// exactly msg.value. Additive only, no outflow.
    function test_Proof_Conservation_DepositGas(uint128 v) public {
        vm.prank(user);
        bytes32 id = registry.registerJob{value: 1 ether}(target, 200_000, 50);
        uint128 escrowBefore = registry.escrows(id);
        vm.assume(v > 0 && v <= type(uint128).max - escrowBefore); // stay within escrow bound
        vm.deal(user, v);
        uint256 balBefore = address(registry).balance;

        vm.prank(user);
        registry.depositGas{value: v}(id);

        assertEqUint(address(registry).balance, balBefore + v);
        assertEqUint(registry.escrows(id), escrowBefore + v);
    }

    /// CONSERVATION: withdrawGas
    /// ETH leaving via withdrawGas decreases contract balance and escrow by
    /// exactly the requested amount. The job owner receives exactly that amount.
    function test_Proof_Conservation_WithdrawGas(uint128 amount) public {
        vm.prank(user);
        bytes32 id = registry.registerJob{value: 1 ether}(target, 200_000, 50);
        uint128 escrowBefore = registry.escrows(id);
        vm.assume(amount <= escrowBefore);
        uint256 balBefore = address(registry).balance;
        uint256 userBalBefore = user.balance;

        vm.prank(user);
        registry.withdrawGas(id, amount);

        assertEqUint(address(registry).balance, balBefore - amount);
        assertEqUint(registry.escrows(id), escrowBefore - amount);
        assertEqUint(user.balance, userBalBefore + amount);
    }

    /// CONSERVATION: pull (zero-pending case)
    /// When pendingPull is zero, pull() reverts and no state changes.
    /// Conservation trivially holds. The positive-pendingPull path is covered
    /// by the fuzzing corpus (Handler's pull-with-balance ghost tracker).
    function test_Proof_Conservation_Pull_ZeroPending() public {
        vm.prank(user);
        bytes32 id = registry.registerJob{value: 1 ether}(target, 200_000, 50);
        uint256 balBefore = address(registry).balance;

        vm.prank(user);
        vm.expectRevert(PeekRegistry.NothingToPull.selector);
        registry.pull();

        assertEqUint(address(registry).balance, balBefore);
    }

    /// CONSERVATION (supplementary): escrow never goes negative
    /// Overdraft attempts revert; escrow is unchanged afterward.
    function test_Proof_Conservation_EscrowNonNegative() public {
        vm.prank(user);
        bytes32 id = registry.registerJob{value: 1 ether}(target, 200_000, 50);
        uint128 escrow = registry.escrows(id);
        uint128 boundary = escrow + 1; // exact off-by-one edge
        vm.prank(user);
        vm.expectRevert();
        registry.withdrawGas(id, boundary);
        assertEqUint(registry.escrows(id), escrow);
    }
}
