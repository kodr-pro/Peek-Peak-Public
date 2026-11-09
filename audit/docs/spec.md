# PeekPeak Protocol Specification (Ground Truth)

> Normative source of truth for the PeekPeak autonomous execution protocol.
> Peek the state. Poke the peak. - Zero-overhead autonomous keeper engine native to Avalanche.
> This document governs all implementation decisions. Contract: Fuji first, then Avalanche mainnet + L1s.

## SPEC-1 Mission

PeekPeak is a zero-token-tax autonomous smart contract execution protocol for Avalanche
C-Chain and Subnet-EVM L1s. No governance token, no protocol token, no subscriptions.
Target contracts implement a 2-method interface (`IAutoJob`). Escrows and reimbursements
settle 100% in native coin. Executors are reimbursed exact gas plus a flat keeper tip (default 0.005 AVAX, DIV-D-3) to treasury; only successful executions charge.

## SPEC-2 Decision Record (binding)

- D1: Off-chain worker is Rust (alloy + tokio), single binary `peekpeakd` with roles.
- D2: `PeekRegistry` is immutable + versioned (NOT upgradeable). Tunables
  (`keeperTip` bounded by MAX_KEEPER_TIP, `treasury`, `authorizedExecutors`, `paused`) remain owner-settable.
  Uses OpenZeppelin `Ownable` (or `Ownable2Step`) + non-upgradeable `ReentrancyGuard`.
- D3: Treasury is a Safe multisig (cold). Executor is a dedicated EOA hot wallet capped
  at 3-5 AVAX. Only Node B (signer role) ever broadcasts transactions.
- D4: Monorepo in github.com/kodr-pro/PeekPeak (private). Website on Vercel at
  peekpeak.app, Root Directory `frontend/` (imported at Phase 4).
- D5: `escrowBalance` lives in a separate mapping, NOT inside the `Job` struct.

## SPEC-3 Target Interface (`IAutoJob`)

```solidity
interface IAutoJob {
    function checkJob() external view returns (bool canExec, bytes memory execPayload);
    function performJob(bytes calldata execPayload) external;
}
```

- `checkJob` is evaluated off-chain via static `eth_call` on every new block. It MUST
  NOT mutate state and MUST return `true` only when `performJob` is ready.
- `performJob` MUST be access-restricted by the client so only the registry can call it,
  and MUST mutate state so `checkJob()` returns `false` on the next block.

## SPEC-4 Registry Storage Layout

```solidity
struct Job {
    address target;        // slot A: bytes 0..19
    uint32  gasLimit;      // slot A: bytes 20..23
    bool    isActive;      // slot A: byte 24
    uint8   consecutiveReverts; // slot A: byte 25
    address owner;         // slot B: bytes 0..19
    uint64  maxGasPriceGwei; // slot B: bytes 20..27
}
mapping(bytes32 => Job) public jobs;
mapping(bytes32 => uint128) public escrows;   // SPEC-2 D5
mapping(address => bool) public authorizedExecutors;
address payable public treasury;
uint128 public keeperTip;     // default 0.005 ether (DIV-D-3), bounded by 0.05 ether
uint256 public jobNonce;       // job id salt
uint32  public maxConsecutiveReverts; // default 3
bool public paused;            // global circuit breaker (owner-settable)
```

- The `Job` struct MUST occupy exactly 2 storage slots (verifiable via `vm.load`).
- `jobId = keccak256(abi.encode(target, owner, jobNonce))` - multiple jobs per target
  are allowed (required by Pharaoh CL vaults).

## SPEC-5 Economic Invariants (executeJob)

Ordered checks-effects-interactions inside `nonReentrant`:

1. `gasInitial = gasleft()` captured at first line of `executeJob`.
2. Checks: job exists + active; executor authorized; not paused;
   `tx.gasprice <= job.maxGasPriceGwei` (revert `GasPriceExceedsJobCeiling`);
   `execPayload.length <= MAX_EXEC_PAYLOAD` = 4096 (revert `PayloadTooLarge`,
   DIV-D-4);
   solvency in uint256: `required = (gasLimit + 2*OVERHEAD_BUFFER) * tx.gasprice + keeperTip`
   with `escrows[jobId] >= required` (else soft-exit: deactivate + `JobDeactivated`,
   no charges). The `2*OVERHEAD_BUFFER` term bounds the measured
   `gasUsed = head checks + target consumption + OVERHEAD_BUFFER` from above.
3. Effects BEFORE interaction: deduct nothing yet, but mark accounting after call.
4. Interaction: `(bool ok, ) = job.target.call{gas: job.gasLimit}(execPayload)`.
   If `!ok`: increment `consecutiveReverts`; when it reaches `maxConsecutiveReverts`,
   deactivate + `JobDeactivated`. The registry transaction SUCCEEDS (soft-exit,
   DIV-D-1) so the counter persists; the client is never charged and the executor
   is never reimbursed for failed work. Off-chain `eth_estimateGas` pre-simulation
   is the first line of defense.
5. Measurement: `gasUsed = (gasInitial - gasleft()) + OVERHEAD_BUFFER`.
   `OVERHEAD_BUFFER` is an immutable constructor constant calibrated by fork tests
   (expected 28,000-35,000 gas; covers signature check, escrow SSTORE, events, transfers).
6. `baseExecutionCost = gasUsed * tx.gasprice` (uint256).
7. `keeperTip` (flat, default 0.005 AVAX) is charged on top of exact gas.
8. `totalDeduction = baseExecutionCost + keeperTip`; require
   `escrows[jobId] >= totalDeduction` against the CURRENT mapping value (the
   unguarded `depositGas` may have credited the job mid-call - audit F-1);
   deduct; reset `consecutiveReverts = 0`.
9. Transfers: `executor.call{value: baseExecutionCost}("")` and
   `treasury.call{value: keeperTip}("")`, both checked; `transfer()` with its
   2300-gas stipend is FORBIDDEN (smart-wallet executors). A failed executor refund
   credits a `pendingPull[executor]` map (pull-over-push) and MUST NOT revert execution.
   A failed treasury send reverts (accounting must stay conservative).
10. Emit `JobExecuted(jobId, executor, gasUsed, baseExecutionCost, keeperTip)`.

## SPEC-6 Registration & Escrow Lifecycle

- `registerJob(target, gasLimit, maxGasPriceGwei)` payable: target non-zero, not zero-address
  owner; `gasLimit` bounded (<= 2,500,000); `maxGasPriceGwei >= 25`; `msg.value` MUST cover
  at least one solvency threshold (SPEC-5.2 formula at current tx.gasprice) - anti-spam.
- `depositGas(jobId)` payable adds to escrow. `withdrawGas(jobId, amount)` only by job owner.
- `setJobStatus(jobId, isActive)` only by job owner.
- Depleted jobs auto-deactivate and emit `JobDeactivated(jobId, reason)`.
- Events REQUIRED for off-chain indexing: `JobRegistered, JobDeactivated, JobExecuted,
  GasDeposited, GasWithdrawn, ExecutorSet, TreasurySet, KeeperTipSet, PausedSet,
  PullPending, PullWithdrawn`.

## SPEC-7 Access Control

- Owner: `setTreasury`, `setExecutor`, `setKeeperTip` (bounded 0..MAX_KEEPER_TIP,
  DIV-D-3), `setPaused`, `setMaxConsecutiveReverts`. Owner MUST be a Safe in
  production (SPEC-2 D3).
- Executor: only `authorizedExecutors` may call `executeJob`.
- Job owner (creator) only: `withdrawGas`, `setJobStatus`.
- Default-deny everywhere else.

## SPEC-8 PharaohEpochKeeper (reference adapter)

- `checkJob()` returns true when `block.timestamp >= nextEpochTimestamp`.
- `performJob` restricted to immutable `REGISTRY_ADDRESS`, advances `nextEpochTimestamp`
  BEFORE external calls (checks-effects-interactions), then calls `voter.distribute()`
  and/or `gauge.harvest()` per configuration. Must be idempotent within an epoch.

## SPEC-9 Off-Chain Worker (Rust)

- One binary, roles: `watcher` (Node A), `signer` (Node B), `standalone` (both, dev).
- Watcher: WS `newHeads` per chain; batch `checkJob` through Multicall3
  (`0xcA11bde05977b3631167028862bE2a173976CA11`); `eth_estimateGas` simulation of
  positives; mTLS-authenticated push of verified payloads to signer; 5s heartbeat.
- Signer: sole transaction broadcaster (nonce monopoly); encrypted keystore key (never
  env vars); EIP-1559 with `maxFeePerGas = min(job.maxGasPriceGwei, baseFee + tipCap)`;
  pending-nonce map with gap resync; on heartbeat loss > 30s runs its own fallback
  `eth_call` scan (failover must engage within 35s).
- Chain multiplexing: per-chain supervisor from `deploy/chains/*.json` (chainId, RPC,
  registry address); every job tagged with chainId; no cross-contamination.
- Secrets NEVER in the repo. `deploy/chains/*.json` holds public data only.

## SPEC-10 Frontend Platform (Phase 4, restyled per owner design brief)

Next.js in `frontend/` on Vercel (Root Directory `frontend/`). Hyper-minimal,
high-conversion developer platform:

- Brand: obsidian `#08080A` base, crimson `#E01A22` -> volt `#FF6600` gradient
  accents, Inter (UI) + JetBrains Mono (technical), Eye-of-Ra mark with emission.
- Home: two-column hero (text left; observatory radar right in a fixed-aspect
  container, never cover-sliced; live counters as large HTML stats fed from
  the registry), headline "CONTRACTS THAT RUN THEMSELVES.", CTAs to /start
  and /docs; how-it-works with real code; exact pricing cards (watching free,
  execution = gas + flat 0.005 AVAX tip, nothing else); assurances (escrow
  withdrawable, reverts cost zero, pause anytime, MIT, verified on explorer,
  independent audit before mainnet); three participation path cards.
- /start: dedicated onboarding funnel - prerequisites, live registry address
  with copy button + explorer link, Step 1 implement IAutoJob (copyable
  contract), Step 2 paste-runnable deploy + register commands (registry
  address prefilled), Step 3 trigger/top-up + calculator, agent path with
  SKILL.md download.
- Console (/dashboard): amber VALIDATION IN PROGRESS status band (adapts to
  live once a registry address is configured), job grid with FULL DEPLOYMENT
  QUEUED overlay pre-deployment, ghosted Add Fuji/C-Chain quick-starts,
  SKILL.md integration check, bounded-economics calculator (exact on-chain
  formula: gasUsed x gasPrice + flat keeper tip), live registry reads via viem once
  registry != null.
- Nav: START / DASHBOARD / DOCS (LOGIN/wallet removed by owner decision -
  no auth surface until the post-launch L1 signup/approval flow). Footer:
  TERMS / PRIVACY / SUPPORT / GITHUB with honest pre-mainnet placeholder
  legal pages.
- Layout system: one elastic shell (max-width 1680px, clamp side padding)
  shared by nav, hero, every section, and footer, so all content sits on the
  same vertical lines at any monitor width; widescreen real-estate
  maximized; mobile stacks with tightened nav/stats (owner directive
  2026-09-24).
- Copy invariants: pricing is ALWAYS described as exact gas reimbursement
  plus the flat keeper tip (default 0.005 AVAX, treasury-bound, successful
  executions only; static checks are free); never as a percentage premium and
  never as user revenue; L1 support claims carry the Subnet-EVM qualifier;
  pre-deployment telemetry is labeled STANDBY/SIM, never fabricated
  confirmations.

## SPEC-13 L1 Economics (multi-chain fee configurability)

1. `keeperTip` is a per-deployment storage variable denominated in each
   chain's NATIVE gas currency: constructor arg `initialKeeperTip`
   (0 = 0.005 ether default, <= 0.05 ether bound) plus owner `setKeeperTip`.
   Deploy scripts take `KEEPER_TIP_WEI`.
2. Tier 1 (zero-tip L1s): `keeperTip = 0` is valid; escrow still reimburses
   exact gas in the L1's own token (executor gas flywheel is self-sustaining).
3. Tier 2 (non-swappable tokens with a paying sponsor): `CoveragePool.sol` on
   C-Chain sells AVAX-denominated time terms per chainId (pricePerDay set by
   the treasury Safe; forward-only expiry extension; <= 365 days per deposit;
   funds route to treasury on receipt - the pool holds no custody). The
   worker's fail-closed gate reads `covered(chainId)` before serving that
   chain. Integrator escrows on the L1 are never encumbered.
4. Tier 3 (valued but unswapped tokens): optional ICTT/ICM tip repatriation -
   operational only; ICM never sits in the payment path (relayer liveness and
   Teleporter receiver surface rejected for the protocol core).
Full design + threat model: docs/l1-economics.md.
5. Security hardening: docs/security-checklist.md is the authoritative
   SEC-01..SEC-17 review (Fuji-readiness); fixes there (fee-bump watchdog,
   pre-send re-verification, balance breaker, liveness healthz, owner
   warnings) are normative for the daemon and runbooks.

## SPEC-11 Acceptance Criteria (Fuji gate)

- Foundry coverage >= 95% across registry paths.
- Invariant holds under fuzzing: `totalDeposited == sum(escrows) + treasury +
  executorReimbursements + withdrawals + pendingPull`.
- Reverting target: client never charged, executor never paid, tx reverts.
- Multi-L1 worker test: Fuji + Subnet-EVM local network concurrently, isolated.
- Failover: kill watcher, signer assumes simulation within 35 seconds.
- E2E: MockJob, 0.2 AVAX escrow, 5 sequential executions, exact 0.005 AVAX tip to treasury per execution.
- Pre-mainnet: fuzz clean (>= 1M runs), OVERHEAD_BUFFER calibration report, external
  audit recommended, Safe treasury + <= 5 AVAX hot wallet.

## SPEC-12 Corrections to Original Mission Brief (supersede it)

1. "Two 32-byte slots including escrowBalance" is impossible (69 bytes > 64); escrow
   moved to separate mapping (SPEC-2 D5).
2. `payable(...).transfer()` forbidden for refunds; checked `call{value}` + pull
   fallback (SPEC-5.9).
3. `gasleft()` deltas under-report due to the 63/64 rule and memory expansion;
   OVERHEAD_BUFFER must be calibrated via fork tests, not hardcoded (SPEC-5.5).
4. Perpetual-revert griefing mitigated by `consecutiveReverts` auto-deactivate (SPEC-4/5).
5. `jobId` derivation defined (SPEC-4).
6. Minimum deposit at registration required (SPEC-6).
7. Solvency arithmetic done in uint256 (SPEC-5.2).
