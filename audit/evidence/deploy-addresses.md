# Deployment Addresses (verified evidence)

> Generated 2026-09-25 during the audit verification pass, from
> `peekpeak/contracts/broadcast/` artifacts. These corroborate the
> `docs/fuji-golive.md` runbook claims.

## Fuji (chainId 43113)

| Item | Value | Source |
|------|-------|--------|
| PeekRegistry | `0xad7653a934625858c33864e568e08ebdf7a04664` | `broadcast/DeployRegistry.s.sol/43113/run-latest.json` |
| Deploy tx | `0xe03dad92192dac6893bc3a3d1feba20788fdbd76ac7f203b01d11d4096d8978c` | same |
| Deployer / Owner / Treasury (EOA pilot) | `0x9d4e138CBfc038E6e2B92bE4E97925189f687d71` | same + `docs/fuji-golive.md` |
| Executor | `0xc753d1def519423b018644d63362b3f0ee4e8f53` | `docs/fuji-golive.md` (keystore `peekpeak-executor`) |
| OVERHEAD_BUFFER (live) | 35,000 | runbook; mainnet MUST use 50,000 (`docs/gas-anomaly.md`, Q-6) |
| keeperTip | 0.005 AVAX (`5000000000000000` wei) | runbook Step 3 |

Localnet (31337) rehearsal runs also present in `broadcast/` (7 deploy runs,
7 register runs) — rehearse.sh artifacts, not production.

## Important note on the Fuji registry vs the remediated code

The Fuji registry is **immutable and predates the audit remediations**
(F-1..F-5 code changes). It retains the two Low-severity findings on-chain
(testnet-only exposure; both require a malicious/buggy target, and the F-2
vector costs only the operator's own executor wallet). The **mainnet
deployment MUST be built from the remediated source** — see
`AUDIT-VERIFICATION.md` sign-off conditions.

## CoveragePool

Not deployed (Tier-2 C-Chain component, ships with the L1 rollout per
`docs/l1-economics.md`).

## Mainnet (chainId 43114) — deployed 2026-11-09, registry of record

| Item | Value |
|------|-------|
| PeekRegistry (FINAL) | `0x5d873059A9Dca265043728862Cf5a5e01741B0f3` |
| Deploy tx / block | `0xe94239ecb1901cf0c33cf9b612166225d2c302b7964049604ccb0178dc33c659` / `99881520` |
| Source | `main` @ `0a2ab28` (audit-alignment, HACVSP stages 1–14 GO) |
| Compiler / settings | solc **0.8.38**, prague, via-ir, optimizer 200 (proven from on-chain CBOR metadata + length fingerprint) |
| Owner / Treasury | Safe `0x23c74e033C1FB94A87c6A495bF8b741521aA9953` (2-of-3) — verified on-chain |
| keeperTip / OVERHEAD_BUFFER | 0.005 AVAX (`5e15`) / `50000` — verified on-chain |
| Executor (authorized) | `0xB52cd91826d33E69Ee7985eA3e422896963641a3` — verified on-chain |

Artifact-identity limitation (owner-ruled, see AUDIT-VERIFICATION.md §6.4):
deployed runtime differs from the hermetic stage-2 artifact by
source-layout-induced codegen (Remix-compiled repo sources); compiler,
codegen profile, and constructor state are proven identical; source
equivalence is deployer-attested.

### Superseded / voided mainnet deployments

| Address | Disposition |
|---------|-------------|
| `0x43Db684b8fb6903e2b954fB003FB029a402322D0` | **VOID** — solc 0.8.34 (not the audited build family); executor auth to be revoked + paused via Safe. No escrow/jobs. |
| `0xb012fe01cd851c454bd5c7d20c3e3e3f98b4643d` | Superseded — 2026-10-22 registry (solc 0.8.37, pre-audit-alignment source); 3 soak executions paid exact tips; dry-run escrow owner-withdrawable; optional pause. |
