# PeekPeak - Complete Audit Record

This directory is the authoritative, versioned audit record for the PeekPeak
protocol. Everything here is public and self-contained; the signatures are
verifiable offline against the files in this tree.

## Layout

| Path | Contents |
|---|---|
| `AUDIT-REPORT.md` | The original security audit (2026-09-25): 2 Low + 6 Informational findings across `PeekRegistry` and `CoveragePool`, each with a working proof of concept. Line references cite `contracts-frozen/` below. |
| `AUDIT-VERIFICATION.md` | Remediation verification and mainnet sign-off (2026-09-25), plus §6: the [2026-11-09 mainnet deployment record](AUDIT-VERIFICATION.md#6-mainnet-deployment-record-2026-11-09) for the audited-build v2 registry (`0x5d87...B0f3`, block `99881520`). |
| `evidence/` | Test results, coverage output, and verified deployment addresses (Fuji, mainnet v1/v2, the voided miscompile). |
| `docs/` | The audit's working documents: security checklist, divergence register, gas-anomaly analysis, Fuji validation and go-live notes, and the `SKILL.md` snapshot as tested. |
| `contracts-frozen/` | The pre-fix source snapshot the original report cites - frozen on purpose so its line numbers stay valid. **Live sources are the repo's `contracts/src/`.** |
| `hacvsp/` | The 14-stage release-gate cadence over the final sources (2026-11-05..07): `SECURITY_ASSURANCE.md`, the full `GATE_LEDGER.json` (all stages GO), the stage-13 expert review (`review/`), the signed attestation bundle (`artifacts/` + `signatures/`). |

## Timeline

| Date | Event |
|---|---|
| 2026-09-25 | Original audit + remediation verification + mainnet sign-off (deploy-gate conditions in `AUDIT-VERIFICATION.md` §5) |
| 2026-11-05..07 | HACVSP release cadence over the final sources: stages 1-14 all GO, incl. mutation (≥90% kill), stateful fuzzing, SMT/Halmos BMC, Kontrol EVM proofs, expert review, attestation |
| 2026-11-09 | Mainnet deployment of the audited build (registry v2, solc 0.8.38/prague/via-ir/200) - record in `AUDIT-VERIFICATION.md` §6 |

Provenance note: the release-cadence gates ran at engagement-pinned commit
`c8ed234`; that lineage was rebased (author-email normalization) immediately
before merging - content-identical, merged as `59dfd0b` - so ledger commit IDs
predate the merge hashes by one rewrite.

## Verifying the signatures

Both signatures are ed25519 (OpenSSH key format), namespace `hacvsp`, made over
the **sha256 hex digest of the signed file, with trailing newline**. From this
directory:

```bash
cd hacvsp

# 1. every bundle file must match the signed manifest
python3 - <<'EOF'
import json, hashlib, pathlib
m = json.loads(pathlib.Path("artifacts/bundle-manifest.json").read_text())
for rel, want in m["files"].items():
    got = hashlib.sha256(pathlib.Path(rel).read_bytes()).hexdigest()
    assert got == want, f"MISMATCH {rel}"
print("all bundle digests match the signed manifest")
EOF

# 2. verify the bundle attestation (over the manifest file's own sha256)
echo "verifier $(cat signatures/bundle-attestation.pub)" > /tmp/as
echo "$(sha256sum artifacts/bundle-manifest.json | cut -d' ' -f1)" \
  | ssh-keygen -Y verify -f /tmp/as -I verifier -n hacvsp \
      -s signatures/bundle-attestation.sig

# 3. verify the manual review sign-off (over the sign-off file's sha256)
echo "verifier $(cat signatures/manual-signoff.pub)" > /tmp/as
echo "$(sha256sum review/MANUAL_REVIEW_SIGNOFF.md | cut -d' ' -f1)" \
  | ssh-keygen -Y verify -f /tmp/as -I verifier -n hacvsp \
      -s signatures/manual-signoff.sig
```

Expected output for both: `Good "hacvsp" signature ... with ED25519 key
SHA256:UgEQmKQNrUqKEjgk2ktGlEogcRPb9xuI/BeRaPEbt10`.

The signing key's fingerprint is
`SHA256:UgEQmKQNrUqKEjgk2ktGlEogcRPb9xuI/BeRaPEbt10` (comment
`brad.myrick@pm.me`). Any byte-level edit to a manifest-listed file, the
manifest itself, or the sign-off document invalidates the corresponding
signature - that is the point.
