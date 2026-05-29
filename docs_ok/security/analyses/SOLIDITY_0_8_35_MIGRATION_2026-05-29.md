# Solidity 0.8.35 Migration

Date: 2026-05-29

## Scope

The project compiler pin and first-party Solidity pragmas were moved from Solidity 0.8.30 to 0.8.35.

Changes included:

- Updated `foundry.toml` to compile with `solc_version = "0.8.35"`.
- Updated first-party contracts, scripts, and tests from `pragma solidity ^0.8.30;` to `pragma solidity ^0.8.35;`.
- Synced `foundry.lock` to the checked-in OpenZeppelin submodule revisions.
- Isolated the synthetic chain id used by `DeploymentMetadataTest` exact-match fixtures so parallel test execution no longer races with fallback fixture cleanup.
- Ran repository formatting so lint remains green after the pragma migration.

## Baseline Before Migration

- `forge build --offline`: passed on Solidity 0.8.30.
- `forge test --offline`: 948 passed, 0 failed, 4 skipped.

## Post-Migration Verification

- `forge test --offline`: 948 passed, 0 failed, 4 skipped.
- `npm run lint`: passed.
- `npm run test:scripts`: 22 passed, 0 failed.
- `npm run check:foundry-lock`: passed.
- `bash scripts-js/check-storage-layout.sh`: passed.

## Warnings And Follow-Ups

- Solidity 0.8.35 emits warning 6335 for vendored OpenZeppelin sources that use identifiers expected to become reserved keywords in a future Solidity release, including `error` and `at`.
- Existing Forge lint warnings remain around timestamp comparisons, casts, and unchecked transfer return values.
- `npm run size-check` is not green: `SplitRiskPool` and `SplitRiskPoolFactory` exceed the EIP-170 runtime size limit under the current build.
- `make security` could not complete locally because `aderyn` is not installed. The Slither step ran before the target failed on the missing binary.

## Conclusion

The Solidity 0.8.35 update builds and passes the full Foundry and script test suites. The remaining non-green checks are contract-size and local security-tooling issues that should be tracked separately from the compiler migration.
