# KONTROL_VACUITY.md — non-vacuity rationale per proof (stage 12)

Proved corpus: `contracts/test/proofs/{PeekRegistryProofs,CoveragePoolProofs}.t.sol`

| Proof | Symbolic vars | Unconstrained? | Non-trivial coverage rationale |
|---|---|---|---|
| test_Proof_DepositGas_ExactAccounting | v (uint128, bounded to escrow domain) | v free within (0, max-before_] | both overflow/no-overflow boundary arms exercised via bound |
| test_Proof_WithdrawGas_OwnerOnly_AndExact | amount (<= balance) | amount free; attacker address literal | revert arm + success arm both asserted |
| test_Proof_Pause_BlocksRegistration | target, gasLimit, ceiling | all free within ctor-valid ranges | every payload blocked — no over-constraining reverts first |
| test_Proof_RegisterJob_ExactInitialEscrow | value (uint96, >= min escrow) | free incl. the equal-target edge | same-owner double registration covered |
| test_Proof_WithdrawGas_OverBalance_FailsAndPreserves | boundary (balance+1) | free above balance | checked-subtraction bound |
| test_Proof_UnsponsoredChains_NeverCovered | none (concrete unpriced set) | free | fail-closed default state |
| test_Proof_Sponsorship_InTermExtension_Compounds | none (both arms concrete) | free above minimum | extension monotonicity across the floor boundary |
| test_Proof_NoCustody_AfterSponsorship | deposit (0.1–10 eth) | free in range | treasury forwarding exhaustiveness |
| test_Proof_Reprice_OwnerOnly | newPrice (any uint256) | fully free | access gate independent of payload |

Full-domain caveat: uint256-wide symbolic args on sponsor()/registerJob() are
bounded by ETH-supply pragmatics (vm.deal bounds); documented for stage-13
ratification.


## Delegations (SMT-intractable under hevm; tracked for Kontrol/fuzz)

- **keccak job-id injectivity** (two registrations never collide): requires
  symbolic-keccak distinctness — delegated to concrete fuzz (1000-run corpus)
  + unit test_Kill114 (third-registration collision).
- **Fully-symbolic chainId fail-closed**: symbolic mapping-slot reasoning —
  concrete unpriced set proved; universal form for Kontrol.
- **Full-range over-balance failure**: boundary (+1 wei) proved; interior
  covered by 1000-run fuzz.

coverage: tool-unavailable — kontrol 1.0.255 exposes no CLI coverage metric
(view-coverage does not exist in this version). Non-vacuity is enforced by the
per-rule table above plus the hevm cross-proof of the same properties (stage 11).
