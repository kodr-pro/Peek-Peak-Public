# PeekPeak Security & Operational Hardening Checklist (Fuji-readiness)

Status: COMPLETE. Each item is either fixed in this hardening pass
("FIX") or already protected by design ("PROTECTED"), with the exact
mechanism, test, or rule cited. Normative rules: docs/ground-truth/review-rules.md.

## Phase 1: Smart Contract Layer (PeekRegistry.sol)

### SEC-01: Re-entrancy via external job call - PROTECTED
`executeJob`, `withdrawGas`, and `pull` are `nonReentrant`
(OpenZeppelin ReentrancyGuard); every escrow mutation happens BEFORE any
external call (checks-effects-interactions, RULE-1); refunds use checked
`call{value}` with a pull-payment fallback (RULE-5). The guard fires before
any state is touched, so a re-entering target frame reverts wholesale.
Tests: `test_ExecuteJob_ReentrancyNeutralized`, `...WithdrawReentryNeutralized`,
`...PullReentryNeutralized`, `test_WithdrawGas_ReentrantAttemptGetsNothing`.

### SEC-02: Target call gas griefing / OOG forcing - PROTECTED
The target receives exactly `job.gasLimit` via `.call{gas: job.gasLimit}`;
the outer tx carries `gasLimit + 150k` headroom (GAS_HEADROOM). A target
that loops forever self-terminates at its stipend; the registry's accounting
tail still runs (or the executor's own gas is the only loss). The measured
`gasUsed` is provably bounded by `gasLimit + 2*OVERHEAD_BUFFER` - asserted
by invariant INV-3 over 2048x128 fuzz. Tests: INV-3, unit bound asserts,
`test_ExecuteJob_GasLimitCapsTargetConsumption`.

### SEC-03: Return data bombing - PROTECTED
The registry never decodes or copies target returndata: the low-level call
discards it (`(bool ok, ) = target.call(...)`); only `ok` is read. There is
no `returndatasize`-driven copy, no `abi.decode` of untrusted data anywhere
in the registry. (The watcher decodes checkJob returns OFF-chain, where a
large payload costs one HTTP response, not gas.)

### SEC-04: Inner call revert absorption - PROTECTED
The low-level call captures failure; the registry transaction SUCCEEDS and
persists `consecutiveReverts` (+ auto-deactivation at the cap) so the client
is never charged and the executor is never reimbursed for failed work
(DIV-D-1, RULE-4). Tests: `test_ExecuteJob_RevertingTargetNeverChargesAnyone`,
`test_ExecuteJob_ConsecutiveRevertsDeactivateJob`.

### SEC-05: Pre-execution escrow solvency - PROTECTED
Dispatch requires `escrow >= (gasLimit + 2*OVERHEAD_BUFFER) * tx.gasprice +
keeperTip` computed in uint256 (RULE-3, DIV-D-2/3); the same formula sets
the registration minimum; a defensive fail-closed branch covers the
provably-unreachable shortfall. Tests: exact-minimum registration,
solvency soft-exit, invariant INV-1 (registry balance == escrows + pulls).

### SEC-06: Tip misconfiguration on non-18-decimal L1s - FIXED (bounded + coupled + documented)
`keeperTip` is hard-bounded (`MAX_KEEPER_TIP = 0.05 ether` of the chain's
base unit) at construction AND in `setKeeperTip`; the deploy script warns
and the runbook requires `KEEPER_TIP_WEI` expressed in the L1's OWN base
units (SPEC-13). Misconfiguration fails LOUD, not silent: the solvency
formula couples the tip into the registration minimum, so an absurd tip
makes jobs unregistrable rather than quietly overcharged, and the bound
caps the worst case. Tests: `test_Constructor_CustomNativeTip`,
`test_Constructor_Reverts_TipAboveBound`, `test_SetKeeperTip*`.

### SEC-07: Unbounded admin loops - PROTECTED (nothing to loop)
The registry contains zero arrays and zero loops: jobs live in a
`mapping(bytes32 => Job)`, `jobNonce` is a counter, all admin setters are
O(1). There is no enumeration entry point to gas-bomb.

## Phase 2: Worker Daemon & Off-Chain Runtime

### SEC-08: Stuck transaction / nonce-queue freeze - FIXED
`broadcast_and_confirm` (the daemon's send path) polls for a receipt after
every broadcast; after ~15s of silence it REPLACES the stuck transaction -
same nonce, fees x13/10, clamped to the job's gas ceiling, at most 2 bumps
- then reports and rolls the local nonce counter back if still unconfirmed.
Fees never exceed the job ceiling (RULE-14 preserved). Tests:
`sec08_fee_bumps_multiply_and_clamp_to_ceiling`,
`sec08_priority_never_exceeds_max_fee_after_bump`.

### SEC-09: Dual-execution collision - PROTECTED
One signer, one nonce counter: the signer role is the sole broadcaster
(SPEC-9 nonce monopoly; standalone mode is a single process). Duplicate
watchers cannot broadcast at all (only the signer holds the key), and the
registry accepts `executeJob` only from `authorizedExecutors`. For a
duplicated executor key (misconfiguration), the second tx either loses the
nonce race or hits the target's own idempotency state (RULE-12 requires
checkJob false next block), which counts as a revert toward
auto-deactivation. Documented + designed, not just policed.

### SEC-10: Mempool front-running / MEV - PROTECTED (nothing to capture)
`executeJob` pays the refund to `msg.sender` and only `authorizedExecutors`
pass the gate - a searcher CANNOT front-run the call to capture the refund,
and there is no protocol reward inside the tx to sandwich. Standard
sandwiching of the target's internal effects is a property of the target
contract, unchanged by automation. Private-RPC submission remains available
by pointing the signer's chain config at a private relay (no code change).

### SEC-11: Simulation vs mining-time drift - FIXED (layered by design)
Two gates cover two different windows, deliberately both present:
1. PRIMARY (watcher, scan time): `eth_estimateGas` verifies a due job
   BEFORE it enters the pipeline - unexecutable jobs never cross the
   signer channel and never allocate a nonce (RULE-13).
2. LAST-MOMENT (signer, pre-sign): `broadcast_and_confirm` re-runs
   `eth_estimateGas` on the EXACT final transaction immediately before
   signing; a revert drops the request AND rolls the allocated nonce back
   (a drift-drop must not strand the sequential queue).
Residual drift between that check and inclusion lands in the on-chain
soft-exit path (SEC-04), so drift can never cost the client anything. A
related waste-fix ships alongside: the watcher suppresses re-scan of a job
for ~6s (2-3 blocks) after its push, eliminating per-block re-estimates and
duplicate pushes while the signed tx is in flight.

### SEC-12: Hot-wallet depletion circuit breaker - FIXED
Before every broadcast the signer checks the executor's native balance
against `min_executor_balance_wei` (default 0.1 native; env
`PP_MIN_EXECUTOR_BALANCE_WEI`); below the floor it HALTS all broadcasts
with an error log (fail-closed) until topped up. Because escrow
reimbursement >= gas spent, funded jobs cannot drain the wallet - the
breaker guards the pre-funded float against pathological revert storms.

### SEC-13: Silent WebSocket death - FIXED
`/healthz` is no longer static: the watcher records the freshest `newHead`
unix time per process (`metrics::liveness`); if supervised chains stop
producing heads for >120s, `/healthz` returns **503 stale-heads**, which
fails Railway's healthcheck and restarts the service. Reconnect logic
(exponential backoff + free-tier endpoint rotation) was already in place.
Tests: `liveness_tracks_head_freshness`.

## Phase 3: Infrastructure, Keys & Access Control

### SEC-14: Signer hot-wallet isolation - FIXED (enforced + warned)
The executor key can ONLY ever be an `authorizedExecutor` - it has no path
to treasury, tips, owner setters, or escrow. The deploy script now WARNS
loudly when `OWNER` is unset (defaults to the deployer hot wallet) and the
runbook mandates `OWNER=$SAFE` from day one. Fuji deploys with owner =
the Safe, treasury = the Safe, executor = key isolated on Railway.

### SEC-15: Observer-to-signer authentication - PROTECTED
The signer's HTTP surface requires a bearer token compared in CONSTANT
TIME (`subtle_constant_eq`) and rejects with a metrics counter; production
topology is mTLS - the signer refuses plaintext binds off-loopback and
requires client certs signed by the private CA (worker/README.md runbook).
Spoofed dispatch commands fail auth before any key material is touched.
Standalone mode has no network bridge at all (in-process channel).

### SEC-16: Admin Safe quorum & key redundancy - FIXED (documented procedure)
Runbook (docs/fuji-golive.md): deploy with OWNER = Safe from day one;
before mainnet liquidity, rotate the Safe 1-of-1 -> 2-of-3 (Safe UI, two
additional signers in geographically separate storage); quarterly
owner-action drill (one no-op setter call) keeps rotation practiced. The
registry additionally survives full owner loss: escrows are
owner-withdrawable BY JOB OWNERS without any admin action (worst case =
jobs stop being executed, funds never trapped).

### SEC-17: Malicious custom targets / SSRF via client URLs - PROTECTED (surface does not exist)
PeekPeak has NO client-supplied URLs anywhere: jobs are contract ADDRESSES
(dispatched via low-level EVM calls, not HTTP); chain RPC endpoints come
from operator-committed configs or operator-only env (RULE-10); the worker
makes zero webhook/outbound-HTTP calls beyond its configured RPC list, and
that list is operator-controlled. There is no SSRF surface to harden.

## Verification

- Contracts: forge test 74/74 (incl. all reentrancy/solvency/tip suites).
- Worker: cargo test 21/21 (incl. sec08 fee-bump math, liveness, nonce,
  fee-cap, e2e x2 on anvil).
- Daemon path: rehearse.sh exercises scripts + standalone daemon + tip
  accounting end-to-end before every deploy.
