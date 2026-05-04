# Static Analysis & Security Checklist

The protocol now targets the Solidity best practices listed in `.cursor/rules/solidity.mdc`. Run the following tools locally before opening a PR:

1. **Slither**
   ```bash
   cd packages/foundry
   pipx install slither-analyzer==0.10.3
   slither . --foundry-out-dir out --checklist
   ```
   This respects `foundry.toml` remappings and reports reentrancy, unused return values, etc.

2. **Mythril**
   ```bash
   cd packages/foundry
   pipx install mythril==0.24.9
   myth analyze contracts/SplitRiskPool.sol --solc-json solc-input.json
   ```
   Generate `solc-input.json` via `forge build --build-info` or `forge inspect SplitRiskPool solc-input`.

3. **Invariant / Fuzz Tests**
   ```bash
   cd packages/foundry
   forge test --ffi --gas-report
   ```

4. **Coverage**
   ```bash
   cd packages/foundry
   forge coverage --ffi --report lcov
   genhtml lcov.info -o coverage-report
   open coverage-report/index.html
   ```
   This tracks line-by-line coverage for the fuzz, invariant, and fork suites. Treat regressions as blockers before merging feature branches.

Document triaged findings in a dated note under `packages/foundry/docs_ok/security/analyses/` or the relevant launch/security doc. CI already runs Foundry tests and Slither on PRs; keep the commands above as the local pre-push checklist.
