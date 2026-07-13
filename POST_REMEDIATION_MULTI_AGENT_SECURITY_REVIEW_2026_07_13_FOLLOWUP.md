# YieldShield Post-Remediation Multi-Agent Security Review Follow-Up — July 13, 2026

## Executive summary

This follow-up reviewed `main` at
`b8016a8d2c4224f72fc0a37fc317ec579c97d1f8`, after the fixes recorded in
`SECURITY_REMEDIATION_2026_07_13.md`. It found **no confirmed Critical or
High-severity issue**. It confirmed one **Medium**, six **Low**, and one
**Informational** weakness or inconsistency.

The Medium finding is in the permissionless dual-feed recovery path. After a
challenge has established that a primary feed is disputed and activated the backup,
any account can call `revertToPrimary` while the backup is unavailable. The function
skips the primary/backup convergence check in that state, reactivates the previously
disputed primary, and allows protected reads to use it. The repository already has a
test that proves this transition succeeds.

The Low findings concern opt-in Robinhood equity safeguards, an advertised Arbitrum
deployment path that cannot deploy the current oversized Solidity implementations,
a required Arbitrum updater confirmation flag that is absent from CLI preflight and the
environment template, receipt-NFT coverage that can regress without tripping a
per-contract floor, the lack of Arbitrum live-fork coverage, and a nondeterministic
randomized-reachability release gate. The Informational finding records fuzz tests
whose names and assertions overstate the boundary conditions they exercise.

| Severity      | Count | Character                                                   |
| ------------- | ----: | ----------------------------------------------------------- |
| Critical      |     0 | None confirmed                                              |
| High          |     0 | None confirmed                                              |
| Medium        |     1 | Permissionless reactivation of a previously disputed oracle |
| Low           |     6 | Configuration, deployment availability, and assurance gaps  |
| Informational |     1 | Misleading fuzz-test assurance                              |

This is an engineering review, not a guarantee of correctness or a substitute for
an independent professional audit and production launch rehearsal before material
value is deposited.

## Scope and method

- **Baseline:** `b8016a8d2c4224f72fc0a37fc317ec579c97d1f8`, clean and synchronized
  with `origin/main` before review.
- **Scope:** production pool/factory accounting, receipt NFTs, governance,
  Chainlink/Pyth/ERC-4626/TWAP/composite oracles, deployment and manifest tooling,
  chain-specific configuration, Foundry tests and invariants, coverage policy,
  static-analysis policy, and GitHub Actions.
- **Review team:** one primary Codex reviewer and three independent Codex agents.
  The agents separately reviewed core protocol/oracle logic, deployment and live
  integration behavior, and tests/tooling/CI. The primary reviewer reproduced,
  deduplicated, and severity-ranked their candidates against current code and prior
  reports.
- **Deduplication:** all 12 findings closed by
  `SECURITY_REMEDIATION_2026_07_13.md` were treated as historical. Known constraints
  are listed separately and are not counted again as fresh findings.
- **Research:** only primary or first-party technical sources were used. The review
  refreshed Chainlink, Pyth, OpenZeppelin, Solidity, EIP, and Arbitrum guidance on
  July 13, 2026.

## Finding summary

| ID   | Severity      | Finding                                                                                                                  | Status                              |
| ---- | ------------- | ------------------------------------------------------------------------------------------------------------------------ | ----------------------------------- |
| M-01 | Medium        | Permissionless failback can reactivate the disputed primary when the backup is unavailable                               | Confirmed and reproduced            |
| L-01 | Low           | Robinhood equity opening and corporate-action safeguards remain opt-in and are not pinned in the mainnet core deployment | Confirmed configuration weakness    |
| L-02 | Low           | Advertised Arbitrum production aliases cannot deploy the current pool and factory implementations                        | Confirmed deployment inconsistency  |
| L-03 | Low           | Arbitrum One requires a Pyth updater confirmation flag that CLI preflight and documentation omit                         | Confirmed operational inconsistency |
| L-04 | Low           | Receipt NFTs are outside per-contract coverage floors                                                                    | Confirmed assurance gap             |
| L-05 | Low           | Supported Arbitrum oracle paths have no live-fork CI coverage, while existing fork jobs run only after merge             | Confirmed assurance gap             |
| L-06 | Low           | The randomized reachability gate is nondeterministic and emits non-diagnostic counterexamples                            | Confirmed assurance gap             |
| I-01 | Informational | A boundary fuzz test never approaches its named boundary and contains tautological assertions                            | Confirmed test-quality issue        |

## Medium finding

### M-01 — Permissionless failback can reactivate a previously disputed primary

**Affected:** `contracts/oracles/CompositeOracle.sol:637-692,827-855,1072-1098`;
`test/CompositeOracle.t.sol:1347-1389`

`revertToPrimary` is permissionless. It correctly requires the primary feed to be
readable and circuit-breaker capable. However, it compares primary and backup prices
only when the active backup both advertises circuit-breaker support and returns a
price. When the backup is unavailable, `currentDeviation` remains
`type(uint256).max`, but the function still sets `isBackupActive = false`.

That behavior is unsafe after a completed challenge:

1. Primary and backup differ by more than the configured threshold.
2. A permissionless challenge is finalized, recording the primary as the disputed
   leg and activating the backup.
3. The backup later becomes stale or otherwise temporarily unavailable while the
   previously disputed primary still returns a locally valid price.
4. Any caller invokes `revertToPrimary`. Because the backup read failed, the
   convergence check is skipped and the call succeeds.
5. In primary mode, `_hasUnresolvedDualFeedDeviation` treats backup failure as safe
   whenever the primary advertises its own circuit breaker. Protected `getPrice`,
   `getValue`, and equivalent-amount paths therefore resume using the previously
   disputed primary.

The existing regression explicitly proves the unsafe policy:

```text
forge test --offline --match-path test/CompositeOracle.t.sol \
  --match-test test_RevertToPrimary_SucceedsWhenBackupUnavailableAndPrimaryHealthy -vv

[PASS] test_RevertToPrimary_SucceedsWhenBackupUnavailableAndPrimaryHealthy()
```

**Impact:** during a correlated oracle incident, an unprivileged caller can replace a
fail-closed state with a protected price from the feed that the challenge mechanism
had already identified as disputed. If that price is used for deposits, collateral
sizing, or cross-asset settlement, the result can be economic loss. The attack does
not require governance authority; it requires the active backup to be unavailable
while the old primary remains readable.

**Recommendation:** require a successful protected backup read and a deviation at or
below the threshold for permissionless `revertToPrimary`. If the active backup is
unavailable, retain the fail-closed state. Recovery without a comparison should be
possible only through the existing scheduled, owner-controlled
`forceResetToPrimary` path. Change the current backup-unavailable regression to
expect `RevertNotPossible`, and add a state-machine property that a permissionless
transition from backup to primary is possible only after both protected feeds are
readable and converged.

## Low findings

### L-01 — Robinhood equity safeguards are opt-in and absent from the mainnet core inventory

**Affected:** `script/DeployYieldShieldProduction.s.sol:594-640,928-955,1095-1101`;
`scripts-js/finalizeDeploymentManifest.js:37-71`;
`contracts/oracles/CompositeOracle.sol:1667-1689`;
`contracts/SplitRiskPool.sol:564-589`

The Robinhood production path deploys `ChainlinkOracleFeed` and
`USMarketSessionGate` as core components. It deploys `RobinhoodStockOracleFeed` only
inside optional testnet demo seeding. The mainnet manifest inventory and reviewed
codehash pins consequently omit the wrapper.

The opening-policy capability is also opt-in. `CompositeOracle` records the
requirement only when a selected feed already advertises the capability, and the
pool intentionally allows openings when the capability is not required. Governance
can therefore register a Robinhood equity directly against the raw Chainlink
adapter. That configuration bypasses the wrapper's corporate-action pause,
market-session, and opening-specific freshness checks without an on-chain rejection.

**Impact:** this is not an exploit against the empty post-deployment configuration;
later governance must make the unsafe registration. It is nevertheless a security
configuration footgun because the deployment does not provide or pin the component
needed to preserve the remediated equity-opening policy.

**Recommendation:** deploy `RobinhoodStockOracleFeed` as reviewed core
infrastructure on Robinhood mainnet, include it in manifest inventory and codehash
evidence, and make equity token onboarding explicitly require that wrapper. The
requirement should derive from an immutable or governance-reviewed token class, not
from whether the selected feed voluntarily exposes an optional selector.

### L-02 — Advertised Arbitrum aliases cannot deploy the current implementations

**Affected:** `config/deployment-finality-policy.json:16-38`;
`scripts-js/parseArgs.js:247-252,397-400,524-547`;
`scripts-js/contract-size-policy.js:1-16`;
`README.md:176-194`

The deployment policy and documentation advertise `arbitrum` and
`arbitrumSepolia` as accepted production aliases. Chain-aware size preflight and
Foundry's code-size override are deliberately limited to Robinhood, so both
Arbitrum aliases proceed through expensive dual-RPC and finality preflight before
normal EVM creation rejects the current implementations.

The exact current artifacts are:

| Contract               |      Runtime | EIP-170 limit |       Excess |
| ---------------------- | -----------: | ------------: | -----------: |
| `SplitRiskPool`        | 48,302 bytes |  24,576 bytes | 23,726 bytes |
| `SplitRiskPoolFactory` | 41,385 bytes |  24,576 bytes | 16,809 bytes |

The CLI probe confirms the gap:

```text
forgeScriptArgsForNetwork("arbitrum", {}) -> []
requiresDeploymentTargetSizeCheck({
  fileName: "DeployYieldShieldProduction.s.sol",
  network: "arbitrum"
}) -> false
```

EIP-170 sets the 24,576-byte runtime cap. Offchain Labs' current ArbOS 61 proposal
reiterates that its proposed 96 KB expansion is for fragmented Stylus programs, not
Solidity contracts. This finding is distinct from the already-documented size
constraint: the inconsistency is that the repository still advertises a production
path which cannot complete and does not reject it at the first preflight boundary.

**Impact:** deployment availability and operator safety. An operator can satisfy the
documented inputs and costly independent-RPC checks, only to fail during Forge
simulation or broadcast. No live funds are exposed by the failed creation.

**Recommendation:** add a checked-in per-chain size policy and execute it before RPC
construction. Block or remove the two Arbitrum deployment aliases until pool and
factory are split below EIP-170, and add a full Arbitrum fork deployment rehearsal
before re-enabling them. Do not copy Robinhood's relaxed size override to Arbitrum.

### L-03 — Required Arbitrum updater confirmation is missing from preflight and documentation

**Affected:** `script/DeployYieldShieldProduction.s.sol:500-517,1833-1847`;
`scripts-js/parseArgs.js:47-60,197-245`; `.env.example:18-23,52-66`;
`README.md:150-194`

The Solidity production script reads
`YS_PRODUCTION_PYTH_UPDATER_CONFIRMED` and requires it to be true on Arbitrum One.
The CLI's `REQUIRED_PYTH_ENV` contains only the oracle codehash, while the environment
template and production instructions never name the confirmation flag. A direct
probe of `missingProductionEnv` confirms that it does not report the absent value.

**Impact:** an operator following all checked-in instructions can pass CLI input and
dual-RPC validation, then fail late in Forge with
`ProductionPythUpdaterNotConfirmed`. This is a release reliability issue, not a
live-contract exploit. The configured Arbitrum Pyth addresses themselves match
Pyth's currently recommended upgraded contracts.

**Recommendation:** add the flag to CLI preflight, `.env.example`, README, and tests,
and reject it before provider construction. Prefer replacing the bare Boolean with
an authenticated Hermes/update smoke test bound to the exact Pyth address,
chain ID, and deployment configuration digest.

### L-04 — Receipt NFTs are outside per-contract coverage floors

**Affected:** `scripts-js/checkCoverage.js:8-88`;
`contracts/ProtectorReceiptNFT.sol:52-76,139-208`;
`contracts/ShieldReceiptNFT.sol:48-117,155-223`

The per-contract coverage inventory includes 13 critical production contracts but
omits both receipt NFTs. Those contracts enforce one-time pool binding,
pool-authorized mint/burn, transfer and movement locks, timestamp-gated operator
approvals, and lock-window-gated token-specific approvals. They are active security
boundaries, not passive data containers.

The current LCOV record reports 66/77 lines and 13/22 branches for
`ProtectorReceiptNFT`, and 71/75 lines and 14/20 branches for `ShieldReceiptNFT`.
Current coverage is not the problem; the missing regression floor is. Zeroing every
line and branch hit in the protector receipt's LCOV record still passes the policy:

```text
aggregate lines:    4,414 / 5,174 = 85.31%   (floor 85%)
aggregate branches:   689 / 1,248 = 55.21%   (floor 53%)
violations: none
```

**Impact:** future changes can remove all exercised protector-receipt paths without
failing CI, provided aggregate coverage remains just above the global floor. A
regression in mint/burn authorization or transfer locks would therefore lose a
useful release signal.

**Recommendation:** add both receipt contracts to
`SECURITY_CRITICAL_CONTRACTS` and give each reviewed line and branch floors. Keep the
inventory-consistency test, and add mutation-style unit tests proving that a complete
loss of coverage for either receipt fails.

### L-05 — Supported Arbitrum paths have no live-fork CI coverage

**Affected:** `.github/workflows/ci.yml:88-163`;
`test/OracleFork.t.sol:12-47,196-224`;
`contracts/oracles/PythConfig.sol:9-33`;
`config/deployment-finality-policy.json:16-38`

The live fork suite covers Ethereum mainnet, Ethereum Sepolia, and Robinhood
mainnet. Its Pyth test uses the Ethereum Sepolia contract, not either checked-in
Arbitrum Pyth address. There is no Arbitrum mainnet or Sepolia fork that verifies
chain ID, runtime code, or Pyth interface behavior, and no Arbitrum One fork verifies
sequencer feed round semantics.
Moreover, the entire fork job runs only on a push to `main`; even the required
Robinhood public-RPC smoke cannot block a pull request before merge.

The current Pyth and Arbitrum One sequencer addresses match first-party Pyth and
Chainlink documentation, so this is not an address-mismatch finding.

**Impact:** interface, address, or chain integration drift on an advertised
Arbitrum path is not detected at any point by live CI. Robinhood drift is detected
only after the merge reaches `main`.

**Recommendation:** add required Arbitrum One and Arbitrum Sepolia fork smokes for
chain ID, code existence, and Pyth selectors/staleness behavior. On Arbitrum One,
also verify sequencer code and round semantics. Monitor Chainlink's registry for a
future canonical Arbitrum Sepolia sequencer feed and add equivalent checks if one is
published. Run deterministic public-RPC smokes on pull requests; leave only
secret-dependent or rate-sensitive cases in the post-merge job.

### L-06 — The randomized reachability gate is nondeterministic and emits non-diagnostic counterexamples

**Affected:** `.github/workflows/ci.yml:80-84`; `foundry.toml:88-92`;
`test/SplitRiskPoolInvariant.t.sol:548-573,981-1008,1037-1071,1443-1485`

The blocking reachability profile requires every economically meaningful handler
to record at least one randomized success in each invariant campaign, but CI does
not pin a fuzz seed. Deterministic setup deliberately excludes its successful calls
from the metric and, after exercising same-asset and cross-asset exits, leaves only
one live shield receipt. A random sequence can consume that receipt before
`claimRewards` selects its current owner. Later `claimRewards` selector dispatches
return as modeled precondition skips, so Foundry reports zero external reverts while
the handler's separate success counter remains zero.

This occurred on the documentation-only SHA
`53318f0f5940f052012887c3e35bfce54f970951`. The normal Foundry suite passed, but
[CI run 29258297496, attempt 1](https://github.com/YieldShield/smart-contracts/actions/runs/29258297496)
failed the dedicated reachability step with 27/28 tests passing. Forge reported 233
`claimRewards` handler dispatches and zero external handler reverts, then shrank the
failing 1,025-call campaign to one unrelated `dropPrice` call. The dispatch count
does not mean that 233 eligible protocol claims failed: calls with no selected live
receipt are intentionally counted as precondition skips. The shrunk trace therefore
does not preserve the scheduling history that made the coverage postcondition fail.

**Impact:** a false-negative release signal, retry-driven normalization of red
security gates, and loss of reproducible failure evidence. This does not establish
a production accounting or `claimRewards` defect.

**Recommendation:** make hard-gated reachability deterministic and reproducible.
Pin and print several reviewed `--fuzz-seed` values, retain or upload the original
unshrunk campaign evidence, and redesign the handler so destructive exits cannot
eliminate every receipt required by another hard floor. For example, reserve a
dedicated claimable receipt or select from a global live-receipt set. Keep unseeded
campaigns as additional exploration, but do not make a single random per-run
path-coverage outcome the release gate. CI output should distinguish attempts,
precondition skips, protocol successes, and unexpected reverts.

## Informational finding

### I-01 — The named uint128 boundary fuzz test does not approach the boundary

**Affected:** `test/SplitRiskPoolFuzz.t.sol:345-371,409-466`

`testFuzz_FeeAccumulationNearUint128Limit` uses deposits around `1e24`, bounds its
input to `uint64`, then re-bounds that value to a yield of 1–5,000 basis points. It
does not construct state near `type(uint128).max`. Its final checks merely assert
that values returned as `uint256` remain below `uint128.max`; they do not test the
exact cap transition or atomic rollback.

Nearby tests also include assertions that an unsigned value is at least zero and at
most `uint256.max`. These are tautologies and cannot catch a regression.

**Impact:** misleading assurance and reduced reviewer signal. Existing deterministic
tests cover some accumulation caps, so this does not establish a production defect.

**Recommendation:** seed state immediately below `MAX_SAFE_ACCUMULATION`, fuzz deltas
on both sides of the exact boundary, assert the precise error and unchanged state on
revert, and replace tautologies with conservation, delta, or reference-model
properties.

## Rechecked areas with no new confirmed defect

The review did not confirm an additional issue in:

- pool share accounting, reward debt, fee buckets, epoch settlement, owner escrow,
  surplus sweeping, or factory retirement;
- withdrawal ordering and reentrancy guards around token callbacks;
- Pyth price age, per-token/per-feed overrides, spot/EMA confidence, exponent
  normalization, composite publish-time skew, and L2 sequencer gating;
- Chainlink round validation, opening freshness, sequencer gating, market-session
  emergency separation, or closed-session exit bounds;
- ERC-4626 minimum supply/value, redeemable-vs-accounting NAV, delayed reference
  refresh, protected upward clamp, underlying staleness, or sequencer gating;
- governance timelock topology, two-step governance replacement, disabled UUPS
  upgrades, storage snapshots, or bootstrap finalization;
- manifest promotion, exact finalized-block agreement, dual-RPC code/wiring checks,
  operator-identity attestations, or quarantine of unpromoted public deployments;
- storage-layout CI or Slither's separate blocking high-severity job.

Automated findings were not accepted by label alone. Slither's Pyth-confidence and
publish-time heuristics do not recognize the repository's explicit validation
helpers; Aderyn's existing report remains noisy and report-only. Every counted
finding above has a current-code path or a reproducible assurance probe.

## Known constraints and trust assumptions not counted again

- **Token behavior:** whitelist admission still relies on a governance attestation
  that balances are static, transfers do not debit senders by more than the nominal
  amount, and behavior cannot change while pools are active. Runtime balance-delta
  checks fail closed if that assumption later breaks, potentially delaying exits or
  bond settlement.
- **Contract size:** standard EIP-170 portability is deliberately report-only in CI;
  repository-owned Robinhood ceilings remain blocking. `SplitRiskPool` has only 583
  bytes of EIP-3860 initcode headroom and `SplitRiskPoolFactory` is exactly at its
  tracked runtime/initcode ceiling.
- **Deployment state:** there is currently no active promoted public deployment
  manifest. Historical Robinhood testnet and Arbitrum Sepolia address maps remain
  quarantined.
- **Operational trust:** Safe custody, governance decisions, oracle providers,
  token issuers/proxy administrators, market-session calendar input, RPC operator
  identity attestations, and Pyth update operations remain outside what unit tests
  can prove.
- **Arbitrum Sepolia:** the disabled sequencer-feed requirement is an explicit
  exception because Chainlink does not currently publish a canonical Arbitrum
  Sepolia sequencer feed. It must be revisited if that changes.
- **Pyth July 31, 2026 change:** the checked-in Arbitrum addresses already select the
  upgraded contracts and `.env.example` documents authenticated Hermes access. No
  address remediation was identified in this review.

## Verification evidence

- Baseline and remote synchronization:
  `git rev-parse HEAD == git rev-parse origin/main == b8016a8d...`.
- Targeted M-01 reproduction: 1 passed, 0 failed.
- Receipt coverage mutation: policy still passes at 85.31% lines and 55.21%
  branches after removing every protector-receipt hit.
- Arbitrum CLI probe: no size override, no chain-aware deployment-target size
  check, and no required updater-confirmation input.
- Current artifacts: pool 48,302-byte runtime / 48,569-byte initcode; factory
  41,385-byte runtime / 41,652-byte initcode.
- Post-push exact-SHA CI on `53318f0f...`: the normal Foundry suite, coverage policy,
  fork smoke, contract-size jobs, Slither reporting and high-severity gate, and
  Aderyn report completed successfully. Attempt 1 of the separate randomized
  reachability gate failed 1/28 as described in L-06.
- The immediately preceding exact-baseline remediation record reports 1,169
  Foundry tests passing with five expected live-fork skips, 134 script tests,
  28 invariant-reachability tests, storage snapshot success, coverage policy
  success, and a passing Slither high-severity gate. This follow-up reran the
  targeted exploit and assurance probes instead of treating those release totals as
  proof that the newly identified policies were safe.

## Primary research sources

- [Chainlink: Using Data Feeds](https://docs.chain.link/data-feeds/using-data-feeds)
- [Chainlink: L2 Sequencer Uptime Feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds)
- [Chainlink: Selecting Quality Data Feeds](https://docs.chain.link/data-feeds/selecting-data-feeds)
- [Pyth: Best Practices](https://docs.pyth.network/price-feeds/core/best-practices)
- [Pyth: EVM Contract Addresses](https://docs.pyth.network/price-feeds/core/contract-addresses/evm)
- [OpenZeppelin: ERC-4626](https://docs.openzeppelin.com/contracts/5.x/erc4626)
- [OpenZeppelin: Access Control](https://docs.openzeppelin.com/contracts/5.x/access-control)
- [Solidity: Security Considerations](https://docs.soliditylang.org/en/latest/security-considerations.html)
- [EIP-170: Contract Code Size Limit](https://eips.ethereum.org/EIPS/eip-170)
- [EIP-3860: Limit and Meter Initcode](https://eips.ethereum.org/EIPS/eip-3860)
- [Offchain Labs: ArbOS 61 Elara proposal](https://forum.arbitrum.foundation/t/constitutional-aip-arbos-61-elara/30601)
