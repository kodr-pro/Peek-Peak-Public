# PeekPeak

> **Peek the state. Poke the peak.**
> Contracts that run themselves - native automated execution for Avalanche C-Chain and L1s.

[peekpeak.app](https://peekpeak.app) · [Start](https://peekpeak.app/start) · [Docs](https://peekpeak.app/docs)

PeekPeak watches your contract's `checkJob()` on every block (free, off-chain),
verifies the execution would succeed, then calls `performJob()` on-chain through
an authorized executor. Escrow pays exactly the gas used plus a flat
**0.005 AVAX** tip. No token, no subscription, no markup. Reverting jobs cost
nothing. Your escrow is withdrawable at any time.

```solidity
interface IAutoJob {
    function checkJob() external view returns (bool canExec, bytes memory execPayload);
    function performJob(bytes calldata execPayload) external;
}
```

Two functions is the entire integration. The full walkthrough (with
paste-runnable commands against the live registry) is at
[peekpeak.app/start](https://peekpeak.app/start).

## What's in this repository

| Path | What it is |
|---|---|
| [`audit/`](audit/) | **The complete security audit** - findings, remediation verification, formal proofs, the 14-stage release-gate ledger, and the cryptographic signatures over the attestation bundle. Start at [`audit/README.md`](audit/README.md). |
| [`contracts/src/`](contracts/src/) | Live sources: `PeekRegistry`, `CoveragePool`, `IAutoJob`, `DemoHeartbeat`. |
| [`contracts/src/adapters/`](contracts/src/adapters/) | **Ready-made chore examples** - `HarvestKeeper` (Compound/Sushi harvests) and `PharaohEpochKeeper` (epoch rollups), battle-shaped reference integrations you can copy. |
| [`contracts/test/`](contracts/test/) | The full Foundry suite the audit ran against - unit, invariant, mutation-kill, and formal proof tests (`test/proofs/`). |
| [`agents/SKILL.md`](agents/SKILL.md) | The zero-config rulefile that lets AI agents (Cursor, Claude) implement the integration for you. |

Protocol docs live at [peekpeak.app/docs](https://peekpeak.app/docs).
The production daemon and deployment configuration are private.

## The audit

The protocol carries a first-party audit trail end to end:

1. **Original audit** (2026-09-25) - [`audit/AUDIT-REPORT.md`](audit/AUDIT-REPORT.md):
   2 Low + 6 Informational findings across `PeekRegistry` and `CoveragePool`,
   each with a working PoC.
2. **Remediation + sign-off** (2026-09-25) - [`audit/AUDIT-VERIFICATION.md`](audit/AUDIT-VERIFICATION.md):
   every fix verified, regression-locked, and cleared for mainnet - including
   the [2026-11-09 deployment record](audit/AUDIT-VERIFICATION.md#6-mainnet-deployment-record-2026-11-09).
3. **Release gate** (2026-11-05..07) - [`audit/hacvsp/`](audit/hacvsp/): a 14-stage
   verification cadence over the final sources - supply chain, deterministic
   build, static analysis, access matrix, mutation testing, stateful fuzzing,
   symbolic execution, and EVM-level theorem proving (Kontrol) - **all 14 stages GO**.
4. **Signatures** - the attestation bundle and the manual review sign-off are
   signed with an ed25519 key; verification commands are in
   [`audit/README.md`](audit/README.md#verifying-the-signatures).

## Status

- **Live on Avalanche C-Chain** - registry
  [`0x5d873059A9Dca265043728862Cf5a5e01741B0f3`](https://snowtrace.io/address/0x5d873059A9Dca265043728862Cf5a5e01741B0f3)
  (audited-build v2, deployed 2026-11-09).

## Support & feedback

[Open an issue](https://github.com/kodr-pro/Peek-Peak-Public/issues) - bug
reports, integration questions, feature requests, and L1 onboarding
inquiries all welcome.

## License

MIT.
