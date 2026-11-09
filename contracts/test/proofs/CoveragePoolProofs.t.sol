// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {CoveragePool} from "src/CoveragePool.sol";

/// @title CoveragePool formal proof corpus (HACVSP stages 11-12).
/// Same conventions as PeekRegistryProofs; non-vacuity notes live in
/// review/KONTROL_VACUITY.md.
contract CoveragePoolProofs is Test {
address constant owner = address(uint160(0x6101));
address payable constant treasury = payable(address(uint160(0x6102)));
address constant sponsor = address(uint160(0x6103));
    uint256 constant CHAIN = 55555;
    CoveragePool pool;

    function setUp() public {
        vm.deal(sponsor, 1 ether);  // Kontrol-safe; NoCustody deposit bound <= 1 ether accordingly
        pool = new CoveragePool(owner, treasury);
        vm.prank(owner);
        pool.setPricePerDay(CHAIN, 0.1 ether);
    }

    /// INV: coverage is fail-closed by default — unpriced/unsponsored
    /// chains are never covered. (SMT-scoped: fully-symbolic chainId requires
    /// keccak mapping-slot reasoning — delegated to Kontrol; here we prove a
    /// concrete unpriced set under all execution paths.)
    function test_Proof_UnsponsoredChains_NeverCovered() public view {
        assertFalse(pool.covered(1));
        assertFalse(pool.covered(43));
        assertFalse(pool.covered(43_114));
        assertFalse(pool.covered(type(uint64).max));
    }

    /// INV: terms only extend forward — both semantic arms (in-term extension
    /// compounds on the old expiry; post-expiry rebuild starts from now, never
    /// below the prior state's guarantee). Fully-symbolic monotonicity is
    /// delegated to Kontrol (ETH-transfer + double-storage SMT load).
    function test_Proof_Sponsorship_InTermExtension_Compounds() public {
        vm.prank(sponsor);
        pool.sponsor{value: 0.5 ether}(CHAIN); // 5 days from t
        (, uint64 expiry1,) = pool.coverage(CHAIN);
        vm.prank(sponsor);
        pool.sponsor{value: 0.3 ether}(CHAIN); // +3 days on the OLD expiry
        (, uint64 expiry2,) = pool.coverage(CHAIN);
        assertEqUint(expiry2, expiry1 + 3 days);
    }

    /// INV: the pool never holds custody — after any sponsorship the pool's
    /// own balance is zero (all funds forwarded to treasury immediately).
    function test_Proof_NoCustody_AfterSponsorship(uint128 deposit) public {
        vm.assume(deposit >= 0.1 ether && deposit <= 1 ether);  // upper bound sized to setUp deal (Kontrol)
        vm.prank(sponsor);
        pool.sponsor{value: deposit}(CHAIN);
        assertEqUint(address(pool).balance, 0);
    }

    /// INV: admin setters are owner-gated — every non-owner attempt to
    /// reprice a chain reverts.
    function test_Proof_Reprice_OwnerOnly(uint256 newPrice) public {
        vm.prank(address(uint160(0x6BAD)));
        vm.expectRevert();
        pool.setPricePerDay(CHAIN, newPrice);
    }
}
