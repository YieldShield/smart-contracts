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
