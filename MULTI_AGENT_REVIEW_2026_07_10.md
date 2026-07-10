# YieldShield Smart-Contract Multi-Agent Review — July 10, 2026

## Executive summary

This review found **no confirmed Critical or High-severity vulnerability** in the
current protocol contracts. The core accounting, oracle fail-closed behavior,
upgrade freeze, governance ownership, and storage-layout defenses remain materially
stronger than in the earlier review snapshots.

The review confirmed **six Medium findings**, **seven Low findings**, and **four
Informational inconsistencies**. The most important open issue is an economic edge
case specific to 24/5 Robinhood stock-token price discovery: a transferable token can
be deposited during a still-fresh off-hours oracle window after public information has
made the last market price predictably stale. The next most important issues are in
the production deployment path: script-size handling, partial-deployment recovery,
contract-size enforcement, Pyth's July 31 authenticated-Hermes migration, and a
mainnet-capable sequencer-feed opt-out.

Three verification defects were fixed as part of this review:

1. `foundry.lock` now matches the checked-out OpenZeppelin submodule revisions.
2. Every CI job that compiles the npm-installed Pyth Solidity dependency now runs
   `npm ci` first.
3. The protector-token invariant now distinguishes active backing from separately
   reserved expired-epoch backing.

The inaccurate model attribution in the two July 4 review documents was also
corrected. Their July 4 dates are historically correct and were not renamed.

### Finding count at the reviewed baseline

| Severity      | Open | Fixed in this delivery |
| ------------- | ---: | ---------------------: |
| Critical      |    0 |                      0 |
| High          |    0 |                      0 |
| Medium        |    6 |                      0 |
| Low           |    7 |                      0 |
| Informational |    4 |                      3 |

## Scope and attribution

- Reviewed baseline: `2ee6918317947d38fc5890a7569bbea6a04bec49` on `main`.
- Solidity scope: `contracts/`, production deployment scripts, oracle update tooling,
  governance, invariants, CI security gates, and deployment metadata behavior.
- Prior findings rechecked: the July 2, July 4, July 4 follow-up, and July 6 reports.
- Review system: **Codex/GPT-5**, with three parallel review agents covering (1) core
  contracts and accounting, (2) deployment/tooling/CI, and (3) external research and
  repository history. The primary agent independently reproduced and triaged the
  material findings before inclusion.
- This is a defensive review of the author's own public repository. It is not a
  commissioned audit and does not replace an independent professional audit before
  material value is placed at risk.

## Authorship check

The public evidence strongly supports the requester's authorship of this repository:

- The baseline history contains 507 reachable commits: 293 authored as `David Hawig`,
  175 as `Noc2`, and 39 Dependabot commits.
- GitHub's contributor view attributes all 468 non-bot commits to the public
  [`Noc2`](https://github.com/Noc2) account, whose public profile name is David Hawig.
- The root commit and the reviewed baseline both map to that account.
- Thirty-three contract `@author` tags name David Hawig.
- The public repository is [`YieldShield/smart-contracts`](https://github.com/YieldShield/smart-contracts),
  and its default branch is `main`.

This establishes a strong public repository-history link. It does **not** prove civil
identity, legal IP ownership, sole authorship of any material imported before the root
commit, or control of the GitHub organization. The commits inspected were not
cryptographically signed, so the conclusion should be described as repository
attribution rather than legal identity verification.

## Confirmed Medium findings

### M-01 — A still-fresh 24/5 stock price permits off-hours adverse selection

**Category:** economic/oracle design

**Affected:** `contracts/oracles/RobinhoodStockOracleFeed.sol:63-78`,
`contracts/oracles/ChainlinkOracleFeed.sol:435-453`,
`contracts/SplitRiskPool.sol:1923-1974`, `contracts/SplitRiskPool.sol:2033-2104`,
`contracts/libraries/ConstantsLib.sol:78`,
`script/DeployYieldShieldProduction.s.sol:561-562`

The stock wrapper checks the token's `oraclePaused()` corporate-action flag and the
inner Chainlink adapter checks freshness, but neither proves that the reference market
is currently discovering prices. Robinhood documents stock tokens as ordinary
transferable ERC-20s, while Chainlink documents US equity feeds as 24/5 rather than
24/7. The production default permits an answer up to 86,400 seconds old.

An adverse-selection window therefore exists after price discovery stops but before
the last answer exceeds the age limit. If material negative information becomes
public in that window, a user can acquire or already hold the transferable stock token,
deposit it at the last market price, and lock that price in `valueAtDeposit`. After the
one-day minimum pool time, a cross-asset withdrawal uses the stored value and current
backing-token price. The subsequent market repricing is borne by protectors even
though the loss was public before the protection position was opened.

This is not a conventional stale-oracle bypass—the answer can satisfy the configured
age rule. It is a mismatch between 24/7 token transferability and 24/5 price discovery.

**Recommendation:** Add a market-session/holiday eligibility gate for opening or
increasing shielded stock positions. At minimum, reject new stock-token protection
when the reference venue is closed, even if the last answer is technically fresh.
Retain per-token max ages as a second layer rather than the primary control. Define
explicit behavior for early closes and exchange holidays and add boundary tests.

### M-02 — The production deploy helper does not handle Robinhood's script-size reality

**Category:** deployment availability

**Affected:** `scripts-js/parseArgs.js:201-206`,
`scripts-js/__tests__/parseArgs.test.cjs:135-148`, `README.md:148-150`,
`script/DeployYieldShieldProduction.s.sol`

`DeployYieldShieldProduction` has approximately **303,900 bytes** of runtime code in
the local build. Foundry's script runner applies a roughly 24 KiB default code-size
limit unless `--disable-code-size-limit` is used. The helper adds that flag only for
the relaxed Robinhood testnet mode; strict testnet, Robinhood mainnet, and the other
public production paths deliberately receive no override.

The deployed pool and factory are below Robinhood Chain's documented 96 KiB runtime
limit, but the local script contract is much larger than both Ethereum's limit and
Robinhood's target-contract limit. Conflating runner code with deployed target code
can prevent a strict rehearsal or mainnet run before the target-contract checks are
useful. The README also warns that a successful broadcast may still produce a
non-zero wrapper exit, which increases deployment ambiguity.

**Recommendation:** Split the production script into smaller phases, or explicitly
apply a runner-only code-size override to both Robinhood networks while independently
enforcing Robinhood's 96 KiB runtime and 192 KiB initcode limits on every deployed
target. Add a non-broadcast strict Robinhood command to CI.

### M-03 — Partial broadcast recovery can mix deployment generations

**Category:** deployment integrity

**Affected:** `script/DeployHelpers.s.sol:27-35`,
`script/DeployHelpers.s.sol:115-168`,
`script/DeployYieldShieldProduction.s.sol:595-615`,
`script/DeployYieldShieldProduction.s.sol:820-923`,
`script/DeployYieldShieldProduction.s.sol:1240-1246`,
`test/DeploymentSecurity.t.sol:1373-1375`

The deployment JSON is exported only after the runner finishes successfully. A public
broadcast, however, can leave accepted transactions on-chain before a later
transaction or post-check fails. On a rerun, the exporter preserves addresses from the
existing JSON and overlays only names present in the current `deployments` array.

The final Robinhood demo validation accepts any non-zero pool count and non-empty
whitelist, while the complete test fixture expects nine pools and ten tokens. The
protocol finalizer records the six core protocol addresses, while governance, demo
assets, feeds, and pools are accumulated through separate paths. A failure after a
partial seed can therefore leave on-chain state that is accepted as "seeded," while a
later export combines current core addresses with stale addresses from a previous
generation.

**Recommendation:** Make manifests generation-scoped and atomic. Record a deployment
ID, chain ID, deployer, expected codehashes, governance addresses, every configured
asset/feed/pool, and an exact configuration digest. Recovery should reconstruct and
validate the complete generation from broadcast receipts; it should never silently
merge unverified prior entries. Validate exact demo counts and identities, not merely
non-empty state.

### M-04 — Pyth price-update automation is not ready for the July 31 auth cutover

**Category:** oracle-update availability

**Affected:** `scripts-js/update-pyth-prices.cjs:419-420`,
`scripts-js/update-pyth-prices.cjs:560-571`,
`scripts-js/update-pyth-prices.cjs:648-660`, `.env.example`,
`contracts/oracles/PythConfig.sol:15-23`

Pyth's current migration guidance states that every Hermes user will require an API
key for the July 31 upgrade and recommends the Douro Labs endpoint plus an
`accessToken`. The repository hardcodes `https://hermes.pyth.network/`, constructs both
Hermes clients without an access token, and documents no `PYTH_API_KEY`.

Pyth also publishes upgraded Arbitrum contract addresses for new deployments. The
checked-in addresses are the legacy/current addresses; Pyth says existing deployments
will auto-upgrade, so this is not an immediate on-chain correctness bug. It is an
upcoming updater availability failure and a deployment-default inconsistency. The
Robinhood Chain path is Chainlink-native and is unaffected.

**Recommendation:** Add a required `PYTH_API_KEY`, a configurable Hermes URL, and
`accessToken` to both client constructors. Exercise authenticated fetching in CI with a
mocked secret boundary. Plan a dual-endpoint/cutover runbook, update new-deployment
address defaults to Pyth's upgraded contracts after verification, and pin fork tests
for both pre- and post-upgrade behavior.

### M-05 — Contract-size exceptions have become non-enforcing budgets

**Category:** portability/release control

**Affected:** `scripts-js/checkContractSizes.js:16-27`, `.github/workflows/ci.yml`

The local size gate reports:

| Contract               |  Runtime | Initcode | Tracked runtime ceiling |
| ---------------------- | -------: | -------: | ----------------------: |
| `SplitRiskPool`        | 45,653 B | 45,920 B |                43,000 B |
| `SplitRiskPoolFactory` | 41,256 B | 41,523 B |                41,000 B |

Both contracts exceed EIP-170's Ethereum runtime limit and now also exceed the
repository's explicit exception ceilings by 2,653 and 256 bytes respectively. CI sets
`CONTRACT_SIZE_REPORT_ONLY=true`, so it reports success even when those project-owned
ceilings regress. Robinhood's larger limits make the current artifacts deployable
there, but the advertised Arbitrum/Base-style public-network paths are not portable and
the regression budget does not currently protect Robinhood headroom either.

**Recommendation:** Keep the general EIP-170 result report-only only where a chain
exception is intended, but make the explicit per-contract ceilings hard failures.
Define per-chain runtime and initcode budgets. Longer term, split pool/factory logic
into libraries or modules rather than allowing unbounded growth.

### M-06 — A shared environment flag can disable the mainnet sequencer guard

**Category:** production configuration safety

**Affected:** `.env.example:38-41`, `scripts-js/parseArgs.js:175-187`,
`script/DeployYieldShieldProduction.s.sol:677-700`

The environment template describes the missing-sequencer opt-out as testnet-only, but
the same `YS_ROBINHOOD_ALLOW_MISSING_SEQUENCER_FEED=true` flag satisfies the helper and
disables `sequencerUptimeFeedRequired` on Robinhood mainnet. A reused testnet shell or
CI environment can therefore create a mainnet deployment without the intended
fail-closed L2 availability check.

Robinhood's documentation recommends a sequencer check, but the review could not find
a canonical on-chain aggregator address in its published address material. The
documented WebSocket "sequencer feed" is an RPC endpoint and must not be supplied as an
oracle contract address.

**Recommendation:** Limit the opt-out to chain ID 46630. Mainnet should require an
explicit, code-bearing address whose interface and current behavior are probed and
whose source is recorded in the deployment manifest. If Robinhood has not published a
canonical feed, block mainnet stock-pool activation rather than carrying the testnet
exception forward.

## Confirmed Low findings

### L-01 — Governance can set a proposal threshold above the irreducible supply

`YSGovernor` permits a threshold up to 100,000 YS
(`contracts/YSGovernor.sol:35-36,106-115`), while `YSToken` permits supply to be burned
down to just over 10,000 YS (`contracts/YSToken.sol:15-16,58-65`). Governance can first
raise the threshold and holders can later burn enough supply that no account can ever
propose the transaction needed to lower it.

Couple the burn floor to the current proposal threshold, limit the threshold to an
irreducible fraction of supply, or retain a narrowly-scoped, timelocked recovery path.
Add a stateful test covering threshold changes followed by distributed burns.

### L-02 — An unbounded active-pool cap amplifies linear governance work

`setMaxActivePools` has no upper bound
(`contracts/SplitRiskPoolFactory.sol:1106-1120`). Several governance validation paths
scan every whitelisted token or active pool
(`contracts/SplitRiskPoolFactory.sol:1303-1401`). Governance can raise the cap and
permissionless creators can fill it, eventually making oracle/feed administration too
expensive for a block.

Set a benchmarked maximum, use cursor-based/batched validation, and include worst-case
gas tests at the supported cap.

### L-03 — The invariant suite tolerates too many ineffective calls

`foundry.toml:72-75` uses `fail_on_revert = false`; handler actions catch many failed
calls; and `invariant_rewardPerShareNonNegative` only asserts that a `uint256` is not
negative (`test/SplitRiskPoolInvariant.t.sol:687-694`). A focused run executed 128,000
handler calls with no framework reverts, but successful path counts were low (for
example, 18/14 deposits, 23/7 withdrawals, 12 commission actions, and 5 reward
actions). The accounting invariants that do execute are useful, but the call volume
overstates reachable-path coverage.

Add success/revert counters with `afterInvariant` minimums, enable Foundry invariant
metrics, and maintain a smaller bounded suite with `fail_on_revert = true`.

### L-04 — The documented Robinhood RPC environment variable is not the Foundry source

`.env.example:18-20` documents `ROBINHOOD_TESTNET_RPC_URL`, while `foundry.toml:40-41`
hardcodes a public endpoint. The JavaScript helper recognizes the environment value,
but direct Foundry commands do not inherit it through the named endpoint.

Wire the RPC endpoint to the environment variable consistently and keep the public,
rate-limited RPC only as an explicit development fallback.

### L-05 — Seeded Robinhood mock feeds expire after one day

The production testnet seeder creates fixed `MockChainlinkAggregator` answers at
deployment time (`script/DeployYieldShieldProduction.s.sol:820-841`), while the
production adapter's maximum accepted age is 86,400 seconds. No keeper or documented
refresh process updates these mocks, so the checked-in demo configuration stops being
usable roughly one day after deployment.

Use real testnet feeds when available or add an explicit demo-feed updater/keeper and
health check. Mark mock-backed deployments as expiring test fixtures in the manifest.

### L-06 — Strict Robinhood testnet still seeds demo assets by default

`_robinhoodTestnetDemoAssetsRequested` defaults to true for chain 46630 regardless of
strict-production mode (`script/DeployYieldShieldProduction.s.sol:703-705`). The README
describes strict mode as a production rehearsal and separately describes a flag to
seed the demo. A strict run is therefore not production-shaped unless the operator
knows to negate an implicit default.

Default demo seeding to false whenever strict guards are enabled. Require an explicit
seed flag and make the helper print the selected mode before simulation.

### L-07 — The blocking Slither gate is pinned behind the reviewed detector set

The blocking job pins Slither 0.10.3. Its exact `--fail-high` command passes, but the
same command on locally installed Slither 0.11.5 exits non-zero because newer releases
add `reentrancy-balance` and Pyth-specific publish-time/confidence analysis. The
reported paths were manually triaged as false positives in this review, but the
version gap means new detector coverage is not part of the continuous gate and a
future unplanned upgrade will turn CI red.

Upgrade Slither deliberately, retain the 0.11.5 output as a baseline artifact, and add
narrow source-level suppressions only where the detector's exact path is covered by a
regression test. Do not globally exclude the new detector families.

## Informational inconsistencies

### I-01 — `getValueWithFallback` is intentionally more fail-closed than its name implies

`CompositeOracle.getValueWithFallback` still rejects unresolved active-feed deviation
before it can use a fallback (`contracts/oracles/CompositeOracle.sol:1235-1295`). This
is a defensible security choice, but the name and interface NatSpec imply broader
availability. Rename it or document precisely which primary failures are recoverable.

### I-02 — Two internal oracle helpers are dead code

`SplitRiskPool._tryGetProtectedBackingValue`
(`contracts/SplitRiskPool.sol:730-735`) and
`CompositeOracle._calculateFeedDeviation`
(`contracts/oracles/CompositeOracle.sol:549-560`) have no live call sites. Remove them
or add a comment explaining their planned use so future reviewers do not mistake them
for active defenses.

### I-03 — GitHub Actions use mutable major-version tags

The workflow uses tags such as `actions/checkout@v6` and `actions/setup-node@v6` rather
than immutable commit SHAs. GitHub recommends pinning third-party actions to full SHAs
for the strongest supply-chain boundary. Dependabot can still update those pins.

### I-04 — Resolved: the first July 4 report's stated unique count did not match its IDs

The report previously said 18 unique findings and listed 11 Informational items, but
its visible IDs enumerate 17 items: 1 Medium, 6 Low, and 10 Informational. The table
and footer now match those IDs. This was a report-accounting inconsistency, not a
missing current-code finding; no finding IDs or historical commits were rewritten.

## Resolved during this review

### R-01 — CI security jobs compiled without installing the Pyth npm dependency

The baseline GitHub Actions run
[`29079756152`](https://github.com/YieldShield/smart-contracts/actions/runs/29079756152)
failed before meaningful analysis: checks failed the stale Foundry lock, while coverage,
Slither, the Slither gate, and Aderyn could not resolve
`node_modules/@pythnetwork/pyth-sdk-solidity`. The fork job would have had the same
problem when secrets were present.

This delivery updates the two OpenZeppelin revisions in `foundry.lock` and adds Node
setup plus `npm ci` to every affected job. This restores the intended verification
preconditions; it does not waive any scanner result.

### R-02 — The July 4 reviews had inaccurate model attribution

`DESIGN_REVIEW_2026_07_04.md` and
`DESIGN_REVIEW_2026_07_04_FOLLOWUP.md` incorrectly claimed that their sessions and
subagents ran on Claude Fable 5. The requester confirmed those runs used Claude Opus
4.8. Both files now carry a dated correction. The old commit message is left intact to
avoid rewriting published `main` history. The filenames remain July 4 because Git
history confirms that is when those reviews were created.

### R-03 — The total-token invariant mixed active and expired protector backing

A final randomized run found a minimized four-call counterexample at fuzz seed
`0xff416612dd09d2e1b3f4c885c4040776fee2ac5ee1c3c14d300abc80a2a01de6`. After a
shield activation left protector backing dust, a later deposit correctly moved the old
dust into `protectorEpochBackingRemainingReserve` and started a new active epoch. The
invariant summed both the expired claim and the new active claim, then compared that
combined value only with active `totalProtectorTokens`.

The contract accounting was correct; the test modeled two ledgers as one. The
invariant now sums current-epoch claims against `totalProtectorTokens`, sums old-epoch
claims against their remaining reserves, and applies a separate rounding-dust bound to
each. The exact seed is retained here as regression evidence.

## Prior-review re-verification

The earlier High findings—upgrade authorization that reverted and an unresettable
transfer-intent state—remain closed. The subsequent reserve accounting, settlement,
strict oracle validation, sequencer timestamp handling, codehash pinning, governance
bootstrap, fee-on-transfer rejection, and storage-layout remediations remain present.

The July 6 findings around redeemable ERC-4626 floors, strict deployment preservation,
staleness, creation-bond recovery, and Pyth npm imports are also implemented. The npm
import itself was correct; the missing per-job installation in CI is the separate
R-01 issue above.

Two prior residuals remain intentional/documented rather than exploitable:

- `CompositeOracle.getValueWithFallback` remains fail-closed on unresolved deviation
  (I-01).
- Cross-asset withdrawal re-probes the backing oracle and can fail closed during an
  oracle outage. That is a deliberate solvency choice, not a bypass.

## Static-analysis triage

Local Aderyn 0.6.8 completed 88 detectors and emitted four generic High alerts. Local
Slither 0.11.5 completed 74 detectors and emitted its generic oracle/reentrancy set.
The following apparent High patterns were rechecked and were **not** confirmed as
exploitable findings:

- **Locked ETH:** pool and factory `receive`/`fallback` functions explicitly revert.
- **Unchecked ETH send:** Pyth refunds either `msg.sender` or an explicit non-zero
  recipient, checks success, and performs no vulnerable state mutation afterward.
- **XOR arithmetic:** the bitwise operation is the standard FullMath modular inverse.
- **Reentrancy:** value-moving external paths are `nonReentrant`; remaining external
  calls are governance-only, factory-pinned, codehash-pinned, or cached probes. No
  attacker-controlled callback path was found that violates accounting.
- **Pyth validation order:** publish time, age, confidence, and sign/exponent checks are
  applied before a price is accepted by a state-changing protocol path.

These are tool false positives on the reviewed code. Scanner jobs should continue to
run; suppressions should remain narrow and accompanied by executable regression tests.

## Verification evidence

The following checks were run against the reviewed tree:

- `forge fmt --check` — pass.
- `npx prettier --check "scripts-js/**/*.{js,cjs}"` — pass.
- `npm run test:scripts` — 34/34 pass.
- `forge build --offline` — pass.
- `forge test --offline` — 46 suites; 1,057 passed, 0 failed, 4 skipped after the
  expired-epoch invariant correction in R-03. The previously failing fuzz seed also
  passes directly.
- `bash scripts-js/check-storage-layout.sh` — `SplitRiskPool` and
  `SplitRiskPoolFactory` snapshots pass.
- `npm run size-check` — correctly fails on the size regressions recorded in M-05.
- Aderyn 0.6.8 and Slither 0.11.5 — completed; High-looking generic results triaged
  above. The exact CI-pinned Slither 0.10.3 `--fail-high` command passes; the newer
  scanner's gate behavior is recorded in L-07.
- Read-only checks of the checked-in Robinhood testnet deployment found the factory
  owned by the timelock, nine pools, bootstrap mode disabled, the composite oracle
  owned by the factory, and no residual authorized callers.

Fork tests were not executed because no authenticated fork RPC secret was available in
the review environment. The GitHub workflow detects that condition and reports the
fork suite as skipped rather than pretending it ran.

## Recommended remediation order

1. Gate new Robinhood stock protection by real market-session eligibility (M-01).
2. Make the deployment run generation-atomic and production-script-size safe
   (M-02/M-03).
3. Implement authenticated Pyth Hermes access before July 31 (M-04).
4. Turn explicit contract-size ceilings back into hard gates (M-05).
5. Remove the mainnet sequencer opt-out and pin a verified feed (M-06).
6. Couple governance threshold and burn floors; then bound/batch pool scans
   (L-01/L-02).
7. Strengthen invariant path-effectiveness assertions (L-03).
8. Upgrade and baseline the blocking Slither release (L-07).

## Primary research sources

- Pyth, [EVM pull integration](https://docs.pyth.network/price-feeds/core/use-real-time-data/pull-integration/evm)
- Pyth, [price-feed best practices](https://docs.pyth.network/price-feeds/core/best-practices)
- Pyth, [preparing for the July 31 upgrade](https://docs.pyth.network/price-feeds/core/upgrade/preparing)
- Pyth, [EVM contract addresses](https://docs.pyth.network/price-feeds/core/contract-addresses/evm)
- Chainlink, [L2 sequencer uptime feeds](https://docs.chain.link/data-feeds/l2-sequencer-feeds)
- Chainlink, [selecting data feeds and market hours](https://docs.chain.link/data-feeds/selecting-data-feeds)
- Robinhood Chain, [oracles and price feeds](https://docs.robinhood.com/chain/oracles-and-price-feeds/)
- Robinhood Chain, [building with stock tokens](https://docs.robinhood.com/chain/building-with-stock-tokens/)
- Robinhood Chain, [connecting and RPC limitations](https://docs.robinhood.com/chain/connecting/)
- Robinhood Chain, [differences from Ethereum](https://docs.robinhood.com/chain/differences-from-ethereum/)
- Arbitrum, [block numbers and time](https://docs.arbitrum.io/arbitrum-essentials/arbitrum-vs-ethereum/block-numbers-and-time)
- OpenZeppelin, [access control](https://docs.openzeppelin.com/contracts/5.x/access-control)
- OpenZeppelin, [governance](https://docs.openzeppelin.com/contracts/5.x/governance)
- Solidity, [security considerations](https://docs.soliditylang.org/en/latest/security-considerations.html)
- Foundry, [invariant testing](https://getfoundry.sh/forge/invariant-testing)
- Ethereum, [EIP-170 contract code-size limit](https://eips.ethereum.org/EIPS/eip-170)
- Ethereum, [EIP-4626 tokenized vaults](https://eips.ethereum.org/EIPS/eip-4626)
- GitHub, [secure use of GitHub Actions](https://docs.github.com/en/actions/reference/security/secure-use)
- Uniswap, [V3 OracleLibrary reference implementation](https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol)

---

_Generated by a Codex/GPT-5 multi-agent review. Findings are based on the July 10,
2026 repository snapshot and primary-source research available on that date._
