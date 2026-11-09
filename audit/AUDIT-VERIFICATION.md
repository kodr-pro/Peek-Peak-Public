# PeekPeak Audit — Verification of Changes & Mainnet Sign-Off

**Companion to:** [`AUDIT-REPORT.md`](AUDIT-REPORT.md) (original audit, 2026-09-25 — left intact; its `contracts/` snapshot is frozen at the pre-fix state so its line references remain valid)
**Subject:** Remediation of findings F-1..F-8 applied to the `peekpeak` monorepo
**Date:** 2026-09-25
**Verdict:** **SIGN-OFF GRANTED** — cleared for Avalanche C-Chain mainnet deployment from the remediated source, subject to the deploy-gate conditions in §5.

---

## 1. Change manifest

All changes are in the `peekpeak` monorepo (working tree vs `7f9a257`; 7 files changed + 1 new test file, +92/−15). The audit-package `contracts/` snapshot is deliberately **not** synced — it is the historical record the original report cites.

| Finding | File(s) | Change |
|---------|---------|--------|
| **F-1** stale-escrow write-back | `contracts/src/PeekRegistry.sol` (`executeJob` success path) | The defensive shortfall check and the deduction now read the **current** `escrows[jobId]` after the target call (`currentEscrow`) instead of writing back the pre-call snapshot. Concurrent `depositGas` re-entry credits survive; conservation invariant restored. The pre-call local `escrow` remains in use only for the pre-dispatch solvency check, where no re-entrancy window has opened yet. |
| **F-2** unbounded payload gas | `contracts/src/PeekRegistry.sol` + ground-truth docs | New `MAX_EXEC_PAYLOAD = 4_096` constant + `PayloadTooLarge()` error + check in the `executeJob` checks block (before solvency/dispatch). Recorded as **DIV-D-4** in the divergence register; RULE-11 and SPEC-5.2 amended. |
| **F-3** Fuji under-reimbursement | none (accepted risk) | No code change; deploy-gate condition §5.3 pins `OVERHEAD_BUFFER=50000` for mainnet (deploy-script default already 50,000, `PeekPeak.s.sol:13`). |
| **F-4** unbounded constructor buffer | `contracts/src/PeekRegistry.sol` | `MAX_OVERHEAD_BUFFER = 500_000` (10× calibration); constructor enforces `MIN ≤ buffer ≤ MAX`. Recorded as **DIV-D-5**. |
| **F-5** CREATE2 tip assert | `contracts/script/DeployRegistry.s.sol` | Assert now compares against the **effective** expected tip (`initialTip == 0 ? DEFAULT_KEEPER_TIP : initialTip`) so custom-`KEEPER_TIP_WEI` deploys no longer abort after broadcasting. |
| **F-6** push-only withdrawals | docs (rationale below) | Documented in `withdrawGas` natspec + `agents/SKILL.md` rule 8. **Not coded, deliberately:** a pull fallback would transfer via the same `call` to the same wallet — a wallet that can *never* receive ETH strands funds identically in `pendingPull`, while a *transiently* failing wallet is already served by the revert-and-retry semantics (escrow stays in place). The fallback would be security theater; the honest fix is the integrator constraint. |
| **F-7** trusted-executor assumption | docs | Trust model documented on `executeJob` natspec + `agents/SKILL.md` rule 10 (exposure bounded by executor honesty; idempotent targets + `setJobStatus`/`withdrawGas` recourse; hot-wallet cap + SEC-12 breaker remain operative). This is the ruled Q-5 permissioned design — no code change. |
| **F-8** spec/doc hygiene | `docs/ground-truth/{spec,review-rules,divergence-register}.md` (monorepo + audit-package mirrors), `PeekRegistry.sol` natspec, `CoveragePool.sol` | (1) SPEC-7 now lists the real setter set (`setKeeperTip`, no `setPremiumBps`); (2) RULE-1 gained the reconciliation note for SPEC-5's measurement-forced post-call accounting incl. the F-1 stale-write-back class; (3) stale "bounded premium" natspec fixed; (4) `evidence/` populated (fresh post-fix outputs + deployment addresses); (5) unused `MIN_TERM_DAYS` removed (undeclared-ABI-safe: CoveragePool not deployed anywhere); (6) theoretical `totalFunded` overflow / force-feed documented as accepted (no code change). |

### F-2 bound justification (why 4,096 is provably safe)

The solvency invariant needs `head + payloadCopy + targetGas ≤ gasLimit + OVERHEAD_BUFFER` in the worst case (target consuming its full stipend minus the success-RETURN ε). At 4 KB (128 words): memory expansion `3·128 + 128²/512 ≈ 416`, calldata→memory copy ≈ `3·128 = 384`, CALL-argument copy ≤ ~1k — total ≈ **2.3k gas**, against a `MIN_OVERHEAD_BUFFER` slack of 10,000 (and head checks ≈ 4k, all inside the buffer allowance for every legal buffer 10k..500k). The bound now holds **on-chain**, independent of the worker's broadcast gas cap, which was the root defect of F-2.

---

## 2. Verification performed (all on the remediated monorepo tree)

| Check | Command | Result |
|-------|---------|--------|
| Compile | `forge build` (solc 0.8.37) | ✅ clean |
| Full suite | `forge test` | ✅ **81/81** (75 original untouched + 6 new regression tests) |
| Invariant campaign (deep) | `FOUNDRY_PROFILE=fuzz forge test --match-contract PeekRegistryInvariantTest` | ✅ 4/4 invariants, 2048 runs × 128 depth (~262k handler calls, 0 failures) |
| Coverage | `forge coverage --report summary` | ✅ PeekRegistry **97.39% lines / 96.69% stmts / 91.67% branches**, CoveragePool 100% lines / 89.19% stmts, PharaohEpochKeeper 100% — no regression vs the audited baseline (97.32/96.58/91.43) |
| Original tests unchanged | diff of `test/` | ✅ only the new `AuditRegressions.t.sol` added; all 75 pre-existing tests byte-identical and green |
| Dependency pinning | `foundry.lock` | ✅ OZ v5.7.0 (`cab1993`), forge-std v1.16.2 — unchanged |

### Regression test mapping (`contracts/test/AuditRegressions.t.sol`)

| Test | Proves | Fails on pre-fix code? |
|------|--------|------------------------|
| `test_F1_MidCallDepositSurvivesExecution` | Mid-`performJob` `depositGas` of 0.5 AVAX survives; `registry.balance == Σescrows + pendingPull` **exactly**; deduction taken from the 1.5 AVAX current escrow | ✅ yes — pre-fix, balance exceeded accounting by exactly 0.5 AVAX (original PoC 1) |
| `test_F2_OversizedPayloadRevertsPreDispatch` | The original 200 KB PoC payload now reverts `PayloadTooLarge` before dispatch: no execution, no charge, no deactivation | ✅ yes — pre-fix, the target executed free and the job deactivated via the "unreachable" branch (original PoC 2) |
| `test_F2_ExactlyOneByteOverCapReverts` | Boundary at `MAX_EXEC_PAYLOAD + 1` | n/a (new surface) |
| `test_F2_PayloadAtCapExecutesAndStaysSolvent` | 4 KB payload executes, charges within the prechecked bound, job stays active, executor reimbursed, exact tip paid — the bound is usable, not just safe | ✅ yes (60k gasLimit job would have been borderline pre-fix at this shape) |
| `test_F4_Constructor_Reverts_BufferAboveBound` / `..._AcceptsBoundaryBuffer` | Buffer bound enforced at 500,001 / accepted at 500,000 | n/a (new surface) |

The two original PoC exploits were re-verified conceptually against the fix: PoC-1's conservation break now measures **zero** unaccounted wei; PoC-2's soft-exit path is unreachable (reverts upfront).

---

## 3. Residual risk register (accepted items)

| Item | Rationale for acceptance |
|------|--------------------------|
| Fuji registry (`0xad76...4664`) runs pre-fix code | Immutable contract; both on-chain findings are Low, testnet-only, and require a malicious/buggy target (F-2 additionally costs only the operator's own executor). Remediated code ships in the mainnet deployment; versioned redeploy on Fuji optional. |
| F-3 executor under-reimbursement on Fuji (35k vs 44,870 measured) | Known, quantified (~10k gas/execution), testnet-only; mainnet gate §5.3 pins 50,000. |
| F-6 wallet-rejects-ETH stranding | Inherent to push semantics; documented integrator constraint (a pull fallback demonstrably cannot help the pathological case). |
| F-7 executor trust | Ruled design (Q-5); exposure bounded (fees only, deactivation threshold), mitigated by hot-wallet cap, SEC-12 breaker, idempotency contract (RULE-12), and client kill-switches. |
| `CoveragePool.totalFunded` uint128 lifetime overflow; force-fed ETH | Astronomically impractical / accepted class; checked arithmetic fails loud; no principal at risk (pool holds no custody). |
| `gas-anomaly` coreth `gasLimit/2` floor | Worker-side mitigation shipped (estimate-hugging gas limits); unrelated to contract code. |

---

## 4. Spec conformance re-check (post-fix)

- SPEC-5.2 checks now include the payload bound → matches implementation (DIV-D-4).
- SPEC-5.8 deduction semantics ("against the CURRENT mapping value") → matches implementation.
- SPEC-7 setter list → matches implementation (`setKeeperTip` bounded, no premium).
- RULE-1 ↔ SPEC-5 tension → reconciled in RULE-1 text; implementation satisfies the amended rule (all post-call write-backs read current storage).
- RULE-11 bounds → all six bounds enforced at registration/dispatch/construction.
- Divergence register: DIV-D-1..D-3 (original rulings) + DIV-D-4/D-5 (audit remediations) — all RULED, none open.
- Storage layout unchanged: the fixes add **no storage variables** (constants and one error only) — `Job` packing proof (RULE-7) and all storage slots are unaffected; the invariant campaign and `Packing.t.sol` confirm.

---

## 5. Mainnet sign-off

### Verdict

**APPROVED for Avalanche C-Chain mainnet deployment** of `PeekRegistry` and (when the L1 rollout ships) `CoveragePool`, built from the remediated source tree (post-`7f9a257` working tree containing the F-1..F-8 remediations). No Critical/High/Medium findings remain; both Low findings are fixed and regression-locked; all Informational items are either remediated or formally accepted in §3.

### Deploy-gate conditions (must hold at deployment time)

1. **Source:** deploy exactly the remediated commit (or later, re-verified); do **not** reuse the Fuji bytecode.
2. **Ownership:** `OWNER` = Safe `0x23c74e033C1FB94A87c6A495bF8b741521aA9953` (per `fuji-golive.md`; never a personal EOA), `TREASURY` = same Safe. Move to 2-of-3 before mainnet liquidity (SEC-16).
3. **Calibration:** `OVERHEAD_BUFFER=50000` (deploy default; overrides nothing — do not pass 35000), `KEEPER_TIP_WEI` as decided (0 → 0.005 AVAX default).
4. **Executor:** fresh keystore (never `PP_TEST_EXECUTOR_KEY`), hot wallet capped ≤ 5 AVAX, SEC-12 breaker floor configured.
5. **Post-deploy smoke test:** re-run the SPEC-11 acceptance sequence on mainnet with a `MockJob` (5 executions, exact tip, conservation via the dashboard) before opening registration to integrators.
6. **Watch items (first weeks):** compare `JobExecuted.gasUsed` vs receipts to validate the 50,000 buffer (Q-6 follow-up); monitor `PayloadTooLarge` reverts for any legitimate integrator hitting the 4 KB cap (raise DIV-D-4 bound only via a new ruled divergence + redeploy).

### Sign-off summary

| Dimension | Status |
|-----------|--------|
| Findings F-1..F-8 disposition | 2 fixed + regression-locked (F-1, F-2); 1 script fix (F-5); 1 hardening (F-4); 4 documented/accepted (F-3, F-6, F-7, F-8) |
| Test evidence | 81/81 unit + 4/4 invariants @2048×128 fuzz profile |
| Coverage | ≥ 97.3% lines on both primaries — no regression |
| Ground truth | spec/rules/divergence updated and consistent with implementation |
| Supply chain | OZ v5.7.0 + forge-std v1.16.2, pinned, official tags |

---

*Evidence: [`evidence/test-results.txt`](evidence/test-results.txt), [`evidence/coverage.txt`](evidence/coverage.txt), [`evidence/deploy-addresses.md`](evidence/deploy-addresses.md). Change diff: `git diff 7f9a257` in the `peekpeak` monorepo (7 files + 1 test file, +92/−15).*

---

## 6. Mainnet deployment record (2026-11-09)

Deployment of the audited code to Avalanche C-Chain (43114), executed by
the repo owner after the HACVSP release-gate cadence completed on the
audit-alignment lineage.

### 6.1 Pipeline lineage (deploy-gate condition §5.1)

The deployed source is `peekpeak` `main` @ `0a2ab28` ("Merge PR #16 from
kodr-pro/audit/hacvsp-alignment"), containing the full audit-alignment
corpus. HACVSP engagement `peekpeak` gate ledger: **stages 1–14 all GO**
(release cadence: access-matrix, mutation ≥90% kill, stateful fuzz,
SMT/Halmos BMC, Kontrol EVM proofs, expert threat-model review stage 13,
cryptographic attestation stage 14), recorded 2026-11-05..07 at commits
`1eacfd0`→`c8ed234` (engagement-pinned hashes). Note: those commits were
rebased (author-email normalization) immediately before merge — content
identical, merged hashes differ (e.g. `c8ed234` → `59dfd0b`); the ledger's
content verdicts carry. Build settings pinned by that lineage:
**solc 0.8.38, EVM prague, via-ir, optimizer 200 runs, ipfs metadata.**

### 6.2 Deployed registry (FINAL, of record)

| Item | Value | Verification |
|------|-------|--------------|
| Registry | `0x5d873059A9Dca265043728862Cf5a5e01741B0f3` | — |
| Deploy tx | `0xe94239ecb1901cf0c33cf9b612166225d2c302b7964049604ccb0178dc33c659` | block `99881520` |
| owner / treasury | Safe `0x23c74e033C1FB94A87c6A495bF8b741521aA9953` | ✅ read on-chain 2026-11-09 |
| keeperTip | `5000000000000000` (0.005 AVAX) | ✅ read on-chain |
| OVERHEAD_BUFFER | `50000` | ✅ read on-chain |
| paused | `false` | ✅ read on-chain |
| Executor authorized | `0xB52cd91826d33E69Ee7985eA3e422896963641a3` → `true` | ✅ read on-chain (Safe 2-of-3 tx) |
| Compiler (deployed artifact) | **solc 0.8.38** | ✅ proven from the CBOR metadata tail embedded in on-chain runtime code (`...736f6c63430008260033`) |
| Codegen profile | **via-ir + optimizer 200** | ✅ length fingerprint: 5,237-byte runtime matches only that profile (8 other settings permutations produce 5.2k–14k bytes, none equal) |
| Artifact identity vs hermetic stage-2 build | ⚠️ **not bit-for-bit** | see §6.4 |

Constructor args were also verified from the deploy tx calldata
(`(Safe, Safe, 50000, 5e15)`) and the `OwnershipTransferred(0 → Safe)`
event at the deploy block.

### 6.3 Voided / superseded deployments

| Address | Status | Reason |
|---------|--------|--------|
| `0x43Db684b8fb6903e2b954fB003FB029a402322D0` | **VOID** (2026-11-09) | Deployed through Remix with solc **0.8.34** (proven from CBOR tail) — not the audited build family. Executor was authorized in error and **must be revoked** (`setExecutor(executor,false)`) and the contract paused (`setPaused(true)`) by the Safe. No escrow, no jobs — zero value at risk. |
| `0xb012fe01cd851c454bd5c7d20c3e3e3f98b4643d` | superseded | 2026-10-22 registry (solc 0.8.37, pre-audit-alignment source: lacks the stage-4 event-indexing fix `6746b7e` and outcome-flag init `5d2cc5c`). Three SPEC-11 soak executions paid exact tips; dry-run escrow owner-withdrawable. Optional hygiene: pause via Safe. |

### 6.4 Artifact identity — recorded limitation and owner ruling

The deployed runtime code is **not byte-identical** to the engagement's
hermetic stage-2 artifact: 2,308 of 5,237 bytes differ (2,308 bytes across
the code body; metadata hash differs as well). Attribution: the deployment
was compiled in Remix IDE from the repository's `contracts/` sources, whose
source-unit layout/import resolution differs from the foundry build, and
via-ir codegen legitimately reorders on source layout. Compiler version
and codegen profile are proven identical (§6.2); **source equivalence is
attested by the deployer/owner** (first-party audit; the loaded Remix file
set was the repo's `contracts/` folder). The owner has ruled the
deployment acceptable on that basis.

Recorded as an **accepted residual risk** in the same register style as §3:
the stage-2 bit-for-bit guarantee holds for the pipeline's own artifact;
the on-chain artifact's equivalence rests on the §6.2 fingerprint plus the
owner's source attestation rather than on a byte-level proof. Snowtrace
verification of the deployed address (flattened source, 0.8.38 / prague /
200 / viaIR) narrows the gap publicly and is listed as a follow-up below.

### 6.5 Deploy-gate conditions (§5) — final status

1. **Source:** deployed from `main` @ `0a2ab28` (audit-alignment lineage,
   14/14 gates GO) — ✅ with the §6.4 artifact-identity limitation recorded.
2. **Ownership:** owner = treasury = the 2-of-3 Safe — ✅ verified on-chain.
3. **Calibration:** buffer 50,000, tip 5e15 — ✅ verified on-chain.
4. **Executor:** production keystore (unchanged since 2026-10-22 provisioning),
   authorized on the final registry — ✅ verified on-chain.
5. **Post-deploy smoke test (SPEC-11):** ⏳ **PENDING** — run the 5-execution
   dry-run against the final registry before opening registration to integrators.
6. **Watch items:** ⏳ open — buffer-vs-receipt comparison (Q-6) and
   `PayloadTooLarge` monitoring, from the first week of live executions.

### 6.6 Follow-ups (open at time of record)

- [ ] Revoke executor + pause on VOID `0x43Db...22D0` (Safe batch).
- [ ] Optional: pause superseded `0xb012fe...643d`.
- [ ] Snowtrace Verify & Publish for `0x5d87...B0f3` (0.8.38/prague/200/viaIR).
- [ ] SPEC-11 soak (§6.5.5), then open registration.
- [ ] Repo wiring PR: `deploy/chains/mainnet.json` + `frontend/lib/chains.ts`
  repointed at `0x5d87...` / block `99881520`; Railway watcher redeploys
  against the fresh registry (empty registry → idle-park mode engages).

*Recorded 2026-11-09 by the deployment-verification pass; on-chain reads
via public Avalanche RPC (api.avax.network, publicnode) and deploy-tx
calldata/metadata-tail analysis. Pre-image artifacts retained at
`evidence/`.*
