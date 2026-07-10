# YieldShield Smart-Contract Remediation Plan — July 10, 2026

## Objective

Close every open finding in `MULTI_AGENT_REVIEW_2026_07_10.md` with an independently
revertible commit, focused regression tests, and a final repeat of the complete
verification and security-analysis matrix before `main` is pushed.

This plan was challenged by three independent reviewers covering core protocol
behavior, deployment integrity, and tooling/supply-chain controls. The primary agent
then rechecked the proposed boundaries against the current code at `2778099`.

## Plan corrections produced by the challenge

1. Market-session controls must gate only the opening of new shielded stock
   positions. Price reads, valuation, fee settlement, and both withdrawal modes must
   remain available while the reference market is closed.
2. A Foundry runner-size override is safe only when every contract instantiated by
   the production script is independently checked against Robinhood's target runtime
   and initcode limits.
3. Exact demo counts do not make deployment recovery generation-safe. A candidate
   manifest may become active only after the completed broadcast and its on-chain
   results have been validated; active manifests must never be assembled by merging
   old addresses into a new run.
4. A numerical pool cap is not sufficient unless worst-case governance scans are
   measured under that cap. The token whitelist needs a bound as well because it has
   an independent linear scan.
5. The new authenticated Pyth endpoint and upgraded Pyth contract address are one
   compatibility generation. The updater must not fetch from one generation for a
   contract from the other.
6. Scanner suppressions must remain source-local and backed by callback/reentrancy
   regression tests. New detector families will not be globally disabled.

## Commit-by-commit remediation

### Medium findings

#### M-01 — Gate new stock protection by an explicit market calendar

Commit: `Gate stock protection openings by market sessions`

- Add a timelock-owned US-equities session gate with explicit UTC open/close
  intervals. Missing days, holidays, invalid intervals, and a paused gate are closed
  by default; a pause-only guardian can react to unscheduled halts.
- Make `RobinhoodStockOracleFeed` advertise protection-opening eligibility without
  blocking any price getter.
- Have `CompositeOracle` expose the primary stock feed's opening eligibility even
  while its backup price is active.
- Check eligibility in `SplitRiskPool.depositShieldedAsset` before token transfer and
  before `valueAtDeposit` is fixed. Do not apply the check to withdrawals or routine
  valuation.
- Deploy, record, configure, and transfer the session gate to the timelock in the
  production script.
- Test closed-but-fresh prices, weekends, holidays, early close, an absent schedule,
  gate-call failure, emergency pause, backup-active pricing, and exits while closed.

Residual operational boundary: an explicit calendar must be maintained and the
guardian must monitor unscheduled halts. An empty or stale calendar fails closed for
new stock protection.

#### M-02 — Separate runner-size handling from target-size enforcement

Commit: `Fix Robinhood deployment runner size handling`

- Pass Foundry's runner-only code-size override for both Robinhood chain IDs in both
  strict and relaxed modes; do not apply it to Ethereum-limit networks.
- Add a pre-broadcast inventory check covering every production-script `new` target
  against Robinhood's 96 KiB runtime and 192 KiB initcode limits.
- Fail when the source inventory and size-check inventory drift.
- Test strict/mainnet flags, non-Robinhood behavior, size boundaries, and inventory
  completeness; document the runner/target distinction.

#### M-03 — Promote only complete, generation-scoped deployment manifests

Commit: `Make production deployment manifests generation safe`

- Assign every production attempt a deployment ID and write simulation output only
  to a generation-scoped candidate.
- Stop the public exporter from preserving arbitrary prior production entries.
- After a successful broadcast, validate chain ID, deployer, completed receipts,
  code/codehashes, proxy/factory/oracle/governance wiring, and the exact configured
  inventory and digest before atomically promoting an active manifest.
- Record YS token, timelock, governor, every core contract, and every requested demo
  token/feed/pool. For the standard fixture, verify exactly ten tokens, ten feeds, and
  nine pools by identity rather than non-empty counts.
- Preserve immutable generation history. Recovery may resume the same broadcast
  generation; it may not merge addresses from a different generation.
- Test partial receipts, wrong chain/deployer, missing code/entries, configuration
  mismatch, stale-name exclusion, atomic promotion, and preservation of the previous
  active manifest on every validation failure.

Residual operational boundary: an old partial deployment without complete original
receipt/configuration evidence cannot be safely auto-promoted and must remain
quarantined for explicit forensic reconstruction.

#### M-04 — Complete Pyth's authenticated Hermes migration

Commit: `Add authenticated Pyth Hermes migration support`

- Require a nonblank `PYTH_API_KEY`, support `PYTH_HERMES_URL`, never log the key,
  and centralize construction of both Hermes clients with `accessToken`.
- Default new Arbitrum deployments to Pyth's upgraded contracts and the Douro Labs
  endpoint. Detect legacy contracts and use the compatible authenticated legacy
  endpoint unless the operator supplies an explicit compatible override.
- Keep endpoint and contract generation validation together so an unverifiable
  payload cannot be submitted.
- Test missing/blank keys, URL selection, both fetch paths, secret redaction, and the
  official upgraded Arbitrum One and Arbitrum Sepolia addresses without live secrets.
- Document the cutover and legacy auto-upgrade path.

Residual operational boundary: a real updater smoke test requires an operator-owned
Pyth API key.

#### M-05 — Make project contract-size ceilings enforceable

Commit: `Enforce tracked contract size budgets`

- Separate standard EIP-170/EIP-3860 portability results from repository-owned
  regression budgets.
- Permit standard-limit reporting only for explicitly excepted Robinhood targets,
  while tracked runtime/initcode ceilings always fail, including in report-only CI.
- Start ceilings at the reproducible current artifacts so any growth requires an
  explicit reviewed budget change and reductions create permanent headroom.
- Unit-test report-only standard violations, hard tracked violations, equality, and
  ordinary non-excepted failures.

Residual architectural debt: this stops silent growth but does not make the current
pool and factory portable to EIP-170 networks.

#### M-06 — Make the sequencer exception testnet-only

Commit: `Require a sequencer feed on Robinhood mainnet`

- Restrict the missing-feed exception to chain ID 46630 in both JavaScript preflight
  and Solidity deployment logic.
- Require Robinhood mainnet to supply a code-bearing, interface-probed uptime feed
  plus provenance metadata; no shared testnet flag may disable the guard.
- Test mainnet with a reused opt-out, valid and malformed feeds, relaxed testnet,
  strict testnet, and manifest provenance.

Residual operational boundary: because no canonical Robinhood mainnet uptime-feed
address has been verified, mainnet stock-pool activation must remain blocked until an
address and source are explicitly pinned.

### Low findings

#### L-01 — Preserve proposal reachability after burns

Commit: `Preserve proposal reachability after governance token burns`

- Couple the token's irreducible supply floor to the governor's maximum proposal
  threshold through one shared governance constant.
- Keep total supply strictly greater than every permitted proposal threshold.
- Execute a stateful governance test that raises the threshold to its maximum, burns
  toward the floor, rejects the next burn, and proves an adequately delegated holder
  can still propose.

This preserves numerical reachability; governance may still choose a fragmented vote
distribution, which is a participation risk rather than a contract deadlock.

#### L-02 — Bound every factory governance scan

Commit: `Bound factory governance scans`

- Enforce conservative hard ceilings for both active pools and whitelisted tokens.
- Reject setter/add-token operations above those ceilings and reject reductions below
  current use.
- Benchmark all scan-heavy governance paths at the supported maxima with explicit gas
  margins. Lower the ceilings or replace scans with reverse indexes/batching if the
  benchmark is not safe.
- Update legacy-zero behavior and existing tests that currently permit a 1,500-pool
  cap.

#### L-03 — Make invariant calls prove path effectiveness

Commit: `Make pool invariants path effective`

- Track attempts, precondition skips, successes, and unexpected reverts by handler
  family; generate inputs from current balances, TVL, collateral headroom, and live
  receipt IDs.
- Replace the unsigned non-negative tautology with ghost-state monotonicity for
  `rewardPerShareAccumulated`.
- Fail `afterInvariant` when important deposit, exit, price, fee, and reward families
  did not execute or when a modeled-valid action unexpectedly reverted.
- Enable invariant metrics and add a smaller targeted strict suite with
  `fail_on_revert = true`.

#### L-04 — Use the documented Robinhood provider variable

Commit: `Wire Robinhood RPC aliases through provider environment variables`

- Make the production `robinhoodTestnet` Foundry alias interpolate
  `ROBINHOOD_TESTNET_RPC_URL`.
- Keep the public rate-limited URL under an explicit development-only alias and mirror
  mainnet provider configuration consistently.
- Test that production aliases are environment-backed and distinct from public
  fallbacks.

#### L-05 — Add expiring demo-feed health and refresh controls

Commit: `Add Robinhood demo feed health and refresh tooling`

- Mark mock-backed promoted manifests with fixture identity, max age, and expiry.
- Add a chain-46630-only health/refresh path that resolves exactly the promoted ten
  mocks, verifies runtime codehash and ownership, and refreshes timestamps only through
  an explicit synthetic-fixture command.
- Never increase price max age or label fixed mock answers as live market data.
- Test stale detection, authorized refresh, answer preservation/update, wrong chain,
  wrong owner/codehash, and incomplete inventory.

Residual operational boundary: refreshing the checked-in live fixture requires its
current owner key or an ownership migration.

#### L-06 — Make demo seeding explicitly opt-in

Commit: `Make Robinhood demo seeding explicitly opt in`

- Default demo seeding to false in every mode and permit explicit enablement only on
  chain ID 46630.
- Print a nonsecret preflight mode summary and snapshot the choice into the generation
  candidate so recovery does not depend on a later shell environment.
- Test absent/true/false values in strict and relaxed modes and reject mainnet seeding.

#### L-07 — Upgrade and baseline the blocking Slither gate

Commit: `Upgrade the blocking Slither gate to 0.11.5`

- Pin both Slither jobs to 0.11.5 and keep all detector families enabled.
- Add callback/reentrancy tests around receipt mints and the shielded-token transfer
  integrity round trip.
- Add only source-local `reentrancy-balance` suppressions for exact reviewed paths;
  leave Pyth detector output visible in report artifacts.
- Require the exact no-exclusion `--fail-high` command and full tests to pass.

### Informational findings

#### I-01 — Clarify guarded fallback semantics

Commit: `Clarify guarded oracle fallback semantics`

- State in interface and implementation NatSpec that fallback never serves a
  disputed, disabled, or unverifiable feed and that policy rejection can return the
  same failure tuple as total outage.
- Retain the existing ABI and fail-closed behavior; test the documented cases.

#### I-02 — Remove dead oracle helpers

Commit: `Remove dead oracle helpers`

- Remove `SplitRiskPool._tryGetProtectedBackingValue` and
  `CompositeOracle._calculateFeedDeviation`.
- Remove stale comments that imply either helper is an active defense and verify no
  references remain.

#### I-03 — Pin GitHub Actions immutably

Commit: `Pin GitHub Actions to immutable commits`

- Replace every workflow action tag with its verified full commit SHA and retain an
  inline version comment.
- Keep weekly GitHub Actions Dependabot updates so immutable pins still receive
  reviewed upgrades.
- Validate workflow syntax and recheck each official tag-to-SHA mapping before commit.

#### I-04 — Correct review finding totals

Commit: `Correct July 4 review finding totals`

- Correct the July 4 severity table and unique total from 18 to the 17 enumerated IDs.
- Correct the July 10 executive-summary Low count and mark this accounting issue
  resolved without changing finding IDs or rewriting history.

## Completion record

All 17 findings in `MULTI_AGENT_REVIEW_2026_07_10.md` are implemented in separately
revertible commits. Follow-up commits discovered by the final verification campaign
remain separate rather than being folded into their parent fixes.

| Finding | Fix commit(s)                                                                              |
| ------- | ------------------------------------------------------------------------------------------ |
| M-01    | `ff5e2a1`, with operational guardian enforcement and live manifest validation in `d243b04` |
| M-02    | `1b171fc`                                                                                  |
| M-03    | `56ef91d`, with live creation-receipt provenance enforcement in `efe4553`                  |
| M-04    | `b1d7c60`                                                                                  |
| M-05    | `6b2438f`                                                                                  |
| M-06    | `2b4c878`                                                                                  |
| L-01    | `57bd257`                                                                                  |
| L-02    | `ba86627`, with coverage-instrumentation isolation in `0c0d6d6`                            |
| L-03    | `05ed188`, with broad-seed precondition corrections in `c7c9971`, `342934d`, and `fc77e5e` |
| L-04    | `727c6e0`                                                                                  |
| L-05    | `53b1072`, with atomic manifest metadata integration in `56ef91d`                          |
| L-06    | `dd03a60`                                                                                  |
| L-07    | `ddd21a8`, with deterministic calendar annotation `8e78ef8`                                |
| I-01    | `e016d4e`                                                                                  |
| I-02    | `8038928`                                                                                  |
| I-03    | `93fb9ae`                                                                                  |
| I-04    | `a48ab84`                                                                                  |

Final local verification on July 10, 2026:

- Solidity and JavaScript formatting passed; all 83 script tests passed, including
  16 generation-safe manifest finalizer tests and 17 deployment-preflight tests.
- `foundry.lock` matched all four submodule revisions.
- The full offline Foundry build, storage-layout snapshots, and full offline test suite
  passed.
- The strict 32-run/64-depth fail-on-revert invariant suite passed. A full
  256-run/500-depth campaign passed with the recorded regression seed, and the full
  suite passed again with fresh seeds. The first pushed CI campaign exposed one more
  modeled-validity gap after repeated oracle price drops; `fc77e5e` added an explicit
  zero-USD deposit regression and the fresh broad campaign passed afterward.
- Instrumented coverage excludes only `FactoryLinearScanGas.t.sol`, because coverage
  probes invalidate its gas measurements. The normal Foundry gate still runs the
  suite and enforces the 15M hard-cap benchmarks; a workflow policy test locks this
  separation in place.
- Production guardian tests proved that the configured nonzero guardian is distinct
  from the timelock, survives finalization and recovery, can pause immediately, and
  cannot unpause or change the calendar. Active manifest promotion independently
  re-read the live guardian and rejected any metadata/wiring mismatch.
- Deployment address provenance was bound to live successful CREATE receipts;
  forged `additionalContracts` entries and CALL targets were rejected as creation
  evidence.
- Tracked size ceilings passed at 45,988/46,255 bytes for `SplitRiskPool` and
  41,258/41,525 bytes for `SplitRiskPoolFactory`; all 16 production deployment
  targets passed Robinhood's runtime/initcode limits.
- Slither 0.11.5 analyzed 154 contracts with 74 detector families and the exact
  no-exclusion `--fail-high` gate exited zero. Medium and Pyth-specific results remain
  visible in reporting rather than being globally excluded.
- Aderyn completed all 88 detectors and generated its report. Aderyn remains a
  report-only CI signal; its broad heuristic findings were not converted into silent
  global exclusions.

Residual boundaries requiring external operator material remain unchanged: a real
Pyth updater smoke test needs an API key; Robinhood mainnet stock protection needs a
verified sequencer-feed address and provenance; refreshing the checked-in synthetic
testnet feeds needs their owner keystore; and the pool/factory remain intentionally
non-portable to standard EIP-170 networks while their Robinhood size budgets are
enforced.

## Verification and delivery gates

Each finding receives its focused tests plus formatting/build checks before its own
commit. After all commits, run in this order:

1. `forge fmt --check`
2. Prettier for JavaScript and JSON tooling
3. `npm run test:scripts`
4. `npm run check:foundry-lock`
5. `forge build --offline`
6. storage-layout verification
7. `npm run size-check`
8. the strict and broad invariant suites
9. `forge test --offline`
10. Slither 0.11.5 reporting and the exact blocking `--fail-high` command
11. Aderyn reporting
12. a final diff review and repeat multi-agent challenge for regressions

Only then push the accumulated, separately revertible commits to `main`. The remote
GitHub Actions run is the final gate; delivery is not complete until every required
job is green or an honestly documented external-secret-only job is skipped by its
designed guard.
