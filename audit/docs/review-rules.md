# PeekPeak Review Rules (Ground Truth)

Numbered rules enforced on every change. Cited as RULE-n.

## RULE-1 Checks-Effects-Interactions
Every function that makes an external call updates ALL internal state (escrow
deductions, counters, timestamps) BEFORE the external call. Reentrancy guard is
defense-in-depth, not a substitute for ordering.

Reconciliation with SPEC-5 (audit F-8.2, 2026-09-25): `executeJob` MUST deduct
escrow AFTER the target call (gas measurement requires it), so its ordering
exception is safe only because (a) every re-entrable value-touching entry point
(`executeJob`, `withdrawGas`, `pull`) is `nonReentrant`, and (b) the unguarded
mutators (`registerJob`, `depositGas`, `setJobStatus`) are additive-only - any
post-call write-back must therefore read the CURRENT storage value, never a
pre-call snapshot (audit finding F-1 was exactly such a stale write-back).

## RULE-2 Default-deny access control
Every external/bpublic function documents and enforces its caller set: `onlyOwner`,
authorized executor, or job owner. No function mutates state without a gate.

## RULE-3 Escrow solvency precondition
No `.call` dispatch to a job target unless `escrow >= (gasLimit + 2*OVERHEAD_BUFFER) *
tx.gasprice + keeperTip` computed in uint256. Depleted jobs deactivate with an
event; they never execute.

## RULE-4 Failed executions charge nobody but the party at fault
A reverting target never charges the client (soft-exit, DIV-D-1) and never pays
the executor. A successful execution MUST charge exactly
`baseExecutionCost + keeperTip` from escrow - never more.

## RULE-5 No `transfer()`/`send()` for protocol payouts
All native-coin payouts use `call{value:}("")` with the return value checked.
Executor refund failure degrades to pull-payment (`pendingPull`); treasury send
failure reverts.

## RULE-6 Gas arithmetic in uint256
Any multiplication involving `gasLimit` or `tx.gasprice` happens in uint256.
Narrowing casts to uint128 require a prior bound check.

## RULE-7 Struct packing honesty
`Job` occupies exactly 2 slots. Any new field must either fit declared padding
(bytes 25-31 of slot A / bytes 28-31 of slot B) or justify a third slot in this
document. Packing is verified by test (`vm.load`).

## RULE-8 Events for every state transition the worker depends on
Registration, depletion, deactivation, execution (with gas/cost/tip), deposits,
withdrawals, executor set, treasury set, tip set, pause, pull accounting. The
off-chain worker only trusts events + storage reads, never logs from other sources.

## RULE-9 Custom errors over revert strings
All reverts use custom errors (`error UnauthorizedExecutor()`, etc.). No string
reverts in hot paths.

## RULE-10 No secrets in-repo
Signer keys live only in Node B's encrypted keystore; deployer keys only in local
env. `deploy/chains/*.json` contains public addresses and RPC URLs only. Any
credential found in a diff is a blocker.

## RULE-11 Every job bounded
`gasLimit <= 2,500,000`; `maxGasPriceGwei >= 25` (floor) and enforced ceiling vs
`tx.gasprice`; `keeperTip <= 0.05 ether`; `maxConsecutiveReverts <= 10`;
`execPayload <= MAX_EXEC_PAYLOAD` = 4096 bytes at dispatch (DIV-D-4);
`OVERHEAD_BUFFER` in `[10_000, 500_000]` at construction (DIV-D-5). Bounds checked
at registration, dispatch, and construction points.

## RULE-12 checkJob/performJob contract
Client contracts (and reference adapters): `checkJob` is `view`-pure logic returning
true only when actionable; `performJob` restricted to the registry, mutates state so
`checkJob` is false next block, and is idempotent for repeated invocation within the
same trigger window.

## RULE-13 Worker never signs what it did not simulate
The signer broadcasts only payloads the watcher (or its own failover scan) verified
via `eth_estimateGas`. Nonce management is single-writer (Node B).

## RULE-14 Gas price discipline
Worker-set `maxFeePerGas = min(job.maxGasPriceGwei, baseFee + tipCap)`. On-chain
`tx.gasprice` enforcement is the backstop, not the first line.

## RULE-15 Tests prove the economics
The conservation invariant (SPEC-11) and the exact flat keeper tip (0.005 AVAX
default) routed to treasury are asserted in tests, not assumed. Every RULE-1..14
violation class has a test that fails on it.
