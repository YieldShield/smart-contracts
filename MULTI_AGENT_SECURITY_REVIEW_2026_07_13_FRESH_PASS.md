# Multi-Agent Smart-Contract Security Review — Fresh Pass

- **Date:** 2026-07-13
- **Reviewed commit:** `a6f91af12510391ae8a429f700de827032dadcd0` (`main`)
- **Scope:** production contracts, oracle adapters, factory and deployment lifecycle,
  receipt NFTs, invariant/fork assurance, CI security gates, and prior-review
  remediations

## Executive summary

Four independent review tracks re-audited the current `main` state: core
accounting/lifecycle, oracle/deployment integration, tests/CI assurance, and an
integrated deduplication/reproduction pass. The review also refreshed primary
Chainlink, Pyth, OpenZeppelin, and Solidity guidance.

No new Critical, High, or Medium issue was confirmed. Six Low-severity residuals
and two Informational inconsistencies survived reproduction and deduplication:

| Severity      | Count |
| ------------- | ----: |
| Critical      |     0 |
| High          |     0 |
| Medium        |     0 |
| Low           |     6 |
| Informational |     2 |

The most concrete contract issue is L-01: second-granularity timestamps cannot
distinguish an operator approval made before a receipt arrives from a legitimate
approval made after receipt arrival when both occur in the same block. The most
material assurance issue is L-05: the invariant reachability gate counts
deterministic setup calls, so it does not prove that randomized dispatch reached
the required economic paths.

This review is an engineering security assessment, not a guarantee that the
protocol is defect-free or a substitute for an independent production audit.

## Findings

### L-01 — Same-block pre-acquisition operator approval can sweep a received receipt

**Affected:** `contracts/ShieldReceiptNFT.sol:155-208`,
`contracts/ProtectorReceiptNFT.sol:139-194`, `test/NFTTransferLock.t.sol:232-254`,
`test/NFTTransferLock.t.sol:369-391`

Both receipt contracts record `setApprovalForAll` and token movement as
`uint64(block.timestamp)`. Operator authorization accepts
`approvalTimestamp >= movementTimestamp`.

This cannot distinguish the following two orderings within one block, because every
transaction in the block has the same timestamp:

1. A recipient approves an operator.
2. The recipient later acquires a mature receipt.
3. The operator transfers that receipt to itself or another address.

At step 3, approval time, movement time, and the current block time are equal. The
receipt lock has matured and `_isAuthorized` returns true, so the operator can take
control of the full shield or protector position. The existing regression covers an
approval in an earlier timestamp and therefore misses equality.

Two temporary Foundry PoCs reproduced the sequence for both receipt types. Both
passed, after which the scratch test was removed:

```text
[PASS] test_PoC_ShieldApprovalBeforeReceiptSameBlockCanSweep()
[PASS] test_PoC_ProtectorApprovalBeforeReceiptSameBlockCanSweep()
```

**Impact:** theft or unwanted control of a mature position under the narrow
precondition that the recipient approves a malicious or compromised operator
earlier in the same block as acquisition. The victim has explicitly approved the
operator, but the receipt contracts are intended to invalidate approvals that
predate receipt acquisition.

**Deduplication:** the July 4 N-4 finding covered the inverse usability problem:
strict `>` rejected a legitimate same-block approval made after receipt. Changing
the comparison to `>=` fixed that ordering but admitted this previously untested
approval-before-receipt ordering.

**Recommendation:** use a contract-monotonic ordering counter rather than time or
block number. Record the current order on receipt movement and operator approval,
then require approval order to be strictly later than movement order. Add mirrored
tests proving approval-before-receipt fails and receipt-before-reapproval succeeds
within one block.

### L-02 — Robinhood-equity classification fails open when `oraclePaused()` is unavailable

**Affected:** `contracts/oracles/CompositeOracle.sol:278-282,323-330,358-368,1295-1313`,
`contracts/SplitRiskPool.sol:564-589`

`_validateRobinhoodStockOracleRoute` treats a token as a Robinhood equity only when
a live `oraclePaused()` probe succeeds and returns a canonical Boolean. A revert,
short response, or malformed Boolean returns from the validator without applying
the pinned-wrapper requirement.

A temporary Foundry PoC configured a raw oracle while the token's pause probe
reverted, then restored the selector and set the token to paused. The configuration
continued returning the raw price and retained
`protectionOpeningEligibilityRequired == false`:

```text
[PASS] test_PoC_ProbeOutagePermanentlyBypassesPinnedWrapper()
```

The bypass persists until governance reconfigures the token. It skips the
`RobinhoodStockOracleFeed` corporate-action pause, session calendar, and
opening-specific freshness policy.

**Impact:** governance can accidentally onboard or reconfigure an equity through an
unsafe raw route during a transient or malformed token response. This is a
governance/configuration precondition, so it is Low rather than a permissionless
exploit.

**Deduplication:** the prior L-01 recommendation explicitly called for a reviewed
token classification rather than a fallible optional-selector probe. The wrapper is
now deployed and pinned, but the current dynamic probe leaves that remediation
incomplete.

**Recommendation:** persist an explicit governance-reviewed equity classification.
For classified tokens, require the one-time pinned wrapper independently of current
token behavior, and fail configuration on reverted, short, or malformed pause
responses. Cover all malformed encodings and recovery after configuration.

### L-03 — Unconfigured calendar days are treated as scheduled market closures

**Affected:** `contracts/oracles/USMarketSessionGate.sol:18-24,107-124`,
`contracts/oracles/RobinhoodStockOracleFeed.sol:155-178`,
`contracts/oracles/ChainlinkOracleFeed.sol:146-151,517-523`,
`contracts/SplitRiskPool.sol:633-645,1320-1334,2163-2181,2301-2304,2457-2459`

An absent `DailySession` has `closesAtSecond == 0`, and `isMarketOpen()` correctly
returns false for protection openings. The closed-session exit path receives only
that Boolean, however, and cannot distinguish an unconfigured day from a weekend,
holiday, or other explicit closure. It therefore enables the seven-day extended
Chainlink freshness window on missing days.

The existing test demonstrates the boundary after clearing the current session:

```sh
forge test --offline \
  --match-path test/RobinhoodStockOracleFeed.t.sol \
  --match-test test_closedSessionExitPrice_AllowsSevenDayBoundaryAndRejectsOlderPrice -vv
```

Result: `1 passed; 0 failed` while a price exactly seven days old was accepted.

**Impact:** if an open weekday is omitted or the configured calendar horizon
expires, same-asset exits and claims can settle yield fees from a stale value during
a live market. This can undercollect or overcollect fees. New openings and
cross-asset withdrawals remain fail-closed.

**Deduplication:** the prior review documented the empty calendar as an operational
release risk and separated emergency pause from scheduled closure. This finding is
the remaining semantic collision between _missing_ and _explicitly closed_ days,
not a duplicate of the emergency-pause issue.

**Recommendation:** expose a tri-state result such as `Unconfigured`, `Open`, and
`ScheduledClosed`, or store explicit closed days. Permit extended freshness only for
`ScheduledClosed`; missing days must fail closed. Alert before the configured
calendar horizon expires.

### L-04 — Solidity finalization validation omits sequencer-feed wiring

**Affected:** `script/DeployYieldShieldProduction.s.sol:299-378,814-873,1495-1596`,
`test/DeploymentSecurity.t.sol:1617-1680`

`_validateProductionProtocolFinalized` checks code hashes, ownership, governance,
factory/oracle topology, the Robinhood wrapper, and the market guardian. It does not
read `sequencerUptimeFeed()` or `sequencerUptimeFeedRequired()` from Pyth,
Chainlink, or ERC-4626 oracle components.

The external Chainlink recovery finalizer performs a separate precheck, but the
shared Solidity view validator can still report a zero-feed deployment as finalized.
The Pyth recovery finalizer has no equivalent precheck before ownership and bootstrap
transitions. JavaScript manifest promotion detects bad wiring later, after broadcast.

The repository's own recovery test deploys Chainlink and ERC-4626 guards with the
known-L2 default `required == true` and zero feed addresses, then successfully runs
the internal finalizer and validator:

```sh
forge test --offline \
  --match-path test/DeploymentSecurity.t.sol \
  --match-test test_ProductionProtocol_FinalizerRecoversPauseOnlyChainlinkGuardian -vv
```

Result: `1 passed; 0 failed`.

**Impact:** a recovery deployment can cross irreversible bootstrap/ownership steps
with price reads denied by missing sequencer wiring, while the Solidity validator
provides false assurance. The normal exact deployment path configures the feed, so
this is an operational availability weakness.

**Deduplication:** the earlier L-06 fix added manifest sequencer evidence. This is a
residual omission in the Solidity finalization boundary, not a claim that the
manifest finalizer lacks the check.

**Recommendation:** add non-mutating, chain-specific sequencer validation to
`_validateProductionProtocolFinalized` and call it before any ownership/bootstrap
mutation in both recovery finalizers. Arbitrum One should require the reviewed
canonical feed and `required == true` on every applicable component; supported
exceptions should attest both zero address and disabled requirement explicitly.

### L-05 — The invariant reachability gate counts deterministic setup calls

**Affected:** `test/SplitRiskPoolInvariant.t.sol:981-983,1037-1056,1443-1477`,
`.github/workflows/ci.yml:80-101`,
`scripts-js/__tests__/invariant-policy.test.cjs:29-57,73-86`

The invariant setup enables metrics and then calls `_seedReachableHandlerPaths`,
which executes every handler family required by `afterInvariant`. The post-run gate
checks lifetime attempt/success totals, not randomized deltas after the seed.
Consequently, the deterministic fixture satisfies every reachability floor before
Foundry performs its first randomized call.

The following one-run, one-call campaign passed every reachability assertion even
though randomized dispatch called only `depositShielded`:

```sh
env FOUNDRY_PROFILE=invariant-reachability \
  INVARIANT_REQUIRE_HANDLER_REACHABILITY=true \
  FOUNDRY_INVARIANT_RUNS=1 \
  FOUNDRY_INVARIANT_DEPTH=1 \
  forge test --offline \
  --match-contract SplitRiskPoolInvariantTest \
  --match-test invariant_poolBalanceSolvency \
  --fuzz-seed 0x01 -vv
```

```text
[PASS] invariant_poolBalanceSolvency() (runs: 1, calls: 1, reverts: 0)
SplitRiskPoolHandler | depositShielded | 1 | 0 | 0
```

**Impact:** the fixed-seed CI job proves fixture construction and invariant validity,
but does not prove randomized path coverage. Handler regressions or ineffective
random scheduling can pass the release gate.

**Deduplication:** the prior L-06 finding concerned nondeterministic seeds and poor
diagnostics. The remediation made the job reproducible but, by counting seed calls,
removed the property it claimed to enforce.

**Recommendation:** snapshot or reset handler metrics after deterministic fixture
construction and require positive randomized deltas for each selector. Update the
policy test to reject seed-counted reachability. Keep fixture-construction assertions
as a separate gate.

### L-06 — The Arbitrum live smoke accepts `PriceFeedNotFound` for its canonical feed

**Affected:** `test/ArbitrumOracleFork.t.sol:99-137`,
`scripts-js/__tests__/fork-policy.test.cjs:75-80`

The smoke assigns the checked-in USDC feed ID, but its catch branch accepts
`PythErrors.PriceFeedNotFound` as an expected live result. The same file proves that
an unknown ID returns exactly that selector. Replacing the checked-in canonical ID
with the unknown ID would therefore leave the integration outcome acceptable.

The current checked-in USDC/USD stable feed ID matches Pyth's current official feed
catalog; the weakness is that CI cannot detect future ID drift or a wrong replacement.

**Impact:** address/interface and sequencer drift are exercised, but canonical
feed-ID availability is not. Production Arbitrum deployment remains blocked by the
separately documented size constraint, so this is assurance/deployment readiness
rather than active-funds exposure.

**Deduplication:** this is a residual of the prior independent-fork remediation. It
does not repeat the older issue where fork jobs could skip entirely.

**Recommendation:** fetch an authenticated Hermes update for the exact checked-in
feed ID, submit it to the configured Pyth contract on each fork, then require a sane
price. `PriceFeedNotFound` must fail for the canonical ID; model staleness separately
if a test intentionally omits an update.

### I-01 — The documented local coverage command is unusable and non-enforcing

**Affected:** `SECURITY.md:67-72`, `Makefile:88-94`,
`.github/workflows/ci.yml:275-282`

Both contributor documentation and `make coverage` run:

```sh
forge coverage --ffi --report summary
```

On the reviewed commit this exits non-zero after disabling optimizer/viaIR:

```text
Error: Compiler run failed: Stack too deep
--> contracts/SplitRiskPool.sol:2562:40
```

Even if generation succeeded, neither local target invokes
`scripts-js/checkCoverage.js`. CI uses a materially different command with
`--ir-minimum`, LCOV output, a gas-test exclusion, and `npm run coverage-check`.

**Impact:** contributors cannot run the documented check locally and may believe a
summary-only command enforces the repository's coverage policy.

**Recommendation:** define one package/Make target containing the exact CI generation
and checker sequence, call it from CI, and document it. If retained, label the
summary target diagnostic rather than policy-enforcing.

### I-02 — Shield liabilities have no non-confiscatory draining lifecycle

**Affected:** `contracts/SplitRiskPoolFactory.sol:108,1134-1195,1529-1563`,
`contracts/SplitRiskPool.sol:145-168,2132-2137,2282-2287`,
`contracts/ShieldReceiptNFT.sol:155-174`

The factory can deactivate a protector-only pool while preserving live protector
withdrawals, but every retirement path involving shield liabilities requires exact
emptiness. A holder can transfer a mature shield receipt to an uncallable address,
or simply never withdraw, leaving one of the 100 active slots occupied indefinitely.

This is not counted as a distinct exploit because a cooperative receipt owner can
already keep a shield position open for an unbounded duration. It is nevertheless a
lifecycle inconsistency: protector liabilities have a slot-freeing draining mode,
while shield liabilities do not.

**Recommendation:** explicitly document open-ended shield duration and permanent
active-slot occupancy as part of the pool-cap model, or add a draining state that
blocks new deposits while preserving every existing exit and required oracle route.
Do not confiscate, burn, or redirect abandoned user positions.

## Research cross-checks

The following current primary guidance was rechecked on 2026-07-13:

- [Chainlink Robinhood tokenized-equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood):
  the feed reports total-return value, `oraclePaused()` freezes publication during
  corporate actions, and integrators remain responsible for risk parameters. This
  supports L-02 and the need to distinguish controlled closures in L-03.
- [Chainlink L2 sequencer uptime feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds):
  consumers should reject downtime and a post-recovery grace period; the current
  canonical Arbitrum One proxy is `0xFdB631F5EE196F0ed6FAa767959853A9F217697D`.
  This supports L-04.
- [Pyth best practices](https://docs.pyth.network/price-feeds/core/best-practices),
  [EVM contract addresses](https://docs.pyth.network/price-feeds/core/contract-addresses/evm),
  and [price feed IDs](https://docs.pyth.network/price-feeds/core/price-feeds/price-feed-ids):
  staleness checks remain required against adversarial update selection, the
  checked-in Arbitrum One address matches the upgraded July 31 contract, and the
  checked-in USDC/USD ID matches the stable catalog. No address/feed correction was
  identified; L-06 concerns what the smoke can prove.
- [OpenZeppelin ERC-4626 guidance](https://docs.openzeppelin.com/contracts/5.x/erc4626):
  empty-vault rounding/inflation risk and virtual-offset defenses were rechecked
  against the current vault-oracle and pool accounting paths. No additional
  ERC-4626 finding survived reproduction.
- [Solidity security considerations](https://docs.soliditylang.org/en/latest/security-considerations.html):
  reentrancy/CEI, external-call behavior, and unbounded-loop risk were rechecked.
  No additional concrete defect survived the integrated pass.

## Verification evidence

The review ran from a clean worktree synchronized to `origin/main` at the reviewed
commit. Temporary PoC tests were deleted after execution.

- Full `forge test --offline`: 1,178 passed, 0 failed, 7 expected live-fork skips.
- Repository policy/script tests: 141 passed, 0 failed.
- Receipt approval PoCs: 2 passed, 0 failed.
- Robinhood classification PoC: 1 passed, 0 failed.
- Closed-session seven-day boundary regression: 1 passed, 0 failed.
- Production finalizer recovery regression: 1 passed, 0 failed.
- One-call invariant reachability reproduction: 1 passed, 0 failed while only one
  randomized selector executed.
- Documented local coverage command: reproduced the expected non-zero
  `Stack too deep` failure.
- The exact reviewed baseline SHA had a green GitHub Actions run before this fresh
  pass; this review does not treat a green baseline as proof that the residual
  assurance properties above are effective.

## Rechecked areas without another confirmed defect

- protector shares, reward debt, commission escrow, fee buckets, expired epochs,
  partial exits, surplus handling, and creation-bond accounting;
- reentrancy ordering, receipt callbacks, pool/factory governance transfer, disabled
  UUPS upgrades, and storage layout gates;
- Pyth staleness/confidence/exponent/composite-skew checks, Chainlink round/bounds
  checks, TWAP liquidity/cardinality, CompositeOracle challenge/failback, and
  ERC-4626 reference-band logic;
- production codehash pins, core topology, manifest finality evidence, dependency
  pins, blocking Slither policy, and action-version pins.

## Known constraints not re-counted

- Robinhood mainnet still requires a verified sequencer-uptime source before launch.
- Mainnet market-calendar population, monitoring, DST, holidays, and early closes
  remain release-critical operational inputs.
- Arbitrum deployment remains blocked by standard EIP-170/EIP-3860 size constraints.
- `SplitRiskPool` implementations are immutable; emergency code fixes require a new
  deployment and migration.
- Aderyn remains report-only and the existing baseline is noisy.
