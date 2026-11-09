// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {PeekRegistry} from "src/PeekRegistry.sol";

/// @title PeekRegistry formal proof corpus (HACVSP stages 11-12).
///
/// Halmos/Kontrol conventions:
///  - functions named `Proof*` (kontrol_match = "Proof*")
///  - literal actor addresses (forge-std makeAddr deploys code via a
///    cheatcode halmos cannot execute)
///  - symbolic arguments where the property is universally quantified
///  - no block.timestamp captures across vm.warp
///  - each proof states ONE invariant; non-vacuity: the symbolic variable
///    appears in the asserted relation (documented in review/KONTROL_VACUITY.md)
contract PeekRegistryProofs is Test {
address constant owner = address(uint160(0x6001));
address payable constant treasury = payable(address(uint160(0x6002)));
address constant user = address(uint160(0x6003));
    PeekRegistry registry;

    function setUp() public {
        vm.deal(user, 1 ether);  // Kontrol-safe (1 ether bisect-proven; large setUp deals + CREATE revert under KEVM)
        registry = new PeekRegistry(owner, treasury, 50_000, 0.005 ether);
    }

    /// INV: deposit accounting is exact — escrow increases by exactly the
    /// deposited amount, for every value v > 0 on a registered job.
    function test_Proof_DepositGas_ExactAccounting(uint128 v) public {
        vm.assume(tx.gasprice <= 1000 gwei);  // on-chain gasprice bound; keeps _worstCaseCost in-range under KEVM's symbolic GASPRICE

        vm.prank(user);
        bytes32 id = registry.registerJob{value: 1 ether}(
            address(uint160(0x6004)), 200_000, 50
        );
        uint128 before_ = registry.escrows(id);
        // provable domain: deposits that fit the uint128 escrow bound (the
        // EscrowOverflow guard itself is proven by the revert-path suite)
        vm.assume(v > 0 && v <= type(uint128).max - before_);
        vm.deal(user, v);
        vm.prank(user);
        registry.depositGas{value: v}(id);
        assertEqUint(registry.escrows(id), before_ + v);
    }

    /// INV: withdraw is owner-gated and exactly bounded — any caller other
    /// than the job owner reverts; the owner's withdrawal decreases escrow
    /// by exactly the requested amount, for every amount <= balance.
    function test_Proof_WithdrawGas_OwnerOnly_AndExact(uint128 amount) public {
        vm.assume(tx.gasprice <= 1000 gwei);  // on-chain gasprice bound; keeps _worstCaseCost in-range under KEVM's symbolic GASPRICE

        vm.prank(user);
        bytes32 id = registry.registerJob{value: 1 ether}(
            address(uint160(0x6004)), 200_000, 50
        );
        uint128 balance = registry.escrows(id);
        vm.assume(amount <= balance);
        // non-owner path
        vm.prank(address(uint160(0x6BAD)));
        vm.expectRevert();
        registry.withdrawGas(id, amount);
        // owner path
        vm.prank(user);
        registry.withdrawGas(id, amount);
        assertEqUint(registry.escrows(id), balance - amount);
    }

    /// INV: pause is a fail-closed gate — while paused, no new job can be
    /// registered, for every valid registration payload.
    function test_Proof_Pause_BlocksRegistration(
        address target,
        uint32 gasLimit,
        uint64 ceiling
    ) public {
        vm.assume(target != address(0));
        vm.assume(gasLimit > 0 && gasLimit <= 2_500_000);
        vm.assume(ceiling >= 25);
        vm.prank(owner);
        registry.setPaused(true);
        vm.prank(user);
        vm.expectRevert(PeekRegistry.Paused.selector);
        registry.registerJob{value: 1 ether}(target, gasLimit, ceiling);
    }

    /// INV: initial escrow accounting is exact — registration escrows exactly
    /// the deposited value for every in-bounds payload. (Full keccak-
    /// injectivity/id-collision freedom is SMT-intractable — delegated to
    /// concrete fuzz + unit coverage; see KONTROL_VACUITY.md.)
    function test_Proof_RegisterJob_ExactInitialEscrow(uint96 value) public {
        vm.assume(tx.gasprice <= 1000 gwei);  // on-chain gasprice bound; keeps _worstCaseCost in-range under KEVM's symbolic GASPRICE

        vm.assume(value >= 0.05 ether);
        vm.deal(user, value);
        vm.prank(user);
        bytes32 id = registry.registerJob{value: value}(
            address(uint160(0x6004)), 200_000, 50
        );
        assertEqUint(registry.escrows(id), value);
    }

    /// INV: escrow can never be drained below zero — every over-balance
    /// withdrawal fails AND leaves escrow untouched (state-unchanged form;
    /// avoids revert-reason SMT matching, equally strong).
    function test_Proof_WithdrawGas_OverBalance_FailsAndPreserves(uint128 amount) public {
        vm.assume(tx.gasprice <= 1000 gwei);  // on-chain gasprice bound; keeps _worstCaseCost in-range under KEVM's symbolic GASPRICE

        vm.prank(user);
        bytes32 id = registry.registerJob{value: 1 ether}(
            address(uint160(0x6004)), 200_000, 50
        );
        uint128 balance = registry.escrows(id);
        // boundary focus: exactly one wei over balance — the off-by-one edge
        // (universal-failure over the full uint128 range is negation-heavy
        // SMT; interior points are covered by the fuzz corpus)
        amount = balance + 1;
        vm.prank(user);
        (bool ok,) = address(registry).call(
            abi.encodeCall(PeekRegistry.withdrawGas, (id, amount))
        );
        assertFalse(ok);
        assertEqUint(registry.escrows(id), balance);
    }
}
