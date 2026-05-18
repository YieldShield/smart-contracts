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
unilaterally pass any proposal — upgrade pools, change oracle policy, alter
NFT transfer locks, install a new (potentially malicious-but-validly-shaped)
governance timelock, or transfer factory/NFT ownership. There is no on-chain
gate preventing this; the only protections are:

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

### NFT secondary-market cooldown carryover

The 24h `CLAIM_REWARDS_COOLDOWN` is keyed by tokenId, not owner — fee baselines
travel with the NFT, so claim metadata follows the same rule for accounting
consistency. A buyer who receives a position right after the seller called
`claimRewards` cannot call it again for up to 24h. This is intentional but
worth surfacing on any secondary-market UI: the displayed "claimable" amount
will continue accruing, but the on-chain `lastClaimRewardsTime` for the
tokenId persists across transfer.

### Permissionless Pyth update messages

`PythOracle.updatePriceFeeds` is intentionally permissionless — Pyth itself
authenticates the data, and gating the call would block any user from posting
the latest Hermes message. As a consequence, an attacker can select the
most-favorable still-valid Hermes message (~2-3 second window of signed
prices) and post it ahead of their own transaction. Consumers MUST therefore
use the protected `getPrice`/`getValue` path (the default after the H-2/L-3
rename); the `*Unsafe` variants intentionally do NOT include EMA-deviation
or spot/EMA cross-checks.

