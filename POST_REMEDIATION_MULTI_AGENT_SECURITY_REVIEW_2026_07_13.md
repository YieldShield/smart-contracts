# YieldShield Post-Remediation Multi-Agent Security Review — July 13, 2026

## Executive summary

This review examined `main` at
`ea727c52963e43179d56455f7ac07a9c3bc8b00e`, after completion of the July 13
remediation program. It found **no confirmed Critical or High-severity issue**.
One **Medium**, seven **Low**, and four **Informational** weaknesses or
inconsistencies survived independent review and reproduction.

The most important finding is economic: Robinhood equity feeds inherit the
production adapter's 86,400-second default freshness window. During a configured
open session, a feed that stops updating without setting `oraclePaused()` can
therefore remain eligible for new protection for almost 24 hours. A depositor can
lock an overstated `valueAtDeposit` and later realize the difference through a
cross-asset withdrawal. The 24-hour ceiling is useful for daily-cadence RWA feeds,
but it is too permissive as the default opening policy for 24/5 equities.

The remaining findings are narrower. They concern a nonstandard token type that can
be admitted but cannot be paid out; an emergency guardian that can indirectly enable
seven-day stale fee settlement; incomplete independence and Pyth-sequencer evidence
in deployment promotion; public-chain deployment/export behavior that is hardened
only for Robinhood; and several assurance or event-semantics gaps.

| Severity      | Count | Character                                                     |
| ------------- | ----: | ------------------------------------------------------------- |
| Critical      |     0 | None confirmed                                                |
| High          |     0 | None confirmed                                                |
| Medium        |     1 | Permissionless stale-price economic exposure                  |
| Low           |     7 | Token liveness, oracle privilege, deployment, and test policy |
| Informational |     4 | Reentrancy assumption, event semantics, and assurance scope   |

This is a defensive repository review, not a guarantee of correctness or a
substitute for an independent professional audit and launch rehearsal before
material value is deposited.

## Scope and method

- **Baseline:** `ea727c52963e43179d56455f7ac07a9c3bc8b00e`, synchronized with
  `origin/main` and clean before review.
- **Scope:** production contracts, oracle adapters, governance and token admission,
  deployment/recovery/finalization tooling, generated-address policy, Foundry tests
  and invariants, static analysis, coverage enforcement, and GitHub Actions.
- **Review team:** one primary reviewer plus three independent agents. The agents
  separately covered core accounting/lifecycle behavior, oracle and deployment
  behavior, and test/tooling/CI assurance. The primary reviewer reproduced and
  deduplicated their candidates against the current code and prior reports.
- **Deduplication:** findings already closed in `REMEDIATION_2026_07_13.md` were not
  re-reported unless the remediation introduced a distinct remaining weakness.
- **Research:** official Chainlink, Robinhood Chain, Pyth, and OpenZeppelin guidance
  was refreshed on July 13, 2026. Only primary documentation was used for technical
  conclusions.

## Primary research updates

The external research changed or confirmed several launch assumptions:

1. Chainlink's Robinhood equity documentation states that the reported total-return
   value already includes Robinhood's `uiMultiplier()`. The protocol must not apply
   it again. The current adapter is aligned with this guidance.
2. The same documentation describes `oraclePaused()` and warns that feeds can hold
   their last good value during corporate actions and outside trading hours. It
   specifically requires integrators to evaluate `updatedAt` against a freshness
   policy appropriate to their application. This supports M-01 and L-02.
3. Chainlink's sequencer-uptime registry still does not list Robinhood Chain. The
   repository correctly keeps Robinhood mainnet deployment blocked rather than
   inventing an address or reusing another Arbitrum chain's feed.
4. Pyth's upgraded Arbitrum contract addresses and authenticated Hermes flow match
   the checked-in `PythConfig` and updater. The July 31, 2026 Pyth migration is not a
   new finding in this repository.
5. The governance topology remains consistent with OpenZeppelin's timelock guidance:
   the timelock is the sole admin and the governor is the sole proposer, executor,
   and canceller in the production validation path.

Primary sources are linked in [Research sources](#research-sources).

## Medium finding

### M-01 — Robinhood openings accept nearly 24-hour-old prices by default

**Affected:** `script/DeployYieldShieldProduction.s.sol:122,604-608`,
`contracts/oracles/ChainlinkOracleFeed.sol:142-154,326-340,440-463`,
`contracts/oracles/RobinhoodStockOracleFeed.sol:180-200`,
`contracts/SplitRiskPool.sol:564-590,2039-2079`

Production constructs `ChainlinkOracleFeed` with a default maximum age of 86,400
seconds. A per-token override exists, but registration does not require one and the
production script does not set an equity-specific value. The Robinhood wrapper's
opening check verifies only `oraclePaused()` and whether the configured market
session is open. It does not enforce a tighter opening freshness threshold.

The resulting sequence is:

1. A stock feed stops updating during a configured open session while the sequencer
   remains available and `oraclePaused()` remains false.
2. For almost 24 hours, `isProtectionOpeningAllowed` remains true and the ordinary
   Chainlink read still accepts the last round.
3. A depositor opens a shield position using an overstated stale stock value.
4. `depositShieldedAsset` fixes that value in `valueAtDeposit` and sizes backing
   collateral from it.
5. After the minimum pool time, a cross-asset withdrawal can realize the stale-value
   difference against protectors, subject to the position's collateral cap.

For example, if the accepted round values 100 stock units at $100 while their live
value has fallen to $50, a position can record $10,000 of protected value while
contributing only $5,000 of current economic value. Later forfeiture of the stock
does not make protectors whole for the overstated protected amount.

**Impact:** permissionless economic loss during an oracle publishing incident with
material price movement. A correctly configured independent backup feed reduces the
risk, but dual-feed mode is not mandatory for every stock.

**Recommendation:** require an explicit, reviewed per-token opening freshness bound
for every Robinhood equity. Prefer an opening-specific check in
`RobinhoodStockOracleFeed.isProtectionOpeningAllowed`, attest every effective age
during deployment/pool launch, and add an open-session regression that rejects a
stock opening after the equity threshold expires even though the generic 24-hour
adapter ceiling has not.

## Low findings

### L-01 — An admitted sender-extra-debit token can permanently trap principal and creation bonds

**Affected:** `contracts/SplitRiskPoolFactory.sol:1278-1288,1494-1522,1589-1599`,
`contracts/SplitRiskPool.sol:994-1009,1953-2018,2491-2615`,
`test/SplitRiskPoolFactory.t.sol:430-446,1983-2025`

Backing-token admission checks decimals and common rebasing/share-balance markers,
then relies on governance's static-balance acknowledgement. A token that transfers
the requested nominal amount but debits an additional fee from the sender passes
these checks. Creation bonds and protector deposits are accepted by received-balance
delta.

Outbound paths deliberately require the pool or factory debit to equal the nominal
amount removed from accounting. The same token therefore makes protector withdrawal,
creator closure, and governance deactivation revert. Existing regression tests
already construct this exact state and confirm both bond-return paths remain blocked.

**Impact:** protector principal and creation bonds can become non-withdrawable, and
an active pool slot can become impossible to close. The precondition is governance
admission of an incompatible token or a compatible token changing behavior.

**Recommendation:** reject sender-extra-debit behavior before token or pool
activation, or require a reviewed transfer-behavior attestation. At minimum, state
explicitly that fee-on-transfer backing support excludes sender-extra-debit designs.
Change the existing regression to require rejection at admission or creation rather
than merely demonstrating that eventual payout fails.

### L-02 — The pause-only market guardian can unlock seven-day stale fee settlement

**Affected:** `contracts/oracles/USMarketSessionGate.sol:90-97,112-124`,
`contracts/oracles/RobinhoodStockOracleFeed.sol:145-159`,
`contracts/oracles/ChainlinkOracleFeed.sol:486-492`,
`contracts/SplitRiskPool.sol:633-645,1316-1330,2172-2177,2297-2300,2453-2456`

`emergencyPause()` sets `emergencyPaused`, and `isMarketOpen()` then returns false.
The stock adapter treats every false result as a scheduled market closure and exposes
the hard-capped seven-day price path. It cannot distinguish a weekend/holiday from an
emergency pause during a live session.

If the ordinary stock price is already more than 24 hours old, the guardian can pause
the session and allow same-asset withdrawals, partial withdrawals, and reward claims
to calculate fees from that older round. A value at or below a position's high-water
mark can undercollect fees that would have been due once live pricing recovered.

**Impact:** bounded fee undercollection or overcollection under the combined
preconditions of an oracle outage and a compromised or colluding guardian. Openings,
cross-asset withdrawals, corporate-action pause checks, sequencer checks, bounds, and
dual-feed deviation controls remain fail-closed.

**Recommendation:** expose a reasoned session state such as `Open`,
`ScheduledClosed`, and `EmergencyPaused`. Permit seven-day pricing only for a
scheduled closure and define a separate conservative checkpoint, fee reserve, or
deferred-fee policy for emergency exits.

### L-03 — “Independent RPC” evidence proves only URL and hostname inequality

**Affected:** `scripts-js/finalizeDeploymentManifest.js:291-325,356-405`,
`README.md:169-175`

Manifest finalization rejects identical URLs and identical hostnames, then records
`independentValidationRpc: true`. Two endpoint-specific hostnames operated by the
same provider pass. The following current-code probe succeeds:

```text
primary:    https://alpha.quiknode.pro/key-a
validation: https://beta.quiknode.pro/key-b
```

Both endpoints can therefore share an operator, infrastructure, censorship policy,
or faulty chain view while satisfying finalized-block, receipt, code, and wiring
agreement.

**Impact:** the manifest can overstate the independence of its finalized-state
attestation. This weakens protection against a faulty or compromised RPC provider.

**Recommendation:** require explicit provider-operator identities, enforce distinct
operators, and persist those identities in finality evidence. Prefer one independently
operated full node and reject different endpoint hostnames belonging to the same
provider.

### L-04 — Public ABI and Ponder exports accept legacy or unpromoted state outside Robinhood

**Affected:** `scripts-js/generateTsAbis.js:52,122-191,208-210,950,986-989`,
`deployments/421614.json:1-12`

Strict schema-v2 manifest validation and exact manifest name/address filtering apply
only to Robinhood chain IDs 4663 and 46630. The checked-in Arbitrum Sepolia deployment
is a legacy address map with no promotion status, finality evidence, codehash evidence,
or wiring evidence. At the reviewed baseline:

```text
validateActiveDeploymentManifest("421614", legacy) -> accepted
requirePromotedManifestForStrictTarget("421614", {}) -> null
constrainStrictChainContracts({421614: rawAddress}, {}) -> rawAddress retained
```

**Impact:** generated frontend or Ponder configuration can publish a stale, failed,
or raw-broadcast address for a non-Robinhood public chain.

**Recommendation:** apply promoted-manifest validation and exact name/address
constraints to every non-local public chain. Migrate or quarantine
`deployments/421614.json`, and add legacy/raw-broadcast rejection tests for chain 421614.

### L-05 — The deployment CLI can broadcast before discovering that finalization is unsupported

**Affected:** `scripts-js/parseArgs.js:53-65,111-129,625-668`, `Makefile:29-36`,
`config/deployment-finality-policy.json:1-14`,
`scripts-js/finalizeDeploymentManifest.js:274-288`

The CLI defaults every configured non-local network to the production deployment
script and invokes `deploy-and-generate-abis`. The Make target broadcasts first and
only then invokes the manifest finalizer. The checked-in finality policy contains
only chain IDs 4663 and 46630; for example, chain 421614 fails with:

```text
Chain 421614 has no checked-in deployment finality policy.
```

This failure is discovered after the irreversible, gas-spending deployment step.

**Impact:** a public deployment can complete on-chain but become stranded before
promotion and ABI publication. This also encourages manual legacy address export,
compounding L-04.

**Recommendation:** make finality-policy support a pre-broadcast check. Either add
reviewed policies for every supported public alias or reject unsupported networks
before invoking Forge.

### L-06 — Pyth-mode manifest promotion omits sequencer wiring attestation

**Affected:** `script/DeployYieldShieldProduction.s.sol:525-535,1363-1368`,
`scripts-js/finalizeDeploymentManifest.js:785-818,979-995`

The production script configures the Arbitrum sequencer feed on both `PythOracle` and
`ERC4626OracleFeed`, then transfers their ownership to the factory. Finalized-state
manifest validation reads and validates the two sequencer guards only in Chainlink
mode. Pyth-mode validation checks ownership and underlying-oracle wiring but omits
both sequencer addresses and both `sequencerUptimeFeedRequired` flags.

The factory has no sequencer-administration forwarding method. A wrong or missing
Pyth-mode feed therefore becomes effectively frozen and requires redeployment. The
current exact deployment code sets the documented Arbitrum feed, and Pyth deployment
promotion is also blocked today by L-05's missing finality policy, so this is a latent
attestation weakness rather than evidence of a currently active bad deployment.

**Impact:** after Pyth public-chain promotion is enabled, a script or recovery
regression could receive an active manifest while price reads are bricked or guarded
by the wrong sequencer feed.

**Recommendation:** always read both Pyth and ERC-4626 sequencer addresses and
required flags in Pyth mode, require the chain-specific expected state, persist it in
the manifest, and add missing/wrong/disabled sequencer rejection tests.

### L-07 — The new commission escrow is outside per-contract coverage floors

**Affected:** `scripts-js/checkCoverage.js:7-50`,
`contracts/ProtectorCommissionEscrow.sol:29-67`

`ProtectorCommissionEscrow` was added after the critical coverage inventory. It
contains beneficiary authentication, a reentrancy guard, exact-debit transfer
accounting, and one-time receipt state, but has no per-contract floor. Zeroing every
line and branch hit in only the escrow's current LCOV record still passes policy:

```text
Production coverage passed: lines 86.09%, branches 55.47%
ProtectorCommissionEscrow critical entry: absent
```

The aggregate remains above its thresholds, so all escrow regressions can disappear
without failing the coverage job. The same manual-inventory concern applies to small
security controls such as `USMarketSessionGate` and `SequencerUptimeGuard`.

**Impact:** CI can lose all direct coverage of a security-sensitive, newly introduced
state machine while remaining green.

**Recommendation:** add the escrow and reviewed security controls to per-contract
floors. Add a policy test that synchronizes the critical coverage list with an
explicit security-critical or production-deployment inventory.

## Informational findings

### I-01 — The transfer-integrity reset violates its helper's reentrancy assumption

**Affected:** `contracts/SplitRiskPool.sol:1020-1047,3118-3136`,
`test/SplitRiskPoolReentrancyBalance.t.sol:14-16,71-94`

`_requireUntaxedShieldedRoundTrip` performs two external token transfers and states
that every caller is a `nonReentrant` external function. The governance-only
`resetShieldedTokenTransferIntegrity` entrypoint is not guarded. The existing callback
test invokes only a guarded harness, so it does not cover the production reset path.

No cross-user theft path was reproduced: balance coverage, the active integrity
flag, authorization, and the final round-trip balance equality constrain current
callbacks. The code nevertheless contradicts its own security argument and leaves a
future-change hazard.

**Recommendation:** add `nonReentrant` to the reset and run the callback regression
through the actual governance path.

### I-02 — Redirected bond-return events label the recipient as the creator

**Affected:** `contracts/libraries/EventsLib.sol:117`,
`contracts/SplitRiskPoolFactory.sol:1211-1229,1561-1573`

Creator `C` may call `closePoolTo(pool, R)`. `_returnCreationBond` emits
`CreationBondReturned(pool, R, token, amount)`, but the event ABI names its second
indexed field `creator`. Indexers can therefore record recipient `R` as the creator
even though the immutable pool creator remains `C`.

**Recommendation:** rename the field to `recipient` or emit both creator and
recipient. Add an event assertion where `C != R`.

### I-03 — The documented local Slither target is fail-open

**Affected:** `Makefile:74-86`, `SECURITY.md:41-60`

`make slither` redirects all output and appends `|| true`, then prints that the report
was written. A missing executable, compilation error, or Slither crash therefore
returns success. `make security` inherits the same false-positive completion state.

CI's separate `slither --fail-high` job is correctly blocking, so this does not
bypass the remote gate. It does make the documented local security checklist weaker
than it appears.

**Recommendation:** preserve the report artifact but propagate tool and compilation
failures. Document clearly whether detector findings are report-only or enforcing.

### I-04 — Stateful invariants omit several complex economic paths

**Affected:** `test/SplitRiskPoolInvariant.t.sol:719-734,1132-1151`,
`contracts/SplitRiskPool.sol:1718-1869,2278-2376`

The handler randomizes 12 selectors and asserts reachability for eight core actions,
but it does not exercise partial shielded withdrawals, expired protector settlement,
commission-escrow claims, fee payouts, or receipt-NFT transfers. Unit tests cover
these paths, so this is not a demonstrated contract defect. The stateful suite cannot,
however, discover sequence-dependent accounting failures that require them.

**Recommendation:** add randomized handlers plus reachability and conservation
assertions for partial receipt replacement, expired settlement and escrow claims,
fee payment, and NFT transfer/cooldown sequences.

## Prior-remediation recheck

The review independently rechecked the July 13 remediation themes. The following
protections remain present and no bypass was confirmed:

- same-asset closed-session exit liveness is separated from cross-asset valuation;
- public Robinhood promotion requires finalized-state, dual-RPC receipt/code/wiring
  agreement and reviewed core runtime pins;
- raw Robinhood broadcasts remain quarantined from ABI and Ponder output;
- governance cannot confiscate another owner's commission, and retirement escrow is
  beneficiary-bound;
- creation-bond recipients can be redirected only by the immutable creator;
- strict oracle, corporate-pause, dual-feed deviation, and sequencer gates fail
  closed on malformed or unavailable state;
- UUPS upgrades hard-revert for both factory and pool implementations;
- the ordinary invariant run rejects framework reverts and reaches its declared
  handler paths; and
- CI enforces production aggregate/critical coverage and an exact deployment-size
  inventory, subject to L-07.

## Residual launch and operational risks

These are not counted as new findings:

- **Robinhood sequencer blocker:** Chainlink still publishes no canonical Robinhood
  sequencer-uptime proxy. Mainnet deployment correctly remains blocked until an
  address, public provenance, and reviewed runtime hash are supplied.
- **No promoted current Robinhood deployment:** the fork smoke checks canonical
  Robinhood token/feed integration, not a deployed YieldShield protocol instance.
- **Market calendar operations:** mainnet starts with an empty calendar. Session,
  holiday, DST, and early-close loading plus monitoring remain release-critical.
- **Pyth cutover operations:** code addresses and authenticated Hermes support are
  current, but an updater rehearsal is still required before the July 31, 2026
  transition.
- **Immutable implementation response:** upgrades are disabled. Emergency code fixes
  require a new deployment, migration, and communications process.
- **Contract size:** `SplitRiskPool` retains only 501 bytes of standard EIP-3860
  initcode headroom. Further growth requires a module split and size-policy review.
- **Aderyn:** the job remains intentionally report-only and produces a noisy existing
  High-category baseline. A genuine future issue can be buried without a structured
  delta baseline.

## Verification

The following checks completed at the reviewed baseline:

- `forge fmt --check` — passed.
- `forge test --offline` — **1,148 passed, 0 failed, 5 fork-gated skipped** across 51
  suites.
- `npm run test:scripts` — **117 passed, 0 failed**.
- `slither ... --fail-high` — analyzed **157 contracts with 74 detectors** and passed
  the blocking High-severity gate.
- `npm run coverage-check` — 29 production contracts; **86.50% lines** and **55.72%
  branches**, subject to L-07.
- `npm run check:foundry-lock` — lock file matched all four submodule revisions.
- `npm audit --omit=dev --audit-level=high` — zero vulnerabilities.

Targeted read-only probes also reproduced:

- acceptance of the legacy 421614 manifest and an arbitrary raw 421614 address;
- acceptance of two QuickNode endpoint-specific hostnames as “independent” RPCs;
- successful coverage enforcement after all escrow line/branch hits were zeroed in
  memory; and
- the post-broadcast finality-policy failure for chain 421614.

## Recommended order

1. Add an equity-specific protection-opening freshness requirement and attest every
   effective Robinhood stock age (M-01).
2. Separate scheduled closure from emergency pause in the extended-fee-price path
   (L-02).
3. Reject sender-extra-debit token behavior before funds or bonds are admitted
   (L-01).
4. Make every supported public network preflight and consume a finalized promoted
   manifest; complete Pyth sequencer attestation at the same time (L-04 through L-06).
5. Strengthen provider independence evidence and the security-critical coverage
   inventory (L-03 and L-07).
6. Apply the four informational hardening items in isolated follow-up commits.

## Research sources

- Chainlink,
  [Robinhood tokenized-equity feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood)
- Chainlink,
  [L2 sequencer uptime feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds)
- Robinhood Chain,
  [connection and RPC guidance](https://docs.robinhood.com/chain/connecting/)
- Robinhood Chain,
  [canonical contracts](https://docs.robinhood.com/chain/contracts/)
- Pyth,
  [EVM contract addresses](https://docs.pyth.network/price-feeds/core/contract-addresses/evm)
- Pyth,
  [price-feed best practices](https://docs.pyth.network/price-feeds/core/best-practices)
- Pyth,
  [fetching authenticated price updates](https://docs.pyth.network/price-feeds/core/fetch-price-updates)
- OpenZeppelin,
  [access-control and timelock guidance](https://docs.openzeppelin.com/contracts/5.x/access-control)
