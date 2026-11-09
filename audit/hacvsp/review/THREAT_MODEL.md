# THREAT_MODEL.md


The system under review is the PeekPeak protocol: an autonomous job
execution registry (PeekRegistry), a prepaid coverage pool
(CoveragePool), and two external-protocol adapters (HarvestKeeper,
PharaohEpochKeeper). The contracts are non-upgradeable, non-proxy, and
deploy with an exact-pinned compiler (solc 0.8.38, via_ir, 200 runs).

Out of scope: the Safe wallet's operational security, the external
protocols the adapters call (Pharaoh, Yield Yak), the frontend, and the
off-chain watcher/worker infrastructure. These are trusted boundaries
documented in the trust boundaries section.

The model assumes: a public adversarial chain environment, rational
economic actors, no collusion between block validators and protocol
participants, and the owner Safe operates with honest 2/3 key holders.


_Checklist: every privileged entry point from the access matrix is rowed and
assessed; every PUBLIC state-changing function is explicitly confirmed._

- [x] All privileged (7) entry points reviewed
- [x] All PUBLIC (10) state-changing functions confirmed intentional
- [x] Untriaged static findings assessed for exploitability

> **Note on PUBLIC classification:** 6 of 10 "PUBLIC" functions have runtime
> authorization gates (in-body requires) that AST-level modifier extraction
> cannot detect. Effective access is documented per-row below. Verified by
> the stage-8 access-control harness (17 wired enforcement tests).

| Entry point | Roles | Trust | Capability | Motivation |
|---|---|---|---|---|
| **Owner-gated functions** |
| CoveragePool.setPricePerDay | OWNER | High - Safe Wallet 2/3 physical separation of keys. Revertible | Set per-chain coverage cost | Accidental or coerced mispricing: price=0 unlocks UnpricedChain revert path (fail-closed ✓); price=1 wei makes coverage nearly free - economic griefing, not theft |
| CoveragePool.setTreasury | OWNER | High - Safe Wallet 2/3, physical key separation. Revertible | Change treasury address (tip recipient) | Accidental or coerced diversion of earned tips to a new wallet; also - could be set to a contract that rejects ETH, bricking tip flow (fail-closed revert in executeJob) |
| PeekRegistry.setTreasury | OWNER | High - Safe Wallet 2/3 physical separation of keys. Revertible | Change treasury address (tip recipient) | Accidental or coerced diversion of earned tips to a new wallet; also - could be set to a contract that rejects ETH, bricking tip flow (fail-closed revert in executeJob) |
| PeekRegistry.setExecutor | OWNER | High - Safe Wallet 2/3, physical key separation. Revertible | Authorize/deauthorize executor addresses (keeper gate) | Authorizing a malicious executor that self-deals escrow via colluding job targets; also - deauthorizing all executors bricks job execution (liveness halt, recoverable by re-authorizing) |
| PeekRegistry.setKeeperTip | OWNER | High - Safe Wallet 2/3, physical key separation. Revertible | Set the flat tip per execution (bounded: 0 ≤ tip ≤ 0.05 ETH by MAX_KEEPER_TIP constant) | Tip=0 starves keepers - no one executes jobs (liveness grief, not theft); tip=max drains escrows faster per execution - cost amplification, bounded by the constant |
| PeekRegistry.setMaxConsecutiveReverts | OWNER | High - Safe Wallet 2/3, physical key separation. Revertible | Set the circuit-breaker threshold for auto-deactivation on consecutive reverts (bounded: 1 ≤ limit ≤ MAX_REVERT_LIMIT) | Limit=1 auto-deactivates jobs on a single transient revert - premature job kill, recoverable; limit=max effectively disables the breaker - reverting targets keep consuming escrow one worst-case cost at a time until depleted |
| PeekRegistry.setPaused | OWNER | High - Safe Wallet 2/3, physical key separation. Revertible | Pause/unpause all job registration and execution (global kill switch) | Pause=true halts the entire protocol - no registrations, no executions, escrows frozen until unpause; no fund movement possible while paused (fail-closed); abuse is liveness-only, not theft |
| **Truly open (no runtime gate)** |
| CoveragePool.sponsor | PUBLIC (truly open) | None - anyone with ETH | Prepay coverage for any chainId by whole days; ETH forwarded to treasury immediately | No theft vector (pool holds zero custody - proven by test_Proof_NoCustody). Griefing: sponsor on an unpriced chainId reverts (fail-closed ✓). Economic: front-running someone else's sponsorship has no effect (terms are per-chain, not competitive) |
| PeekRegistry.registerJob | PUBLIC (truly open) | None - anyone with ETH | Create a job with escrow; jobId = keccak(target, msg.sender, nonce) | Job registration is self-funded - attacker only locks their own ETH. Griefing: register a target that always reverts → escrow drains one worst-case cost per execution (bounded by maxConsecutiveReverts breaker). No cross-job effect (per-job escrow isolation) |
| PeekRegistry.depositGas | PUBLIC (truly open) | None - anyone with ETH | Top up any job's escrow (additive; cannot reduce) | Purely additive - no way to withdraw someone else's deposit. No griefing vector: adding to a job you don't own only helps that job's owner (they can withdraw it). Note: attacker could fund a victim's job to extend its life against the victim's wishes - low-severity, note-only |
| PeekRegistry.pull | PUBLIC (truly open) | None - anyone | Withdraw own pendingPull balance (executor refund fallback) | Can only withdraw msg.sender's own accumulated balance - no cross-actor theft. nonReentrant guarded. Zero-balance reverts (NothingToPull) - no state change on empty pull |
| **Runtime-gated to job owner (in-body require)** |
| PeekRegistry.withdrawGas | PUBLIC (runtime gate: job.owner) | High - job owner is the depositor | Withdraw from own job's escrow; checked subtraction prevents overdraft | No cross-job access (per-job ownership check). Overdraft reverts (InsufficientEscrow - proven by test_Proof_WithdrawGas_OverBalance). Rejection: a non-ETH-receiving owner wallet bricks their own escrow (self-inflicted) |
| PeekRegistry.setJobStatus | PUBLIC (runtime gate: job.owner) | High - job owner controls own job | Pause/unpause own job (isActive flag) | Only affects own job's executability - no cross-job impact. A paused job still holds escrow (withdrawable). Griefing: none beyond self-harm |
| **Runtime-gated to authorized executor** |
| PeekRegistry.executeJob | PUBLIC (runtime gate: authorizedExecutors) | Medium - any address the owner has authorized | Trigger a job's target.performJob with gasLimit; charges escrow for gas + tip | Core value-transfer path. Collusion: authorized executor + malicious job target → target consumes gasLimit then reverts → executor still charges escrow (RULE-4: never charge for failed work - mitigated). Reentrancy: nonReentrant + F-1 defensive escrow re-read (suppressed with justification). MEV: first-mover races for tips - no priority mechanism, natural competition |
| **Runtime-gated to registry (adapter chain)** |
| DemoHeartbeat.performJob | PUBLIC (runtime gate: REGISTRY_ADDRESS) | Implicit - trust derives from the registry's executor authorization | Emit a DemoTick heartbeat (demo/monitoring contract) | No value transfer; only callable by the registry (which is itself gated). Abuse: none beyond emitting a heartbeat event - zero state impact beyond a counter |
| HarvestKeeper.performJob | PUBLIC (runtime gate: REGISTRY_ADDRESS) | Implicit - trust derives from the registry chain | Trigger harvest on the external harvester contract (Yield Yak-style adapter) | External call surface: the harvester address is immutable (set at deploy). A malicious/compromised harvester contract could do anything within its own permissions - the keeper itself holds no value. Outcome flags recorded in Harvested event (proven by test_Kill328) |
| PharaohEpochKeeper.performJob | PUBLIC (runtime gate: REGISTRY_ADDRESS) | Implicit - trust derives from the registry chain | Roll epoch: call voter.distribute() and gauge.harvest() (Pharaoh protocol adapter) | External call surface: voter and gauge addresses are immutable. Failed legs don't roll back the epoch (swallow-on-purpose, flags in EpochRolled event - proven by test_Kill354). No value held by the keeper. Risk: if voter/gauge are upgradeable, their compromise affects Pharaoh, not PeekPeak |

## Actor Matrix
### Untriaged static findings

_High-signal items only - full list in artifacts/static-analysis-summary.json._

**missing-zero-check (constructor params):** Constructor address params without explicit zero-checks. Low severity: a zero address at deployment is a deployment error, not an exploit vector; the registry/pool constructors already revert on zero treasury. Recommend adding explicit checks for defense-in-depth but not blocking.

- [x] `slither/missing-zero-check` @ DemoHeartbeat.sol:33 - constructor(registry): zero registry would brick the demo contract only (no value). Accept.
- [x] `slither/missing-zero-check` @ HarvestKeeper.sol:37 - constructor(registry, harvester): zero registry reverts on first performJob (NotRegistry). Zero harvester reverts on harvest call. Fail-closed by design. Accept.
- [x] `slither/missing-zero-check` @ PharaohEpochKeeper.sol:40 - same pattern as HarvestKeeper. Accept.

**reentrancy-events / reentrancy-benign:** Event emission after external calls. The events are informational (flags recorded for off-chain consumers); no state that security depends on is written after the call (effects-before-interactions is enforced by the effects-first pattern in the keepers and by nonReentrant in the registry).

- [x] `slither/reentrancy-benign` @ PeekRegistry.sol:275-344 - executeJob emits after call; nonReentrant guarded; state written before events in the failure path. Accept (same site as the suppressed reentrancy-no-eth).
- [x] `slither/reentrancy-events` @ CoveragePool.sol, HarvestKeeper.sol, PharaohEpochKeeper.sol - informational events after external calls; no security-relevant state affected. Accept.

**timestamp:** Use of block.timestamp for time-based logic. The protocol's scheduling uses whole-day/epoch boundaries - a 15-second validator drift is immaterial to day-level granularity. Accept as by-design for a scheduling protocol.

- [x] All `slither/timestamp` findings - reviewed; day/epoch granularity makes sub-minute timestamp manipulation irrelevant. Accept.

**low-level-calls:** The `.call{value}()` patterns in withdrawGas/executeJob/pull are checked (return value asserted, revert on failure). The `target.call` in executeJob is intentionally untrusted (the job target). Accept.

- [x] `slither/low-level-calls` @ PeekRegistry.sol:229-239, 347-354; CoveragePool.sol:58-79 - all return values checked. Accept.

**naming-convention, pragma, assembly (OZ StorageSlot), solc-version, aderyn informational:** All in third-party libraries or stylistic. No exploitability. Accept.

- [x] All naming/pragma/assembly/aderyn informational findings - third-party or stylistic. Accept.


_Checklist: enumerate every boundary where control crosses a trust line._

- [x] Native-asset custody boundary (escrow/prepayment custody mapped)
- [x] External-call boundaries (every `.call`/interface target listed)
- [x] Admin/privilege boundary (owner powers enumerated, timelock status)
- [x] Upgrade/deployment boundary (proxy status confirmed, key custody)

## Trust Boundaries
### 1. Native-asset custody (PeekRegistry escrow)

**Who holds:** PeekRegistry contract holds per-job escrows (uint128 per jobId).
**What crosses:** job owners deposit → executors consume (gas + tip) → treasury receives tips.
**Enforced by:** per-job ownership (withdrawGas/setJobStatus), authorized-executor gate (executeJob), checked subtraction (overdraft reverts), maxConsecutiveReverts breaker.
**Residual risk:** escrow is slowly consumed by executions even if the target always reverts (bounded by breaker). Owner can pause all flows.

### 2. Native-asset custody (CoveragePool prepayment)

**Who holds:** CoveragePool holds nothing - all sponsorship ETH forwarded to treasury immediately.
**What crosses:** sponsor → treasury (direct, immediate).
**Enforced by:** no custody design (proven by test_Proof_NoCustody_AfterSponsorship). Terms are bookkeeping only (expiresAt).
**Residual risk:** none from the pool itself; treasury custody is the Safe's responsibility.

### 3. External-call boundary (executeJob → job target)

**Who holds:** the job target contract (arbitrary, registered by anyone).
**What crosses:** gasLimit-capped execution of `IAutoJob.performJob(bytes)`.
**Enforced by:** gasLimit forward (target can consume at most gasLimit), nonReentrant (no re-entry into registry), worst-case escrow check before call, RULE-4 (no charge on revert).
**Residual risk:** target can consume the full gasLimit per execution - escrow drains at the contractual rate. Targets receiving arbitrary `execPayload` bytes must validate their own inputs (PeekPeak is a trigger, not a security boundary - see protocol boundary note below).

### 4. External-call boundary (adapters → external protocols)

**Who holds:** HarvestKeeper → external harvester; PharaohEpochKeeper → external voter + gauge.
**What crosses:** calls to immutable external contracts; no value held by the adapters.
**Enforced by:** adapter addresses immutable (set at deploy); try/catch swallow-on-purpose (failed legs don't roll back epoch - flags in event for observability); registry-gated (only the registry can trigger).
**Residual risk:** if external protocols are upgradeable/compromised, their behavior changes - but the adapter holds no value and the registry's escrow is untouched.

### 5. Admin/privilege boundary (owner)

**Who holds:** Safe Wallet 2/3 with physical key separation.
**What crosses:** all OWNER functions (7 in the matrix above).
**Enforced by:** OZ Ownable (onlyOwner modifier); no timelock currently.
**Residual risk:** no timelock means the 2/3 Safe can make instant parameter changes (tip, executors, pause). Users must trust the Safe's operational security. **Recommendation:** add a timelock before mainnet if the threat model warrants it.

### 6. Protocol boundary: scheduler ≠ rate limiter

PeekPeak guarantees job isolation (one job cannot affect another's schedule,
escrow, or state). PeekPeak does NOT guarantee that a target contract is
protected from being called by other sources. Consumers MUST implement their
own frequency/access gating inside `performJob` - PeekPeak is a trigger, not
a security boundary. An attacker can always call any public function on any
contract directly, with or without PeekPeak.

Implication: any contract implementing IAutoJob must treat `performJob` as
an untrusted external entry point and gate its own side effects.


_Checklist: each value-flow is gamed on paper - describe the attack and the
control that blocks it._

- [x] Custody drain vectors (escrow withdrawal paths reviewed)
- [x] Gas/ griefing vectors (costless spam, unbounded work per call)
- [x] Tip/reward extraction abuse (keeper economics)
- [x] Rounding/dust accumulation reviewed

## Economic Vectors
### Vector 1: Escrow drain via reverting target

**Attack:** register a job whose target always reverts; an authorized executor repeatedly calls executeJob.
**Precondition:** an authorized executor is willing to collude (or is the attacker).
**Control:** worst-case escrow check before each call ensures sufficient escrow; gas is still consumed (executor paid); consecutive-revert breaker deactivates the job after maxConsecutiveReverts.
**Net effect:** escrow drains at one worst-case cost per execution. The executor is paid for gas (by design). The job owner loses only their own escrow. Mitigated.

### Vector 2: Executor tip extraction via gas-price gaming

**Attack:** authorized executor sets tx.gasprice at the job's ceiling (maxGasPriceGwei), maximizing `gasUsed * tx.gasprice` reimbursement per execution.
**Precondition:** executor is authorized; job has a high gas price ceiling.
**Control:** each job sets its own maxGasPriceGwei ceiling; the worst-case escrow requirement accounts for the ceiling. The executor pays the actual gas price to the network - they only profit if the ceiling exceeds the actual price (bounded by the job's own configuration).
**Net effect:** executor profits up to the ceiling delta. This is the designed keeper incentive - not a vulnerability.

### Vector 3: Sponsorship dust / rounding

**Attack:** sponsor with `msg.value` that's a fraction of a day's price.
**Precondition:** none.
**Control:** `msg.value < price` reverts (InsufficientDeposit). `msg.value / price` floors to whole days; the **full** msg.value goes to treasury (dust becomes revenue - by-design, documented in COVERAGE_EXCEPTIONS).
**Net effect:** no dust accumulation in the contract; treasury absorbs fractional-day surplus. Clean.

### Vector 4: CoveragePool repricing mid-term

**Attack:** owner sets pricePerDay to 1 wei while a sponsor has a long active term.
**Precondition:** owner action.
**Control:** terms are forward-only - the sponsor's existing expiresAt is locked in. Repricing affects only future sponsorships. The sponsor's prepaid days are not devalued.
**Net effect:** no retroactive impact. Clean.


_Checklist: ordering, backrunning, sandwich surfaces._

- [x] Executor races (first-mover advantage for tips - priority/censorship risk)
- [x] Backrunning opportunities (profitable follow-on transactions)
- [x] Oracle/state-dependence ordering risks

## MEV Exposure
### Executor tip races

Executors compete to be the first to execute an eligible job and claim the tip. This is by design - natural competition keeps execution latency low. No on-chain priority mechanism (no commit-reveal, no auction); the winner is determined by block position. An executor with privileged mempool access could consistently front-run others, but this doesn't harm the protocol (the job executes either way). **No mitigation needed - the competition is the feature.**

### Backrunning job executions

If a job's side effect creates a profitable follow-on (e.g., an epoch roll that changes a staking position), a backrunner could profit from the state change. This is a property of the job's target, not of PeekPeak. The executor could also backrun their own execution (same block) - this is expected keeper behavior.

### No oracle dependency

PeekPeak has no price feeds or external state dependencies. All scheduling is time-based (block.timestamp at day/epoch granularity) - no manipulation surface.
