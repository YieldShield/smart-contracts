# Security Policy

YieldShield is a smart-contract protocol. Please treat suspected vulnerabilities
as sensitive until they have been triaged and remediated.

## Supported Code

Security reports should target the current `main` branch unless maintainers
explicitly identify another supported release or deployment.

In scope:

- Solidity contracts under `contracts/`
- Deployment and verification scripts under `script/`
- Oracle integrations and supporting libraries
- Build, test, and security tooling that can affect contract verification

Out of scope:

- Third-party dependencies under `lib/`, except when a pinned dependency version
  creates a vulnerability in YieldShield contracts
- Issues requiring leaked private keys, privileged account compromise, or
  malicious maintainer behavior

## Reporting a Vulnerability

Do not open a public issue with exploit details.

Use GitHub private vulnerability reporting for this repository if it is enabled.
If private reporting is unavailable, open a minimal public issue asking for a
security contact without including technical details.

Please include:

- A concise description of the issue
- Affected contracts, scripts, or deployments
- Steps to reproduce or a proof of concept
- Expected impact and severity
- Suggested remediation, if known

## Local Security Checklist

Run these checks before opening or merging security-sensitive changes:

```sh
forge build --offline
forge test --offline
forge fmt --check
```

Run static analysis when changing contract logic:

```sh
make slither
make aderyn
```

The local Slither target is report-only for detector findings: it writes the
full checklist to `slither-report.md` and uses `--fail-none`. Tool startup,
configuration, compilation, and analyzer crashes still return a non-zero exit
status so a broken analysis cannot appear successful.

In CI, Slither's dedicated high-severity job is the blocking static-analysis
gate. Aderyn is uploaded as a report-only artifact for manual triage unless a
separate Aderyn severity gate is intentionally added later.

Run coverage when changing core accounting, pool, oracle, receipt NFT, or
governance behavior:

```sh
forge coverage --ffi --report summary
```

Document triaged security findings in a dated note under
`docs_ok/security/analyses/` or in the relevant launch/security document.

## Known Trust Assumptions

These are deliberately accepted properties of the design, not bugs. They
constrain who is trusted with what during specific lifecycle phases.

### Bootstrap-holder concentration (pre-distribution)

`YSToken` mints `INITIAL_SUPPLY` (1,000,000 YS) to a single bootstrap holder
(production: a 2-of-N Safe), and self-delegates. `YSGovernor`'s
`proposalThreshold` is 10,000 YS and `MIN_QUORUM_VOTES` is 10,000 YS — so the
bootstrap Safe controls 100% of voting power and trivially meets quorum on
its own.

Consequence: until YS tokens are broadly distributed, the bootstrap Safe can
unilaterally pass any proposal to change oracle policy, alter NFT transfer
locks, install a new (potentially malicious-but-validly-shaped) governance
timelock, or transfer factory/NFT ownership. It cannot repoint live pool or
factory logic through the UUPS upgrade path because those entrypoints are
disabled on-chain. The remaining protections are:

- pool and factory UUPS upgrade entrypoints are disabled on-chain; future logic
  changes require a fresh deployment rather than repointing live user funds.
- a `MIN_PUBLIC_GOVERNANCE_DELAY = 2 days` on timelock changes (gives the
  community a withdraw-window if a malicious proposal slips through),
- `_validateGovernanceTimelock`'s enumeration check (H-8) requiring a fresh
  timelock to have exactly one DEFAULT_ADMIN_ROLE member equal to itself,
- the Safe-shape requirement on the bootstrap holder (≥2 owners, threshold
  ≥2; production-validated by `_validateProductionBootstrapHolder`).

Anyone evaluating protocol risk pre-distribution should assume that the
bootstrap Safe's quorum is the trust boundary. After tokens are distributed
broadly enough that the bootstrap holder no longer controls quorum, normal
governance dynamics apply.

### ReentrancyGuard storage under disabled upgrades

`ProtocolAccessControlUpgradeable` inherits OpenZeppelin's plain
`ReentrancyGuard` storage rather than `ReentrancyGuardUpgradeable`. This is
accepted for the current deployment model because pool and factory UUPS upgrade
entrypoints are disabled on-chain, live logic is pinned by codehash, and storage
layout checks gate changes in CI. If upgradeability is ever re-enabled for live
proxies, this base must be migrated deliberately and checked with a storage
layout diff before deployment.

### Supported-token behavior attestation

`SplitRiskPoolFactory.addToken` and `addTokenInitial` retain their existing
selectors, but their final boolean is an explicit governance attestation of
all token behavior required by nominal pool accounting. Before acknowledging a
token, governance must establish that:

- balances held by external accounts are static (no rebasing, reflection,
  elastic-balance, or share-indexed representation),
- `transfer` and `transferFrom` never debit the sender by more than the requested
  amount in any context the factory, a pool, or an escrow can exercise, and
- those properties cannot be enabled, disabled, upgraded, or otherwise changed
  while any pool using the token remains active.

The acknowledgement is a reviewed governance decision, not an on-chain proof.
The factory probes a small set of common rebasing/share-token interface markers,
but absence of those markers does not establish safe transfer behavior. Tokens
with recipient-deducted transfer fees can be handled by balance-delta accounting;
tokens that charge an additional sender-paid amount are unsupported.

Pool and creation-bond outbound transfers independently compare the contract's
balance delta with the requested amount. If an admitted token later changes to
sender-extra-debit behavior, affected operations fail closed instead of silently
breaking accounting. That defense can make withdrawals or bond settlement
temporarily unavailable, so the token issuer, proxy administrator, and any
transfer-policy controller remain part of the governance onboarding trust
boundary.

### NFT secondary-market cooldown carryover

The 24h `CLAIM_REWARDS_COOLDOWN` is keyed by tokenId, not owner — fee baselines
travel with the NFT, so claim metadata follows the same rule for accounting
consistency. A buyer who receives a position right after the seller called
`claimRewards` cannot call it again for up to 24h. This is intentional but
worth surfacing on any secondary-market UI: the displayed "claimable" amount
will continue accruing, but the on-chain `lastClaimRewardsTime` for the
tokenId persists across transfer.

### Withdrawal ACL during governance-timelock rotations

Pool withdrawal gating only applies while the configured access-control
contract is owned by, or solely administered by, the pool's current governance
timelock. During a timelock rotation, an ACL still controlled by the old
timelock intentionally fails open for withdrawals so user funds are not trapped
behind an obsolete authority. Operators that require uninterrupted withdrawal
gating must transfer the ACL owner/admin to the replacement timelock before
calling `acceptGovernanceTimelock` on the pool or factory-managed pool batch.

### Permissionless Pyth update messages

`PythOracle.updatePriceFeeds` is intentionally permissionless — Pyth itself
authenticates the data, and gating the call would block any user from posting
the latest Hermes message. As a consequence, an attacker can select the
most-favorable still-valid Hermes message (~2-3 second window of signed
prices) and post it ahead of their own transaction. Consumers MUST therefore
use the protected `getPrice`/`getValue` path (the default after the H-2/L-3
rename); the `*Unsafe` variants intentionally do NOT include EMA-deviation
or spot/EMA cross-checks.
