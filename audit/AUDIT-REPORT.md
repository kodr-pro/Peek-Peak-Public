# PeekPeak Security Audit Report

**Target:** `PeekRegistry` and `CoveragePool` (PeekPeak autonomous execution protocol)
**Scope repo:** `../peekpeak/contracts` (byte-identical to this handoff package's `contracts/`)
**Auditor:** Independent review per `PeekPeak-audit` handoff package
**Date:** 2026-09-25
**Methodology:** Static line-by-line adversarial review against `docs/spec.md` (SPEC-1..13), `docs/review-rules.md` (RULE-1..15), `docs/divergence-register.md` (DIV-D-1..3), `docs/security-checklist.md` (SEC-01..07 contract layer), plus execution verification: `forge build` / `forge test` / `forge coverage`, and two purpose-built proof-of-concept tests for the findings below.

---

## 1. Executive summary

The PeekPeak contract layer is well-engineered: reentrancy is guarded on every payout path, access control is default-deny, escrow arithmetic is uint256 with bounded narrowing, no `transfer()`/`send()` is used anywhere for payouts, soft-exit semantics (DIV-D-1) match the ruling, and the solvency precheck matches the DIV-D-2/D-3 formula. The test suite (75/75 passing, verified) and coverage claims (PeekRegistry 97.32% lines, CoveragePool 100% lines / 89.19% statements — both verified by re-run) are accurate.

Two real defects were found and **confirmed by PoC**:

1. **[Low] Stale-escrow write-back erases concurrent deposits** in `executeJob` — a `depositGas` performed by the target during its own `performJob` is silently destroyed, permanently breaking the protocol's headline conservation invariant (`deposited_wei == Σescrow + pendingPull + payouts + withdrawals`) and stranding the deposited wei.
2. **[Low] The solvency model ignores `execPayload` copy gas** — the code comment calls the post-execution shortfall branch "unreachable"; a ~200 KB `execPayload` (returned by a malicious `checkJob`) makes it reachable: the target's work completes, nobody is charged, and the executor absorbs the full transaction cost. Repeatable per re-activation cycle: a free-execution griefing vector against the operator's executor wallet.

Neither finding threatens user escrow principal under normal operation. A handful of informational notes follow, including one script bug (custom `KEEPER_TIP_WEI` + CREATE2), the known Fuji under-reimbursement (accepted risk, Q-6), and several spec/doc hygiene items.

**Mainnet verdict:** proceed after fixing F-1 and F-2 (both small, surgical changes), or after formally accepting F-2 as mitigated by the worker's broadcast gas cap.

---

## 2. Scope and verification performed

| Item | Result |
|------|--------|
| `forge build` (solc 0.8.37) | clean (lint warnings only) |
| `forge test` | **75/75 passing** — matches README claim |
| `forge coverage --report summary` | PeekRegistry **97.32% lines** (claimed 97.3%), CoveragePool **100% lines / 89.19% statements** (claimed 100/89.2), PharaohEpochKeeper 100% |
| Snapshot vs monorepo `contracts/{src,test,script}` | byte-identical (`diff -r`; only build artifacts differ) |
| Dependency pinning | OZ **v5.7.0** @ `cab1993`, forge-std **v1.16.2** — official tags, no stray forks |
| Fuji deployment evidence | `broadcast/DeployRegistry.s.sol/43113/run-latest.json`: registry `0xad7653a934625858c33864e568e08ebdf7a04664`, deployer `0x9d4e...7d71` — corroborates `docs/fuji-golive.md` (note: the handoff `evidence/` folder is **empty**; claims re-verified independently) |
| PoC suite | 2/2 passing (F-1, F-2), staged in an out-of-repo sandbox |

Out of scope per the package README: off-chain Rust worker (behavioral context only), frontend.

---

## 3. Findings

Severity scale: Critical / High / Medium / Low / Informational.

### F-1 [Low] — Stale escrow snapshot is written back, erasing mid-execution deposits

- **Where:** `contracts/src/PeekRegistry.sol:251` (read), `contracts/src/PeekRegistry.sol:287` (write-back)
- **Class:** checks-effects-interactions residue / storage shadowing (skill Rule 1; SPEC invariant #1; RULE-15/INV-1)
- **Description:** `executeJob` caches `uint128 escrow = escrows[jobId]` *before* dispatching to the target (`PeekRegistry.sol:251`). `depositGas` — unlike `executeJob`, `withdrawGas` and `pull` — carries **no `nonReentrant` guard** (correctly so, since it makes no external calls), so a target contract *can* legitimately re-enter `depositGas` during its own `performJob`. On the success path the registry then writes the stale snapshot wholesale:

  ```solidity
  escrows[jobId] = escrow - uint128(totalDeduction);   // line 287
  ```

  Any wei deposited during the dispatch window is silently erased from the accounting. The registry's balance ends up strictly greater than `Σescrows + pendingPull`: the deposited wei becomes **unaccounted and permanently unrecoverable** (`withdrawGas` can only reach the mapped value; no admin function sweeps surpluses). This is a direct violation of the protocol's first documented invariant (README §"Key invariants", #1) and of invariant INV-1 in the test campaign — the campaign never exercises a target that self-deposits, so it cannot catch this class.
- **Impact:** Low. Only a job target depositing into *its own* escrow mid-`performJob` (buggy integrator, or a deliberate self-harm/conservation-vandalism demo) loses funds; no path exists to steal *another* party's wei. But it breaks the flagship "never a wei more or less" guarantee, which the protocol's marketing and dashboards lean on.
- **PoC (passing):** `SelfDepositingJob` tops up its own escrow with 0.5 AVAX inside `performJob`; after execution the registry holds exactly 0.5 AVAX more than `escrows + pendingPull`.
- **Fix:** mutate relative to storage, not the stale local: `escrows[jobId] -= uint128(totalDeduction);` (after the existing `escrow >= totalDeduction` guard, or re-read `escrows[jobId]` post-call). Cost-neutral. Also worth a sentence in RULE-1's file: the guard set is `{executeJob, withdrawGas, pull}` and the unguarded mutators are additive-only — *except* when their effects are later clobbered by a stale write-back.

### F-2 [Low] — Solvency bound ignores `execPayload` copy gas; "unreachable" defensive branch is reachable

- **Where:** `contracts/src/PeekRegistry.sol:259` (dispatch), `:274` (measurement), `:279-285` (defensive branch + comment)
- **Class:** gas-model assumption / under-bounded accounting (RULE-3, RULE-4; SEC-02's "provably bounded" claim)
- **Description:** the solvency precheck requires `escrow >= (gasLimit + 2·OVERHEAD_BUFFER)·tx.gasprice + keeperTip`, and the code comments assert measured `gasUsed ≤ gasLimit + 2·OVERHEAD_BUFFER` is *provable*. The measured quantity is `gasUsed = (gasInitial − gasleft()) + OVERHEAD_BUFFER`, which includes the `abi.encodeCall` calldata→memory copy of `execPayload` (`PeekRegistry.sol:259`) and the CALL argument copy — both unbounded functions of the payload size. `execPayload` originates from the *target's own* `checkJob()` return value, i.e. it is job-owner-controlled data relayed by an honest worker. A ~200 KB payload adds ~120k gas of copy/expansion cost; with a small `gasLimit` (e.g. 60k) that pushes `gasUsed` past the prechecked bound and drops execution into the "defensive: unreachable while the solvency precheck holds" branch (`:281`): the target has **already run**, nobody is charged, no reimbursement is paid, and the job is deactivated.
- **Impact:** Low (operator-side). The job owner can cycle `setJobStatus(jobId, true)` and get their maintenance executed for free indefinitely; each cycle costs the *executor* real gas — in the PoC, the outer tx consumed ~26.4M gas, dominated by calldata (16 gas/non-zero byte is paid by the sender as intrinsic gas and is *never* measured or reimbursed). On the current permissioned design only the operator's wallet bleeds, and the worker's own defenses (estimate-gas simulation succeeds — the tx *does* succeed; the coreth `gasLimit/2` floor makes oversize payloads extra expensive to the sender) bound the pain. But the on-chain contract does **not** enforce the invariant its comments and RULE-3 claim; a future permissionless-executor world (Q-5 "revisit post-mainnet") would turn this into a direct drain vector against any executor.
- **PoC (passing):** 60k gasLimit job, 200 KB payload → `performCount == 1`, escrow untouched, executor and treasury balances zero, job deactivated via the "unreachable" branch.
- **Fix options (either suffices):**
  1. Bound the payload on-chain: `if (execPayload.length > MAX_PAYLOAD) revert PayloadTooLarge();` (pick e.g. 4–32 KB; legitimate keeper payloads — Pharaoh's `""` — are tiny), or fold `execPayload`-derived gas into the precheck;
  2. Keep the branch but document that the bound holds *only* under the worker's broadcast gas cap (`job.gasLimit + headroom`), and re-verify that cap rejects oversize payloads before any permissionless-executor change.

### F-3 [Informational] — Fuji deployment systematically under-reimburses the executor (accepted risk, verify before mainnet)

`docs/gas-anomaly.md` / Q-6: measured full-transaction overhead is 44,870 gas vs the live Fuji `OVERHEAD_BUFFER = 35,000`, so each Fuji execution under-pays the executor by ~10k·gasPrice. Documented, owner-accepted for testnet, and the deploy script default is already 50,000 (`script/PeekPeak.s.sol:13`). **Mainnet gate item:** confirm the mainnet deploy uses `OVERHEAD_BUFFER=50000` (the `fuji-golive.md` rollback/redeploy notes already commit to this). No code change requested.

### F-4 [Informational] — No upper bound on the `OVERHEAD_BUFFER` constructor argument

`PeekRegistry.sol:147` enforces only `overheadBuffer >= 10_000` (`MIN_OVERHEAD_BUFFER`). A fat-fingered deploy with a huge buffer does not fail loud at registration (unlike an out-of-bounds tip): jobs remain registrable and each successful execution would charge `(measured + buffer)·gasPrice + tip` — technically within the precheck and the client's own escrow, but wildly in excess of "exact gas + flat tip" (RULE-4's spirit). Suggest `overheadBuffer <= 500_000` (10× calibration) to make misconfiguration fail loud. Deploy-hygiene only; current deploy scripts are sane.

### F-5 [Informational] — `DeployRegistry.s.sol` CREATE2 path reverts after deployment when `KEEPER_TIP_WEI` is custom

`script/DeployRegistry.s.sol:42-44` asserts `PeekRegistry(deployed).keeperTip() == 0.005 ether` as a sanity check that the factory returned a registry. With `KEEPER_TIP_WEI` set to any non-default legal value (the SPEC-13 L1 flow explicitly supports this), the assert fails **after** the CREATE2 deployment transaction has already been broadcast, leaving a deployed registry behind a script that exited in error. Compare against `initialTip` instead, or drop the check. Scripts only; no funds at risk.

### F-6 [Informational] — `withdrawGas` is push-only: a job owner that cannot receive ETH strands its escrow

`PeekRegistry.sol:210-211` pushes the withdrawal with `call{value}` and reverts on failure. Executor refunds have a pull fallback (`pendingPull`); job-owner withdrawals do not. A job registered from a contract that later rejects ETH (or a lost/reverted receiver) makes the escrow unwithdrawable. Given the executor precedent, a `pendingPull`-style fallback for owners would be consistent; alternatively document the constraint in SKILL.md (integrators register from EOAs or ETH-accepting contracts today).

### F-7 [Informational] — Trusted-executor assumption is load-bearing for non-idempotent targets

Nothing on-chain checks `checkJob()` before dispatch (by design — SPEC-3, off-chain gating). A compromised or malicious `authorizedExecutor` can call `executeJob` with arbitrary payloads at will; RULE-12 *requires* client targets to be idempotent so repeated pokes are harmless, but the escrow still pays `gasUsed·gasPrice + tip` per call — a rogue executor can grind any job's escrow down to the deactivation threshold with no client recourse beyond `withdrawGas`/`setJobStatus(false)`. This is exactly the Q-5 permissioned design (nonce/MEV-contention avoidance), and SEC-10 correctly notes searchers *cannot* front-run the refund. Recorded as a centralization note: executor key compromise = liveness + bounded economic loss, not principal loss; the hot-wallet cap (3–5 AVAX) and SEC-12 breaker remain the operative mitigations.

### F-8 [Informational] — Specification/documentation hygiene

1. `spec.md` SPEC-7 still lists owner-callable `setPremiumBps` — removed by DIV-D-3; the contract correctly has none.
2. RULE-1's letter ("updates ALL internal state BEFORE the external call") conflicts with SPEC-5.3-4, which (necessarily, for gas measurement) deducts escrow *after* the target call. The implementation is safe because every re-entrable value-touching path is guarded — but F-1 shows precisely where that reasoning had a hole. Recommend a doc note reconciling the two rules.
3. `PeekRegistry.sol:10` natspec still says "streams a bounded premium to the protocol treasury" — stale post-DIV-D-3 (flat tip).
4. The handoff `evidence/` folder is empty (README promises `coverage.txt`, `test-results.txt`, `deploy-addresses.md`). All claims were independently re-verified for this audit, but the package should ship its evidence.
5. `CoveragePool.MIN_TERM_DAYS` is declared but unused (the `msg.value < price` check enforces the same thing).
6. Theoretical only: `CoveragePool.totalFunded` cumulative `uint128` could overflow after ~3.4e38 wei of lifetime sponsorship (checked arithmetic → `sponsor` would brick for that chain); force-fed ETH (selfdestruct) can also break the registry's balance-vs-accounting equality — accepted class, no exploit.

---

## 4. Positive confirmations (attacks attempted, no finding)

| Area | Confirmation |
|------|--------------|
| Reentrancy | `executeJob`/`withdrawGas`/`pull` are `nonReentrant` (OZ v5.7); attacker-frame reverts wholesale; existing tests (`ReentrancyNeutralized` ×3, `ReentrantWithdrawer`) plus review of the unguarded mutators (`registerJob`, `depositGas`, `setJobStatus` — additive-only, modulo F-1) |
| Checks-effects-interactions | `withdrawGas` and `pull` decrement before transfer and revert-roll back cleanly; `sponsor` writes the term before the treasury transfer and rolls back on transfer failure |
| Solvency precheck | `(gasLimit + 2·OVERHEAD_BUFFER)·tx.gasprice + keeperTip` in uint256 — matches DIV-D-2/D-3 and RULE-3; registration minimum uses the same formula (anti-spam) |
| Pricing | Successful execution charges exactly `gasUsed·tx.gasprice + keeperTip` (verified in existing tests and by balance deltas in the PoCs); `transfer()`/`send()` absent from all payout paths (RULE-5); executor refund failure degrades to `pendingPull`; treasury failure reverts conservatively |
| Access control | Every mutator gated: `onlyOwner` setters, executor gate first in `executeJob`, job-owner gates on `withdrawGas`/`setJobStatus`; default-deny (RULE-2). Zero-address checks on treasury/executor/target; `Ownable` rejects zero owner at construction |
| Arithmetic | All multiplications uint256; narrowing casts (`uint128` escrow, `uint8` revert counter ≤ `MAX_REVERT_LIMIT` ≤ 10) are prior-bounded (RULE-6); escrow overflow paths tested (`EscrowOverflow`, `InsufficientDeposit` in pool) |
| Gas griefing | Target stipend exactly `job.gasLimit`; OOG inner call counts as revert (tested); returndata never copied/decoded (SEC-03 holds — the `(bool ok, )` pattern discards it) |
| Job packing | Exactly 2 slots, zero padding, escrow outside the struct — proven by `vm.load` probes (`Packing.t.sol`), matching SPEC-4/RULE-7 |
| CoveragePool | Zero custody (revenue-on-receipt, balance always 0 — tested); forward-only expiry extension from `max(current expiry, now)` (tested); `covered()` strict `>` is fail-closed; no refund surface ⇒ no refund griefing; `uint64` expiry arithmetic comfortably in range (≤365 d/call) |
| Pause semantics | `paused` blocks `registerJob`/`executeJob` but leaves `withdrawGas`/`pull` open — users can always exit during a pause |
| MEV / front-running | Executor-only refund destination; no capturable protocol reward inside the tx (SEC-10 holds) |
| Events | Every state transition the worker depends on emits (superset of SPEC-6's list, incl. `TargetReverted`, `JobStatusSet`, `MaxRevertsSet`) |

---

## 5. SPEC / RULE conformance matrix

| Rule | Status | Notes |
|------|--------|-------|
| RULE-1 C-E-I | ⚠️ | Holds on all payout paths; F-1 is the exception class (stale write-back after interaction) |
| RULE-2 default-deny | ✅ | |
| RULE-3 solvency precondition | ✅ | Formula exact; bound itself has the F-2 payload caveat |
| RULE-4 failed/success charging | ✅/⚠️ | Soft-exit semantics per DIV-D-1, exact charge per DIV-D-3; F-2's branch lets a *successful* target execution charge nobody (executor loss) |
| RULE-5 no transfer()/send() | ✅ | |
| RULE-6 uint256 math | ✅ | |
| RULE-7 struct packing | ✅ | Test-proven |
| RULE-8 events | ✅ | |
| RULE-9 custom errors | ✅ | |
| RULE-11 bounds | ✅ | gasLimit ≤ 2.5M, ceiling ≥ 25 gwei, tip ≤ 0.05, reverts ≤ 10 |
| SPEC-5 executeJob ordering | ✅ | Matches spec incl. gasInitial first-line capture |
| SPEC-6 registration | ✅ | |
| SPEC-7 access | ⚠️ | Spec text still lists `setPremiumBps` (F-8.1) |
| SPEC-11 acceptance | ✅ | Coverage ≥95% ✅, invariant campaign green, conservation invariant — see F-1 for the uncovered re-entrancy corner |
| DIV-D-1/2/3 rulings | ✅ | Implemented as ruled |

---

## 6. Test-quality assessment

Strong overall: 75 tests, genuine adversarial fixtures (`AttackerJob`, `ReentrantWithdrawer`, `ToggledExecutor`), event-derived ghost accounting in the invariant handler, packing proof by storage probing, coverage verified. Gaps found by this audit:

1. No fuzz/corpus case where the target re-enters `depositGas` during `performJob` (would have caught F-1 and INV-1's blind spot — the invariant only checks handler-known jobs against balance, and a self-deposit from a *funded target* breaks it in a way `sumEscrows()` never sees).
2. No large-`execPayload` case (would have caught F-2; the invariant handler only ever passes an 8-byte payload).
3. `Handler.executeJob` bounds gas price to 1–24 gwei and ceilings to ≥25, so `GasPriceExceedsJobCeiling` is unit-tested but never fuzz-exercised — acceptable, noted for completeness.

The two PoC tests accompanying this report (staged in the audit sandbox, not the repo) can be upstreamed as regression tests alongside the F-1/F-2 fixes.

---

## 7. Recommended remediation order

1. **F-1** (one-line fix + regression test) — protects the flagship conservation invariant.
2. **F-2** (payload length bound or explicit bound-documentation) — must be resolved *before* any move toward permissionless executors.
3. **F-4** (buffer upper bound) and **F-5** (script assert) — cheap hardening in the same PR.
4. **F-8** doc hygiene + ship the empty `evidence/` folder.
5. Mainnet gate: confirm `OVERHEAD_BUFFER=50000` and Safe ownership per `fuji-golive.md` (F-3).

With F-1 and F-2 remediated (or F-2 formally accepted under the worker gas-cap mitigation), the contract layer is **ready for Avalanche C-Chain mainnet deployment** from this auditor's perspective.

---

## Appendix — Verification commands and PoC sources

Commands run (in an out-of-repo sandbox copy of `../peekpeak/contracts`, libs symlinked):

```
forge build                                   # clean
forge test                                    # 75/75 passed (+2 PoC = 77/77)
forge coverage --report summary               # figures in §2
diff -r PeekPeak-audit/contracts peekpeak/contracts   # sources byte-identical
```

### PoC test contract (`AuditPoC.t.sol`, passing 2/2)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PeekRegistry} from "../src/PeekRegistry.sol";

/// F-1: target tops up its own escrow DURING performJob; the registry's
/// success path writes the STALE pre-call escrow snapshot back, erasing
/// the mid-call deposit (conservation invariant broken).
contract SelfDepositingJob {
    PeekRegistry public registry;
    bytes32 public ownJobId;
    uint256 public performCount;

    constructor(PeekRegistry r) payable { registry = r; }

    function setJobId(bytes32 id) external { ownJobId = id; }

    function checkJob() external view returns (bool, bytes memory) { return (true, ""); }

    function performJob(bytes calldata) external {
        performCount += 1;
        registry.depositGas{value: 0.5 ether}(ownJobId); // mid-execution top-up
    }

    receive() external payable {}
}

/// F-2: minimal target; a very large execPayload makes the measured gasUsed
/// (calldata->memory copy inside executeJob) exceed the prechecked bound, so
/// the "provably unreachable" defensive shortfall branch fires AFTER the
/// target already executed: free execution, executor eats the gas.
contract CheapJob {
    uint256 public performCount;

    function checkJob() external view returns (bool, bytes memory) { return (true, ""); }

    function performJob(bytes calldata) external { performCount += 1; }
}

contract AuditPoCTest is Test {
    uint32 internal constant BUFFER = 35_000;
    uint256 internal constant GAS_PRICE = 25 gwei;

    PeekRegistry internal registry;
    address internal owner = makeAddr("owner");
    address payable internal treasury = payable(makeAddr("treasury"));
    address internal executor = makeAddr("executor");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.prank(owner);
        registry = new PeekRegistry(owner, treasury, BUFFER, 0);
        vm.prank(owner);
        registry.setExecutor(executor, true);
        vm.deal(alice, 10 ether);
        vm.txGasPrice(GAS_PRICE);
    }

    function _worstCase(uint32 gasLimit) internal view returns (uint256) {
        return (uint256(gasLimit) + 2 * uint256(BUFFER)) * GAS_PRICE + registry.keeperTip();
    }

    /// PoC 1: mid-call depositGas is erased by the stale-escrow write-back.
    function test_PoC_StaleEscrowOverwriteErasesMidCallDeposit() public {
        SelfDepositingJob target = new SelfDepositingJob(registry);
        vm.deal(address(target), 1 ether);

        bytes32 jobId = keccak256(abi.encode(address(target), alice, registry.jobNonce()));
        vm.prank(alice);
        registry.registerJob{value: 1 ether}(address(target), 500_000, 100);
        target.setJobId(jobId);

        assertEq(address(registry).balance, 1 ether);

        vm.prank(executor);
        registry.executeJob(jobId, "");

        assertEq(target.performCount(), 1);
        uint256 payouts = executor.balance + treasury.balance; // baseCost + tip
        assertEq(address(registry).balance + payouts, 1.5 ether); // deposit physically received

        uint256 escrowAfter = registry.escrows(jobId);
        uint256 accounted = escrowAfter + registry.pendingPull(executor);

        // CONSERVATION BROKEN: registry holds 0.5 ether more than it accounts
        // for; the deposit is unrecoverable (withdrawGas only reaches the
        // mapped value).
        assertEq(
            address(registry).balance - accounted,
            0.5 ether,
            "unaccounted wei: mid-call deposit erased by stale-escrow write-back"
        );

        uint256 baseCost = executor.balance;
        uint256 tip = treasury.balance;
        assertEq(1 ether - escrowAfter, baseCost + tip);
    }

    /// PoC 2: oversized execPayload pushes measured gasUsed past the
    /// solvency bound; the "unreachable" defensive branch fires after the
    /// target already executed (free execution, executor eats the gas).
    function test_PoC_LargePayloadReachesDefensiveShortfallBranch() public {
        CheapJob target = new CheapJob();

        uint32 gasLimit = 60_000;
        uint256 required = _worstCase(gasLimit);
        bytes32 jobId = keccak256(abi.encode(address(target), alice, registry.jobNonce()));
        vm.prank(alice);
        registry.registerJob{value: required}(address(target), gasLimit, 100);

        bytes memory payload = new bytes(200_000);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = 0x01;
        }

        vm.prank(executor);
        registry.executeJob(jobId, payload);

        assertEq(target.performCount(), 1, "target executed");
        assertEq(registry.escrows(jobId), required, "client not charged");
        assertEq(executor.balance, 0, "executor not reimbursed");
        assertEq(treasury.balance, 0, "treasury got no tip");
        (,, bool isActive,,,) = _job(jobId);
        assertFalse(isActive, "job deactivated via 'unreachable' branch");
    }

    function _job(bytes32 jobId)
        internal
        view
        returns (address, uint32, bool, uint8, address, uint64)
    {
        return registry.jobs(jobId);
    }
}
```
