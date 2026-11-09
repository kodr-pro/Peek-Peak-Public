# L1 Economics: Non-Swappable Gas Tokens (SPEC-13)

> Design ruling for sovereign Avalanche L1s whose native gas token cannot pay
> an AVAX-based operator. Grounded in Avalanche's Interchain Messaging (ICM):
> messages carry aggregate BLS signatures from the source chain's validator
> set, verified at the destination against the P-Chain validator registry;
> Interchain Token Transfer (ICTT) moves tokens natively over ICM; relayers
> are permissionless (docs.avax.network / solutions/interoperability).

## The problem

PeekPeak's unit economics are AVAX-native: the operator (keeper infra + risk)
earns the keeper tip, denominated in each chain's NATIVE gas currency
(`keeperTip`, set per deployment - see DIV-D-3). On the C-Chain this is AVAX.
On a sovereign L1 the native token is whatever the L1 launched with:

1. **Swappable / valuable token** - tips have real value; optionally bridge
   them home via ICTT (Tier 3).
2. **Non-swappable / low-value token** - tips are dust. The operator cannot
   run on dust. Escrow-based GAS reimbursement still works perfectly (the
   executor recycles the L1's own token as execution gas), but the TIP leg
   of the economics must move elsewhere.

Key observation that shapes everything below: **the executor's gas on an L1
is self-sustaining.** `executeJob` reimburses `gasUsed x gasPrice` in the
L1's native token, which is exactly what the executor spends to broadcast
there. The only cross-chain obligation is the operator's FEE.

## Tier 1 - Zero-tip flywheel (available today, no new code)

Set `keeperTip = 0` for that L1's registry deployment (`KEEPER_TIP_WEI=0`
falls back to default; `setKeeperTip(0)` after deploy, both supported).
Integrators pay exactly the gas their jobs consume, in their own chain's
token, forever. Operator cost = marginal infrastructure.

Use when: the L1 sponsor runs their own watcher replica or the chain is
strategically worth serving at infra cost.

## Tier 2 - L1 Coverage Pool on C-Chain (implemented: `CoveragePool.sol`)

The owner's "pay AVAX into a pool, time-expiring" direction, hardened.

**Mechanics** (contract lives on C-Chain, AVAX-denominated):

1. The L1's sponsor (its DAO / foundation) prepays a coverage TERM: whole
   days at an owner-set `pricePerDay(chainId)`.
2. `sponsor(chainId) payable` extends `expiresAt` FORWARD ONLY from
   `max(current expiry, now)`; partial-day surplus is revenue; a single
   deposit cannot buy > 365 days (`TermTooLong`).
3. Sponsor AVAX routes straight to the treasury Safe on receipt - the pool
   holds **zero custody**. No refunds exist, so no refund-griefing, no
   custody obligation, no "pool drain" attack class. Like an insurance
   premium: pay for a term, term is visible on-chain, top up any time.
4. **Fail-closed service gate**: the worker reads `covered(chainId)` before
   scanning/executing on that L1. No coverage -> no pokes. Jobs simply stop
   being automated; integrator escrows on the L1 are untouched and
   withdrawable at all times.

**Why this shape is the most secure**:

- User funds (L1 escrows) are NEVER encumbered by the operator's commercial
  state - the coverage gate lives on a different chain from the escrow.
- No bridge and no cross-chain message sits in the payment path. The only
  cross-chain coordination is the worker itself, which already watches every
  chain - a system that exists and is tested.
- Failure mode is silent STOP (fail-closed), not loss of funds: worst case,
  automation pauses until the sponsor tops up.

**Worker policy (specified; ships with the L1 rollout)**: for chains whose
config carries `coverageChainId`, the supervisor calls `covered()` on the
C-Chain pool each scan cycle; on lapse it logs `coverage lapsed; halting
chain` and skips scan/push. Re-arm is automatic when a new term is sponsored.

## Tier 3 - Tip repatriation via ICTT (optional, operational only)

For L1s whose native token HAS value but no C-Chain market: bridge treasury
tips home with Avalanche's native token bridge (ICTT - home contract on the
L1, remote on C-Chain, validator-signed ICM messages, permissionless
relayers). This is a periodic treasury operation, not a payment-path
dependency; if the bridge or a relayer is down, nothing about execution,
escrow, or coverage changes.

## Why ICM is deliberately OUT of the critical path

The alternative design - the L1 registry verifying C-Chain pool state via a
Warp/Teleporter message - was evaluated and rejected for the protocol core:

- **Liveness coupling**: execution on the L1 would depend on relayer delivery
  of coverage attestations. ICM relayers are permissionless (good) but not
  guaranteed (bad, for a keeper whose whole job is availability).
- **Bigger trust surface**: a Teleporter receiver on every spoke registry,
  message replay/freshness handling, and quorum-rotation edge cases (the L1's
  validator set changes must be tracked on C-Chain via the P-Chain registry
  and vice versa) - a large audit surface for zero safety gain.
- **No safety benefit**: the worker's fail-closed `covered()` check achieves
  the identical guarantee with one local read. Safety-critical state (user
  escrow) never crosses chains either way.

ICM is exactly the right tool for what REMAINS: moving VALUE that has somewhere
to go (Tier 3 repatriation), where a delayed message costs nothing.

## Executor-balance guard (the owner's third idea - adopted as ops policy)

The worker already self-monitors executor balances on every chain it serves
(metrics endpoint exposes broadcasts/errors). Policy: alert + halt a chain
when the executor's native balance on it falls below `gasLimit + headroom`
for N consecutive cycles - this is enforced off-chain today and needs no
on-chain change (the L1 escrow flywheel makes sustained drain impossible for
funded jobs: reimbursement >= gas spent by construction).

## Rollout

| Step | What | Status |
|------|------|--------|
| 1 | Per-chain native-denominated `keeperTip` (constructor + admin) | shipped |
| 2 | `CoveragePool.sol` on C-Chain + tests (74-suite green) | shipped |
| 3 | Worker `covered()` gate for coverage-tagged chains | specified, next PR |
| 4 | First sponsored L1 (sponsor prices the term, worker gate on) | post-Fuji |
| 5 | Optional ICTT tip repatriation runbook | when a valued-token L1 lands |

Funding guidance for integrators on any chain (SKILL.md rule 6): escrow at
least `(gasLimit + 70000) x gasPrice + keeperTip(chain)` per banked execution,
where `keeperTip(chain)` is read from that chain's registry - 0 on
zero-tip L1s.
