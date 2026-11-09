# Fuji Validation Runbook (SPEC-11)

Everything here runs from this repo. Prerequisites that only the owner can
provide are marked [OWNER].

## 0. Prerequisites [OWNER]

- [ ] Funded deployer address on Fuji with >= 1 AVAX (gas for deploys) - key
      available as `DEPLOYER_KEY` env (never committed).
- [ ] Safe treasury created on Fuji (`TREASURY` address).
- [ ] Dedicated executor EOA created + funded with 3-5 AVAX, then exported as
      an encrypted keystore (`PP_KEYSTORE_PATH`/`PP_SIGNER_PASSWORD` on Node B).

## 1. Contracts gate (local, before touching Fuji)

```bash
cd contracts
forge test                                      # 61 tests green
FOUNDRY_PROFILE=fuzz forge test                 # long invariant campaign
forge coverage --report summary                 # >= 95% on PeekRegistry
cd ../worker && cargo test                      # incl. anvil E2E
```

## 2. Deploy to Fuji

```bash
cd contracts
DEPLOYER_KEY=0x... TREASURY=0x... OVERHEAD_BUFFER=35000 \
  CREATE2_SALT=0x$(printf 'peekpeak-v1%.0s' {1..3}) \
  forge script script/DeployRegistry.s.sol --rpc-url $FUJI_RPC --broadcast
# record the registry address in ../deploy/chains/fuji.json and
# ../frontend/lib/chains.ts (public data)
```

Then authorize the executor (multisig call): `setExecutor(<executor>, true)`.

## 3. Register the dry-run job (SPEC-11: 0.2 AVAX, 5 executions)

```bash
DEPLOYER_KEY=0x.. REGISTRY=0x.. DEPOSIT_WEI=200000000000000000 \
  forge script script/RegisterJob.s.sol:DeployMockJob --rpc-url $FUJI_RPC --broadcast
```

## 4. Worker bring-up (dual node)

- Node A (home server): `deploy/systemd/peekpeakd-watcher.service` with the
  mTLS material from `worker/README.md`, `--executor-address` set.
- Node B (cloud VPS): `deploy/systemd/peekpeakd-signer.service` with keystore.
- Generate mTLS material per the runbook; verify heartbeat every 5s in logs.

## 5. Acceptance checklist (SPEC-11)

- [ ] Foundry coverage >= 95% (local gate, step 1).
- [ ] Conservation invariant green under >= 1M-run fuzz.
- [ ] Reverting target charges nobody (unit test suite proves; optionally
      register `MockRevertingJob` on Fuji and observe).
- [ ] Multi-L1 isolation: point the worker at Fuji + a Subnet-EVM local L1
      concurrently; verify chainId-tagged separation in logs.
- [ ] Failover: `systemctl stop peekpeakd-watcher` on Node A; Node B's
      "failover scan engaged" log must appear within 35s.
- [ ] Arm `MockJob` (`setReady(true)`) 5 times sequentially; after each
      execution verify: escrow decreased, executor refunded, treasury received
      exactly 0.005 AVAX (keeperTip):
      `cast logs --from-block <a> --address <registry> 'JobExecuted(bytes32,address,uint256,uint256,uint256)'`
- [ ] Dashboard (peekpeak.app) shows the job, executions, treasury accrual.

## 6. Mainnet gate

- [ ] OVERHEAD_BUFFER calibration report from Fuji receipts (Q-6): compare
      `gasUsed` vs transaction receipts' actual gas; adjust + redeploy if the
      35,000 default over/under-charges.
- [ ] External audit recommended before mainnet escrows.
- [ ] Registry address recorded; frontend chains updated; executor hot wallet
      capped at 5 AVAX.
