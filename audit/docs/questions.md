# PeekPeak Open Questions Register

Questions that gated implementation decisions. ANSWERED entries are binding.

| ID | Question | Status | Answer / Owner |
|----|----------|--------|----------------|
| Q-1 | Worker language: Rust vs TypeScript? | ANSWERED | Rust (alloy + tokio). Single binary, low RAM, robust WS reconnects. |
| Q-2 | Registry mutability: UUPS vs immutable? | ANSWERED | Immutable + versioned. Tunables stay owner-settable. Global `paused` breaker. |
| Q-3 | Treasury/executor key model? | ANSWERED | Safe multisig treasury (cold) + dedicated EOA hot wallet (3-5 AVAX cap). |
| Q-4 | Vercel provisioning path? | ANSWERED | Dashboard import by owner at Phase 4; Root Directory = frontend/. |
| Q-5 | Executor permission model: permissioned vs permissionless? | ANSWERED | Permissioned (`authorizedExecutors`) per spec - prevents nonce/MEV contention. Revisit post-mainnet. |
| Q-6 | Exact OVERHEAD_BUFFER value? | ANSWERED | Calibrated from live Fuji executions + anvil-fork replay (docs/gas-anomaly.md): measured overhead 44,870 gas; future deploys use 50,000 (script default updated). Fuji keeps 35,000 (trivial delta at testnet prices). Also surfaced and fixed the coreth gasLimit/2 charge floor via estimate-hugging gas limits in the worker. |
| Q-7 | Test signer keys in the worker? | ANSWERED | Owner approved (2026-09-23) use of anvil's publicly documented dev keys via PP_TEST_EXECUTOR_KEY in tests only; production exclusively uses the encrypted keystore path (RULE-10 signoff recorded). |
