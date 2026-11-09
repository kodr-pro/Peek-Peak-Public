# Gas Anomaly: coreth gasLimit/2 Floor (Q-6 resolved)

## Observation (Fuji, 2026-09-24)

Five live `executeJob` transactions charged the executor **325,000 gas**
each, while the identical signed transaction replayed against a vanilla EVM
(anvil fork of the same Fuji state) burns **114,029 gas**. The number is
exact: 325,000 = 650,000 / 2 - half the transaction's gas limit - for every
run. Confirmed from two independent avalanchego endpoints (official gateway
and PublicNode); coreth consensus, not a display bug: the executor's balance
delta (-0.00103 AVAX over 4 runs at ~1 gwei) matches the halved charge.

## Mechanism

Avalanche's EVM (coreth) applies a floor of `gasLimit / 2` on the gas
CHARGED for this transaction shape (outer 1559 tx whose inner `.call`
carries an explicit large stipend). Effective law, empirically:

    gas_charged = max(gas_actually_used, gas_limit / 2)

Vanilla EVM charges `gas_actually_used` only. The floor punishes
over-provisioned gas limits: every unused unit below the half-line is still
paid for by the sender.

## Impact before the fix

The worker broadcast with `job.gasLimit + 150k` = 650,000 always ->
executor paid 325,000 gas while being reimbursed for ~67,000-104,000
(the registry's measured accounting). Residual loss ~0.00026 AVAX per
execution at ~1 gwei; at mainnet prices (~25 gwei) that would be ~0.0065
AVAX per execution - MORE than the 0.005 keeper tip. Not acceptable.

## Fix (shipped in the worker)

`broadcast_and_confirm` now derives the broadcast gas limit from the
pre-send `eth_estimateGas` (which fully simulates `performJob`, heavy path
included): `limit = estimate * 1.2`, capped at `job.gasLimit + headroom`.
With the limit hugging the true requirement, `max(used, limit/2)` collapses
to ~`used`, and the floor becomes harmless. A target that branches on
`gasleft()` to behave differently under estimation only deactivates itself
via the consecutive-revert cap (RULE-4 / DIV-D-1).

Registry-side calibration (measured): full-transaction overhead beyond the
registry's internal measurement = intrinsic + tail = **~44,870 gas** on the
cold first run. The Fuji registry's 35,000 buffer slightly under-covers
(trivial at testnet prices); future deployments (including mainnet) use
**OVERHEAD_BUFFER = 50000**.

## Post-fix verification (next live executions)

Expected per-execution executor cost after the worker fix: ~77k-114k gas
charged (vs 325k), i.e. reimbursement >= cost and the tip is clean margin.
Watch the next `JobExecuted` receipts after the Railway redeploy.
