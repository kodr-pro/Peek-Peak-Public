// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoveragePool} from "../src/CoveragePool.sol";

contract CoveragePoolTest is Test {
    CoveragePool internal pool;
    address internal owner = makeAddr("owner");
    address payable internal treasury = payable(makeAddr("treasury"));
    address internal sponsor1 = makeAddr("sponsor1");
    uint256 internal constant CHAIN = 55555;

    function setUp() public {
        vm.deal(sponsor1, 100 ether);
        vm.prank(owner);
        pool = new CoveragePool(owner, treasury);
        vm.prank(owner);
        pool.setPricePerDay(CHAIN, 0.1 ether);
    }

    function _sponsor(address who, uint256 amount) internal {
        vm.prank(who);
        pool.sponsor{value: amount}(CHAIN);
    }

    function test_Sponsor_BuysWholeDays_AndPaysTreasuryImmediately() public {
        uint256 before = treasury.balance;
        vm.expectEmit(true, true, false, true, address(pool));
        emit CoveragePool.Sponsored(CHAIN, sponsor1, 0.5 ether, uint64(block.timestamp + 5 days));
        _sponsor(sponsor1, 0.5 ether);

        (bool active, uint64 expiresAt,) = pool.coverage(CHAIN);
        assertTrue(active);
        assertEq(expiresAt, block.timestamp + 5 days);
        assertEq(treasury.balance - before, 0.5 ether); // revenue on receipt
        assertEq(address(pool).balance, 0); // no custody held
    }

    /// HACVSP stage-9 mutant 2 (IfStatementMutation on the zero-treasury
    /// constructor guard): no prior test constructed CoveragePool with a
    /// zero treasury, so removing the guard survived. Kill it.
    function test_Reverts_ZeroTreasuryConstructor() public {
        vm.prank(owner);
        vm.expectRevert(CoveragePool.InvalidTreasury.selector);
        new CoveragePool(owner, payable(address(0)));
    }

    /// HACVSP stage-7 branch gap: sponsor() ternary's expired-term arm —
    /// when the old term has lapsed, the new term builds from NOW, not the
    /// stale base (fail-closed: no phantom coverage from expired prepayments).
    function test_Sponsor_AfterExpiry_RebuildsFromNowNotStaleBase() public {
        uint256 t0 = vm.getBlockTimestamp(); // via_ir-safe capture
        _sponsor(sponsor1, 0.1 ether); // 1 day
        vm.warp(t0 + 1 days + 1 seconds);
        assertFalse(pool.covered(CHAIN)); // expired
        _sponsor(sponsor1, 0.3 ether); // 3 days from NOW
        (, uint64 expiresAt,) = pool.coverage(CHAIN);
        assertEq(expiresAt, uint64(vm.getBlockTimestamp() + 3 days));
    }

    function test_Covered_FalseBeforeExpiryAndAfter() public {
        assertFalse(pool.covered(CHAIN));
        _sponsor(sponsor1, 0.1 ether); // 1 day
        assertTrue(pool.covered(CHAIN));
        vm.warp(block.timestamp + 1 days + 1 seconds);
        assertFalse(pool.covered(CHAIN)); // time-expiring: fail-closed
    }

    function test_Sponsor_ExtendsForwardOnly() public {
        // via_ir-safe time capture: block.timestamp is rematerialized by the
        // Yul optimizer at use sites (tx-stable assumption), which vm.warp
        // violates mid-test. The cheatcode read is a real call — immune.
        uint256 t0 = vm.getBlockTimestamp();
        _sponsor(sponsor1, 0.5 ether); // expiry = t0 + 5d
        vm.warp(t0 + 2 days);
        _sponsor(sponsor1, 0.3 ether); // +3 days on top of the OLD expiry
        (, uint64 expiresAt,) = pool.coverage(CHAIN);
        // base = prior expiry (t0+5d), not now (t0+2d) => t0+8d = now + 6d
        assertEq(expiresAt, block.timestamp + 6 days);
        assertEq(uint256(expiresAt), t0 + 8 days);
    }

    function test_Sponsor_PartialDayRoundsDownAndIsRevenue() public {
        uint256 before = treasury.balance;
        _sponsor(sponsor1, 0.14 ether); // 1 whole day at 0.1/day, 0.04 surplus
        (bool active, uint64 expiresAt,) = pool.coverage(CHAIN);
        assertTrue(active);
        assertEq(expiresAt, block.timestamp + 1 days);
        assertEq(treasury.balance - before, 0.14 ether); // full amount is revenue
    }

    function test_Sponsor_Reverts_UnpricedChain() public {
        vm.prank(sponsor1);
        vm.expectRevert(CoveragePool.UnpricedChain.selector);
        pool.sponsor{value: 1 ether}(99999);
    }

    function test_Sponsor_Reverts_ZeroChainId() public {
        vm.prank(sponsor1);
        vm.expectRevert(CoveragePool.ZeroChainId.selector);
        pool.sponsor{value: 1 ether}(0);
    }

    function test_Sponsor_Reverts_BelowOneDayPrice() public {
        vm.prank(sponsor1);
        vm.expectRevert(CoveragePool.InsufficientDeposit.selector);
        pool.sponsor{value: 0.05 ether}(CHAIN);
    }

    function test_SetPricePerDay_OnlyOwner_AndNotRetroactive() public {
        _sponsor(sponsor1, 0.1 ether); // 1 day at 0.1
        vm.prank(owner);
        pool.setPricePerDay(CHAIN, 0.2 ether); // price change...
        (, uint64 expiresAt,) = pool.coverage(CHAIN);
        assertEq(expiresAt, block.timestamp + 1 days); // ...does not touch active term
        vm.prank(sponsor1);
        vm.expectRevert();
        pool.setPricePerDay(CHAIN, 1 ether);
    }

    function test_SetTreasury_RoutesFutureDeposits() public {
        address payable t2 = payable(makeAddr("t2"));
        vm.prank(owner);
        pool.setTreasury(t2);
        _sponsor(sponsor1, 0.1 ether);
        assertEq(t2.balance, 0.1 ether);
    }

    function test_Sponsor_Reverts_TermTooLong() public {
        vm.prank(sponsor1);
        vm.expectRevert(CoveragePool.TermTooLong.selector);
        pool.sponsor{value: 0.1 ether * 366}(CHAIN); // 366 days > MAX_TERM_DAYS
    }

    function test_Sponsor_Reverts_AbsurdDepositBeyondUint128() public {
        // RULE-6: deposits beyond uint128 bound the narrowing cast loudly
        vm.deal(address(this), uint256(type(uint128).max) + 1);
        vm.prank(address(this));
        vm.expectRevert(CoveragePool.InsufficientDeposit.selector);
        pool.sponsor{value: uint256(type(uint128).max) + 1}(CHAIN);
    }

    function test_ReceivingEthDirectlyReverts() public {
        (bool ok,) = address(pool).call{value: 1 ether}("");
        assertFalse(ok); // no receive: all value flows through sponsor()
    }
}
