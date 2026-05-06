# Contributing

Thanks for helping improve YieldShield smart contracts.

## Development Setup

```sh
git clone --recurse-submodules https://github.com/YieldShield/smart-contracts.git
cd smart-contracts
npm ci
cp .env.example .env
```

Install Foundry `v1.5.1` or use the version in `.foundry-version`.

## Before Opening a Pull Request

Run the checks that CI runs:

```sh
make lint
npm audit --omit=dev --audit-level=high
forge build --offline
forge test --offline
```

For contract logic changes, also consider:

```sh
node scripts-js/checkContractSizes.js
make slither
make aderyn
```

## Pull Request Guidelines

- Keep changes scoped and reviewable.
- Include tests for behavior changes.
- Update docs when changing deployment, security, or integration behavior.
- Do not commit local `.env`, `cache/`, `out/`, coverage reports, or local
  development broadcasts.
- Explain security-sensitive changes clearly in the PR description.
- Do not disclose suspected vulnerabilities in public issues or PRs. Follow
  `SECURITY.md` instead.

## Submodules

This repository uses Git submodules for Foundry dependencies. After pulling or
switching branches, run:

```sh
git submodule sync --recursive
git submodule update --init --recursive
```

If a PR intentionally changes dependency revisions, include the reason and
security impact in the PR description.
