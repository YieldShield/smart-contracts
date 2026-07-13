# YieldShield July 13 Security Remediation Record

## Outcome

This remediation implements the actionable findings from
`MULTI_AGENT_REVIEW_2026_07_13.md`, rechecks the proposed fixes with independent
review agents, and records the remaining external release constraints. No confirmed
Critical or High-severity vulnerability was present at the reviewed baseline.

The work addresses all three Medium, all seven Low, and all four Informational
findings in the July 13 report. It also closes two concrete Low-severity gaps found by
the adversarial post-fix review: raw Robinhood broadcast artifacts bypassing manifest
quarantine, and a retirement deadlock when an expired commission cannot be paid to
its current owner. Final verification also found and corrected a test-handler model
gap for backing-token amounts whose USD value truncates to zero; production behavior
was already fail-closed. The first exact-SHA CI run then exposed live-fork environment
leakage from the generated `.env`; an explicit fork-test opt-in now keeps ordinary and
coverage runs hermetic while preserving mock-based tests located in a fork test file.

Robinhood mainnet deployment remains intentionally blocked until a documented
sequencer-uptime feed address and independently reviewed runtime hash are available.
The repository does not invent an address or reuse the feed of another Arbitrum
chain.

## Method and plan double-check

The implementation plan was challenged before editing by independent agents covering
contract/accounting behavior, oracle/deployment behavior, and tests/CI. The primary
review then re-read each patch before committing it. After the first remediation
wave, a separate adversarial agent tried to break the committed fixes and found the
two additional Low-severity issues described above. Two agents independently
diagnosed the later invariant-model discrepancy before the correction was committed.

The implementation order was:

1. Preserve same-asset exit liveness without relaxing openings or cross-asset value
   decisions.
2. Make public deployment promotion finalized-state and multi-RPC aware.
3. Require reviewed runtime commitments for the complete production core.
4. Close each lower-severity contract, deployment, recovery, CI, and monitoring gap
   in a separate commit.
5. Adversarially re-review the result, remediate any regression separately, then run
   the complete local and remote verification gates.

## Finding-to-fix map

| Finding                                             | Resolution                                                                                                                                                                                                                                                           | Commit               |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| M-01 closed-session exit liveness                   | Added a seven-day, market-closed, corporate-unpaused price capability used only for same-asset full/partial exits and fee settlement. Openings and cross-asset exits keep strict freshness. Dual-feed challenge and deviation policy remains enforced.               | `192d1db`            |
| M-02 pre-finality manifest promotion                | Promotion now resolves the explicit `finalized` block on two distinct-host RPCs, requires exact block/receipt agreement, and re-reads code and live wiring at that numeric block before persisting finality evidence.                                                | `b50a90a`            |
| M-03 incomplete runtime attestation                 | Added exhaustive, mode-specific reviewed pins for the factory proxy and implementation, pool implementation, YS token, timelock, exact immutable-patched governor runtime, composite oracle, ERC-4626 oracle, and selected Pyth/Chainlink path.                      | `5f2584a`            |
| L-01 legacy Robinhood deployment                    | Removed the pre-hardening active-looking `46630` manifest, archived its provenance, and made active Robinhood manifests schema-v2/evidence-gated.                                                                                                                    | `237276a`            |
| L-02 recapitalization oracle coupling               | Empty-pool backing recapitalization no longer depends on an unrelated shielded-token oracle.                                                                                                                                                                         | `6e8cda3`            |
| L-03 commission confiscation                        | Governance can no longer forfeit another owner's commission. A post-fix retirement-only owner escrow separately resolves transfer-blocked expired commissions without redirecting ownership.                                                                         | `405b811`, `7ff715e` |
| L-04 creation-bond return liveness                  | Pool creators can redirect their own bond return without changing ownership of the claim.                                                                                                                                                                            | `778967e`            |
| L-05 Chainlink deployment allowlist                 | Chainlink-native recovery is restricted to Robinhood mainnet/testnet.                                                                                                                                                                                                | `c5b9579`            |
| L-06 independent fork assurance                     | Ethereum mainnet, Sepolia, and Robinhood mainnet suites are independently gated; Robinhood uses the official public RPC fallback and canonical token/feed registry smoke checks. Deployed-protocol sequencer coverage remains externally blocked as described below. | `117b801`            |
| L-07 production coverage                            | CI now enforces aggregate and critical-contract line/branch floors and fails closed for missing or malformed LCOV.                                                                                                                                                   | `1816175`            |
| I-01 Chainlink health mismatch                      | `isPriceStale` now mirrors the protected read's effective max-age policy.                                                                                                                                                                                            | `8305950`            |
| I-02 invariant effectiveness                        | The randomized invariant profile must reach the intended handler paths and rejects framework-level reverts.                                                                                                                                                          | `6baeee9`            |
| I-03 deployment-size scope                          | CI enforces the exact Robinhood production deployment target inventory and its reviewed size ceilings.                                                                                                                                                               | `fca5616`            |
| I-04 recovery metadata                              | Same-generation recovery retains freshly validated mutable evidence instead of restoring stale validation state.                                                                                                                                                     | `460f667`            |
| July 11 B-1                                         | Dual feeds must enforce corporate-action pause capability symmetrically.                                                                                                                                                                                             | `b7081c2`            |
| July 11 B-2                                         | Protection-opening policy is aggregated across configured feeds instead of being bypassable through feed ordering.                                                                                                                                                   | `8e67c4b`            |
| TWAP monitoring carry-forward                       | TWAP health reporting now mirrors protected zero-normalization failures.                                                                                                                                                                                             | `545d812`            |
| Adversarial: raw-broadcast quarantine bypass        | Robinhood broadcasts are excluded without a promoted manifest and constrained to exact manifest name/address pairs before ABI/Ponder consumption.                                                                                                                    | `1b48484`            |
| Adversarial: expired commission retirement deadlock | A permissionless retirement-only escrow moves the exact expired commission to a contract with an immutable owner beneficiary; governance cannot claim or redirect it.                                                                                                | `7ff715e`            |
| Verification: zero-value protector deposit model    | The randomized handler now skips positive backing-token amounts whose USD value truncates to zero, matching the production deposit guard and preventing false modeled-valid paths.                                                                                   | `f73dfc9`            |
| Reviewed remediation size ceilings                  | The tracked Pool and Factory ceilings were advanced to the exact post-remediation artifacts, with an explicit module-split requirement before further growth.                                                                                                        | `e74298d`            |
| Sequencer input attestation                         | Mainnet sequencer input gains an exact reviewed runtime pin plus finalized dual-RPC code/wiring evidence; testnet's explicit exception remains scoped to `46630`.                                                                                                    | `8b176a9`            |
| Post-push CI: implicit live-fork activation         | RPC values copied from `.env.example` can no longer activate live fork tests by themselves. Dedicated fork commands explicitly opt in and remain fail-closed when their required RPC is unavailable.                                                                 | `7314a1f`            |

## Deliberate constraints and external blocker

- Chainlink's current L2 sequencer-uptime registry does not publish a Robinhood Chain
  proxy. Mainnet deployment therefore remains blocked until a documented address,
  public provenance, and independently reviewed runtime hash are supplied.
- The mandatory Robinhood fork suite is a canonical registry/integration smoke test,
  not proof of a promoted YieldShield deployment. A current-deployment selector suite
  becomes mandatory once an authorized finalized manifest exists.
- ERC-4626 `previewRedeem` deviation remains a deliberate fail-closed vault-admission
  constraint; weakening it would trade availability for a price-manipulation risk.
- Pyth EMA and Uniswap V3 TWAP feeds remain intentionally unavailable as direct
  `CompositeOracle` legs until they implement the protocol's strict protected-price
  capability contract.
- `SplitRiskPool` has 501 bytes of standard EIP-3860 initcode headroom after the
  remediation. Any further growth requires a module split and an explicit size-policy
  review; the existing Robinhood deployment-size exception remains target-specific.

## Verification

Local verification on the final code state completed successfully:

- formatting, Prettier, `git diff --check`, Foundry lock consistency, a clean offline
  build, and both storage-layout baselines;
- 117 JavaScript deployment/tooling tests;
- 1,148 Foundry tests passed, zero failed, and five fork-gated tests skipped in the
  ordinary offline suite;
- the isolated invariant-reachability profile passed 18 tests over 4,096 calls with
  zero reverts under the reproducing seed after the model correction;
- production LCOV passed for 29 contracts at 86.50% line coverage and 55.72% branch
  coverage; the instrumented run passed 1,138 tests with zero failures;
- tracked Pool/Factory size ceilings and all 16 exact Robinhood deployment-target
  limits passed. `SplitRiskPool` is 48,384 bytes runtime and 48,651 bytes initcode;
- Slither analyzed 157 contracts with 74 detectors and passed the `--fail-high` gate;
- `npm audit --omit=dev --audit-level=high` reported zero vulnerabilities; and
- the mandatory Robinhood mainnet canonical stock/feed fork smoke test passed 1/1
  against the official public RPC.

The first pushed run, GitHub Actions `29237567663`, correctly caught an unauthenticated
template Robinhood RPC being consumed by the ordinary and coverage jobs after
`npm ci` copied `.env.example` to `.env`. All unrelated jobs passed, including the
dedicated Robinhood fork smoke and both Slither gates. The follow-up guard was tested
in both directions: an unenabled dead RPC skipped without a connection attempt, the
same required and enabled RPC failed closed, and the enabled official Robinhood smoke
passed. The succeeding exact-final-SHA run is reported in the repository handoff.

The exact final pushed SHA and remote CI run identifiers are reported with the
repository handoff after the documentation commit itself completes those checks.

## Primary external sources refreshed on July 13

- Chainlink, [Robinhood tokenized equities](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
- Chainlink, [L2 sequencer uptime feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds)
- Robinhood Chain, [connecting and official RPC endpoints](https://docs.robinhood.com/chain/connecting/)
- Robinhood Chain, [canonical token contracts](https://docs.robinhood.com/chain/contracts/)
- ethers v6, [provider and receipt APIs](https://docs.ethers.org/v6/single-page/)
