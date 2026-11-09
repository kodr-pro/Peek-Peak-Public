# Fuji Go-Live Runbook (Phase B) - execute top to bottom

Rehearsal status: PASSED locally (worker/scripts/rehearse.sh) - the exact
script path, daemon, economics, and health endpoints are verified.

Fixed parameters for this launch (owner decision: Fuji pilot runs an EOA
owner/treasury - no Fuji Safe exists; the mainnet Safe takes over at
mainnet launch, the SEC-16 gate is unchanged):

- Owner / Treasury / Deployer (Fuji pilot, dedicated EOA): `0x9d4e138CBfc038E6e2B92bE4E97925189f687d71`
- Executor: `0xc753d1def519423b018644d63362b3f0ee4e8f53` (keystore
  `peekpeak-executor` created)
- Mainnet (later): Owner/Treasury = Safe `0x23c74e033C1FB94A87c6A495bF8b741521aA9953`,
  fresh executor keystore
- CREATE2 salt (hex "peekpeak" padded; same registry address on mainnet later):
  `0x7065656b7065616b000000000000000000000000000000000000000000000001`
- OVERHEAD_BUFFER: 35000 live on Fuji (delta trivial); future deploys incl. mainnet use 50000 per docs/gas-anomaly.md (Q-6 closed)
- ChainStack mainnet endpoints live in `.secrets` (never committed) - used at
  mainnet launch via PP_RPC_URLS; Fuji pilot uses public gateways.

## Step 1 - fund the two addresses [OWNER]

- Deployer `0x9d4e...7d71`: >= 0.5 AVAX on Fuji (faucet or from your wallet).
- Executor: create fresh (Step 2), then fund 3-5 AVAX.

## Step 2 - create the executor key + encrypted keystore [OWNER]

```bash
cast wallet new          # note the address + private key (never commit)
# fund the printed address from the faucet, then:
cast wallet import peekpeak-executor --private-key 0x<fresh key>
# prompts for a password -> this is PP_SIGNER_PASSWORD
ls ~/.foundry/keystores/peekpeak-executor   # the encrypted keystore file
```

## Step 3 - deploy the registry (CREATE2)

```bash
cd contracts
DEPLOYER_KEY=0x<your deployer key> \
OWNER=0x9d4e138CBfc038E6e2B92bE4E97925189f687d71 \
TREASURY=0x9d4e138CBfc038E6e2B92bE4E97925189f687d71 \
CREATE2_SALT=0x7065656b7065616b000000000000000000000000000000000000000000000001 \
OVERHEAD_BUFFER=35000 \
KEEPER_TIP_WEI=5000000000000000 \
forge script script/DeployRegistry.s.sol \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc --broadcast --verify
```

SEC-14: the executor key is strictly an `authorizedExecutor` - it can never
touch treasury, tips, or job config regardless of who owns the registry.
For THIS pilot the owner/treasury is the EOA above (owner decision; Fuji
has no Safe deployment). At MAINNET the owner/treasury MUST be the Safe
`0x23c74e...9953` - never a personal EOA.
SEC-16: before mainnet liquidity, the mainnet Safe moves to 2-of-3 signers
and the team runs a quarterly owner-action drill (one no-op setter call).

Printed address should match the rehearsal: NOT guaranteed identical (different
chain state), but stable across every future chain with this salt + code.
Record the deployed address as `$REGISTRY`.

## Step 4 - authorize the executor

```bash
cast send --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
  --private-key 0x<deployer key> \
  $REGISTRY "setExecutor(address,bool)" 0xc753d1def519423b018644d63362b3f0ee4e8f53 true
```

## Step 5 - record the address (me)

`deploy/chains/fuji.json` registry field + `frontend/lib/chains.ts`, push ->
Vercel dashboard goes live.

## Step 6 - register the dry-run job (0.2 AVAX escrow)

```bash
DEPLOYER_KEY=0x<deployer key> REGISTRY=$REGISTRY DEPOSIT_WEI=200000000000000000 \
forge script script/RegisterJob.s.sol:DeployMockJob \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc --broadcast
```

## Step 7 - Railway service [OWNER + me]

1. Railway dashboard: New Project -> Deploy from GitHub repo -> select
   PeekPeak, service root `/` (repo root), dockerfilePath `worker/Dockerfile`
   (railway.json applies: single replica, ON_FAILURE restart, /healthz).
2. Attach a volume mounted at `/data`.
3. Upload the keystore: shell into the service (or via Railway CLI) and place
   `~/.foundry/keystores/peekpeak-executor` at `/data/executor.json`
   (or `railway ssh` + base64 paste).
4. Set environment variables:
   - `PP_SIGNER_PASSWORD` = the keystore password
   - `RUST_LOG` = `warn,peekpeakd=info,pp_signer::broadcast=info`
   - optional `PP_MIN_EXECUTOR_BALANCE_WEI` = SEC-12 breaker floor
     (default 100000000000000000 = 0.1 AVAX)
   - the container binds /metrics + /healthz to Railway's `$PORT`
     automatically; the platform healthcheck (railway.json) hits /healthz
   - optional `PP_RPC_URLS` = comma-separated extra Fuji endpoints when you
     add more free tiers (ChainStack Fuji app, dRPC, PublicNode).
   - Do NOT set PP_TEST_EXECUTOR_KEY in production.
5. Deploy; watch logs for `watcher synced` + `standalone consumer` lines.
   Healthcheck: `https://<service>.up.railway.app/healthz` (if a domain is
   attached) or the metrics port.

## Step 8 - arm and verify (SPEC-11)

```bash
RPC=https://api.avax-test.network/ext/bc/C/rpc
# arm 5 times sequentially; after each, watch the daemon execute it
for i in 1 2 3 4 5; do
  cast send --rpc-url $RPC --private-key 0x<deployer key> \
    0x<MockJob address> "setReady(bool)" true
  sleep 6   # next block scan + execution
done
cast logs --rpc-url $RPC --from-block <deploy block> --address $REGISTRY \
  'JobExecuted(bytes32,address,uint256,uint256,uint256)'
```

Verify per event: `keeperTip == 5000000000000000` wei (0.005 AVAX exactly),
escrow decreasing on the dashboard, treasury Safe balance increasing by the
tips.

## Step 9 - resilience checks

- Railway restart (Redeploy): daemon re-syncs jobs from logs and resumes.
- Kill test: `railway ssh` -> `kill 1` -> service restarts (platform-level).
- Buffer calibration (Q-6): compare `gasUsed` in events vs receipt gas used;
  if 35000 is materially off, note for the mainnet deployment (versioned
  redeploy is cheap; Fuji address can stay).

## Rollback

- Pause everything: `cast send $REGISTRY "setPaused(bool)" true` (owner).
- Drain a job: `withdrawGas(jobId, amount)` as job owner.
- Registry is immutable; a bad deployment = new salt, new address, migrate
  escrows (they are per-job and withdrawable by their owners at any time).
