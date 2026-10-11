# YieldShield smart-contracts audit — 2026-10-11

## Scope and baseline

Reviewed the current `main` revision `414cc3abfc55b20bab32780032f2bdc68cd6c6dd` of `YieldShield/smart-contracts`. The scope included production Solidity contracts, receipt NFTs, fee/epoch accounting, factory lifecycle and governance, oracle/token integration, deployment tooling, pinned dependencies, tests, and downstream interface compatibility. Vendor libraries were treated as pinned dependencies, not re-audited in full. Read-only public-chain fork checks were used; no transactions were broadcast.

Work combined independent agent reviews, local behavioral regressions, existing fuzz/invariant suites, Slither, Aderyn, dependency advisories, storage-layout checks, and deployment-size checks. Two agent runs were interrupted by automated screening; their preliminary observations were independently validated before inclusion. This is a source-code review with reproducible tests, not a certification that all vulnerabilities have been found.

## Confirmed findings and separate fixes

| ID | Severity | Finding | Fix commit |
| --- | --- | --- | --- |
| YS-01 | Medium | Protector commission fractions could be allocated twice, and current claims could consume historical reserves | `6fd1825` |
| YS-02 | Medium | Factory governance migration count stayed complete after a staged pool transfer was canceled | `acd82e8` |
| YS-03 | Medium | Direct stock oracle configurations did not enforce their protection-opening policy | `8595751` |
| YS-04 | Low | Production CompositeOracle lacked decimals metadata required by the ERC4626 underlying-price integration | `108a94d` |
| YS-05 | Low (tooling exposure) | Unneeded shx dependency introduced a braces denial-of-service advisory into development tooling | `95e0198` |
| YS-06 | Low (test correctness) | Robinhood fork smoke expected the wrong stale-price error during normal closed-market conditions | `c2e0272` |

### YS-01 — commission conservation

`_accumulateProtectorReward` and `_tryDistributePendingProtectorRewardDust` rounded the amount represented by an index increment down, while retaining the fractional credit in the index. The same fraction could subsequently be redistributed as whole-token dust. New and partially withdrawn receipts also rounded reward debt down, allowing multiple positions to acquire fractions predating their shares. Claims/forfeitures were globally capped but current-epoch entitlements were not capped by the current epoch's reserve.

Before the fix, an ordinary local accrual sequence produced an entitlement of 228,494 native units against a reserve of 228,485. With a historical epoch present, a current claim paid 228,495 against 228,485 current units. The absolute impact depends on token granularity, share distribution, and repeated operations; these values do not establish loss in any deployed pool.

The fix rounds consumed index credit and new/reset reward debt upward and caps entitlement by the position's own epoch reserve. Unclaimable fractional units remain funded until the existing orphan-reserve settlement. No storage fields or external function signatures changed.

Regression evidence: `AuditRewardRounding.t.sol`, `ProtectorRewardConservation.t.sol`, `ProtectorRewardDebt.t.sol`, and updated existing commission/fuzz tests. Tests cover multiple claim orders, late deposits, partial exits, dust redistribution, and historical reserve isolation. Commit `9e068d1` aligns older assertions with the corrected conservative rounding; it does not change production code.

### YS-02 — governance migration tracking

Factory staging decremented a cached remaining-pool count. Cancellation cleared the pool target without restoring that count. In addition, repeating a direct pool setter with the same target cleared its factory-staged guard, and factory pagination could count a directly staged pool without adopting that guard. These paths allowed factory acceptance while a pool could no longer complete the intended migration. They require legitimate governance actions, not unauthorized ownership acquisition.

The fix invalidates the canceled pool's tracking marker and restores the count exactly once, adopts direct staging into factory control, and preserves the guard on same-target restaging. Three regressions failed before the fix and pass afterward; cancellation/restaging and existing multi-page migration tests also pass. Storage layout is unchanged.

### YS-03 — direct oracle opening policy

A pool governance update could select `RobinhoodStockOracleFeed` directly. Price validation accepted the feed, but opening checks only queried the composite-router policy marker. The direct feed's capability marker was not recognized, so a closed session could still accept a new shielded position.

The fix recognizes the direct `IProtectionOpeningEligibility` marker and enforces its status. Advertised policies with unavailable or malformed responses fail closed. Legacy feeds without either capability remain supported. `DirectOracleOpeningPolicy.t.sol` covers open/closed sessions, emergency pause, stale opening quotes, failed status, and malformed booleans. The default factory route already used CompositeOracle; the finding concerns supported direct-oracle configuration/migration.

### YS-04 — composite metadata and composition boundary

`ERC4626OracleFeed` validates underlying-oracle decimals in its constructor/setter. The production CompositeOracle normalized to eight decimals but exposed no decimals getter. Existing integration tests worked around this with a test-only subclass, hiding the production failure.

The fix exposes `decimals() == 8` and uses the production contract in integration tests. Direct nesting of CompositeOracle as a configured feed is rejected because pool collateral and optional-policy inspection supports one router layer. An ERC4626 feed can still use CompositeOracle to price its underlying asset. Constructor, migration, primary/backup route, and self-reference tests cover that boundary.

### YS-05 — development dependency reduction

The only use of shx was copying `.env.example` once. Removing it eliminates the `shx → shelljs → fast-glob → micromatch → braces` chain. A built-in Node filesystem copy preserves an existing file or symlink and propagates unexpected errors. Local creation/preservation checks pass; the refreshed full dependency audit reports zero advisories. The upstream advisory is rated high, but this repository uses a fixed local pattern with no demonstrated untrusted-pattern entry point, so repository exposure is classified low.

Advisory: https://github.com/advisories/GHSA-vfj7-8cjw-p6xm

### YS-06 — normal stale-price fork behavior

The live read-only Robinhood smoke reached the normal stale-price path and expected the three-argument Chainlink error. Timestamp staleness is actually enforced by `OracleValidationLib.StalePrice(token, updatedAt, maxAge, currentTime)`. The test now asserts that exact error. The corrected fork test passes; production price checks are unchanged.

## Verification results

Verification used Solidity 0.8.35, Foundry 1.7.1, and Node.js 24.14.0.

| Check | Result |
| --- | --- |
| Complete offline Solidity suite | 1,233 passed, 0 failed, 7 optional network skips (60 suites) |
| Coverage run (`--ir-minimum`, 16 invariant runs × 64 calls; gas-only suite excluded) | 1,223 passed, 0 failed, 7 optional skips |
| Production coverage policy | Passed for 29 contracts: 86.88% lines (4,563/5,252), 56.94% branches (722/1,268) |
| Deterministic invariant reachability, seeds `0x01`, `0x02`, `0x03` | 28 passed per seed; required handler paths reached |
| JavaScript deployment/tooling suite | 147 passed |
| Public RPC fork smoke checks | Arbitrum mainnet, Arbitrum Sepolia, Robinhood mainnet passed |
| Pool/factory storage-layout checks | Passed; no storage changes |
| Foundry dependency gitlink/lock consistency | Passed for all four pins |
| Robinhood deployment size policy | Passed for all 16 production targets |
| npm full dependency audit | Zero reported advisories after removal of shx |
| Solidity and JavaScript formatting | Passed |

The full Solidity suite uses the repository's standard fuzz/invariant settings. The separate coverage run deliberately reduces invariant workload and excludes `FactoryLinearScanGas.t.sol` because instrumentation changes gas measurements. Coverage percentages are measured evidence, not proof of safety; the lower branch coverage remains a review limit.

## Static analysis triage

Slither 0.11.5 analyzed 160 contracts with 74 detectors: **0 high, 121 medium, 72 low raw findings**. The high-severity gate passed. The remaining findings are not automatically confirmed vulnerabilities:

- 64 strict-equality warnings cover zero-balance/empty-state sentinels, exact receipt IDs, and exact-transfer integrity checks. Those comparisons are intentional.
- 23 reentrancy-without-ETH warnings point to guarded pool entrypoints, internal calls reached through those guards, and governance-only calls into pinned/trusted protocol components. Receipt mint callbacks are covered by existing callback/reentrancy tests.
- Nine Pyth confidence/publish-time warnings miss validation in helper functions: `_readPythPrice` validates future time, age, and confidence; EMA reads validate age and confidence; staleness probes ultimately validate protected pricing.
- Seven uninitialized-local warnings concern Solidity zero initialization or assignments in guarded try/catch paths. Eighteen unused-return warnings concern intentionally discarded tuple fields or return values from operations whose required failure signal is a revert.
- Low findings include bounded/paginated loops, event ordering, local shadowing, and zero-address checks. No additional reproducible defect was established from these categories.

Aderyn analyzed 45 production source/interface files (9,652 nonblank source lines at the initial scan). Its five high categories were manually triaged: direct ETH receive handlers revert; Pyth refunds return the caller's excess payment; the FullMath XOR is intentional modular-inverse arithmetic; reported reentrancy sites have the guards/trust boundaries above; weekday modulo arithmetic is not a randomness source. Its low categories remain informational maintenance observations, not a clean static-analysis claim.

## Deployment and review limits

- Existing deployments have **not** changed. Pool and factory upgrade authorization is disabled. Applying these fixes on-chain requires reviewed fresh deployment and position/liquidity migration; changing a repository pin or ABI cannot patch deployed bytecode.
- Pool/factory monoliths remain above the standard EIP-170 runtime limit. The existing deployment policy blocks unsupported chains and permits the reviewed Robinhood limits. This audit did not perform a size-reduction redesign or authorize a production deployment.
- Mainnet readiness still depends on correctly configured timelocks, market calendars/guardian, supported token behavior, trusted oracle sources/updaters, sequencer protection, and operational monitoring. Read-only smoke checks do not validate all production configuration or every market condition.
- Seven opt-in network tests are skipped by the offline suite. Arbitrum mainnet/Sepolia and Robinhood mainnet smoke tests were additionally run explicitly. Optional Ethereum/Sepolia suites requiring configured provider endpoints were not run.
- No formal verification, live-value adversarial transaction, exhaustive economic simulation, or full audit of OpenZeppelin/Pyth/Uniswap dependencies was performed. The changes reduce identified risks; absence of additional findings is not a guarantee.
