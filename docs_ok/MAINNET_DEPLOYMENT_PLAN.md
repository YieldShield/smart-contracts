# YieldShield Mainnet Deployment Plan

**Created:** January 7, 2025  
**Status:** Pre-Mainnet Checklist  
**Current Test Count:** 232 tests passing

---

## Executive Summary

This plan outlines remaining tasks before mainnet deployment, organized by priority. The protocol has undergone multiple security audits and most critical issues have been addressed.

---

## Priority 1: Security Fixes (Must Complete)

### 1.1 ✅ NEW-1: Fee Payment Access Control
**Status:** COMPLETED  
Access control added to `payPoolFee()` and `payProtocolFee()`.

### 1.2 ❌ PREV-5: Combined Fee Maximum Validation
**Status:** NOT IMPLEMENTING - Deemed unnecessary  
**Rationale:** Individual fee bounds (50% commission, 20% pool fee, 10% protocol fee) provide sufficient protection. Combined validation would add complexity without significant security benefit. Governance controls ensure reasonable fee structures.

### 1.3 ✅ NEW-4: MinimumPoolTime Bounds Validation
**Status:** COMPLETED  
**Location:** `SplitRiskPool.sol:updatePoolConfig()`, `ConstantsLib.sol`  
**Implementation:** Added `MAX_MINIMUM_POOL_TIME = 90 days` constant and validation in `updatePoolConfig()` to prevent governance from setting excessive lock periods.

---

## Priority 2: Code Quality (Should Complete)

### 2.1 PREV-2: Clear TokenInfo on Whitelist Removal
**Location:** `SplitRiskPoolFactory.sol:removeToken()`  
**Task:** Add `delete tokenInfo[token];`  
**Effort:** Trivial (15 min)

### 2.2 NEW-5: Semantic NFT Error Messages
**Location:** `InsuredReceiptNFT.sol`, `UnderwriterReceiptNFT.sol`  
**Task:** Replace `NotOwner` with `OnlyPoolCanCall` in `onlyPool` modifier  
**Effort:** Low (30 min)

### 2.3 PREV-4: Event for Zero Commission Claim
**Location:** `SplitRiskPool.sol:claimCommission()`  
**Task:** Emit event when `claimable == 0`  
**Effort:** Low (30 min)

---

## Priority 3: Testing (Recommended)

### 3.1 Add Tests for New Access Control
**Task:** Test that `payPoolFee()` and `payProtocolFee()` revert for unauthorized callers  
**Effort:** Medium (2 hours)

### 3.2 Add Integration Tests for Fee Reserve Protection
**Task:** Test MED-3 fix - verify withdrawals respect reserved fees  
**Effort:** Medium (2-3 hours)

### 3.3 Fuzz Testing for Edge Cases
**Task:** Add fuzz tests for:
- Extreme deposit amounts near uint256 limits
- Fee accumulation approaching uint128 limits
- Commission distribution with many underwriters
**Effort:** High (1-2 days)

### 3.4 Invariant Tests
**Task:** Add invariant tests verifying:
- `poolState.insuredTokenBalance >= getReservedFees()`
- `totalInsuredTokens <= totalUnderwriterTokens * BASIS_POINT_SCALE / COLLATERAL_RATIO`
- NFT counts match token accounting
**Effort:** High (1-2 days)

---

## Priority 4: Documentation (Recommended)

### 4.1 Update NatSpec Comments
**Task:** Ensure all public functions have complete NatSpec documentation  
**Effort:** Medium (1 day)

### 4.2 Create Deployment Runbook
**Task:** Document step-by-step deployment process including:
- Contract deployment order
- Initialization parameters
- Post-deployment verification steps
- Emergency procedures
**Effort:** Medium (1 day)

### 4.3 Document Known Behaviors
**Task:** Document acknowledged behaviors:
- Oracle challenge front-running window (PREV-6)
- NFT getPosition returns defaults for non-existent tokens (PREV-3)
- Pool creator immutability (PREV-1)
**Effort:** Low (2 hours)

---

## Priority 5: Deployment Preparation

### 5.1 Set Up Multisig for Governance
**Task:** Deploy and configure Gnosis Safe or similar for:
- `governanceTimelock` address
- `defaultProtocolFeeRecipient`
- Factory owner
**Effort:** Medium (1 day)

### 5.2 Configure Oracle Feeds
**Task:** Verify and configure:
- Chainlink price feeds for target tokens
- ERC4626 oracle feeds for vault tokens
- MetaOracleAdapter parameters (deviation threshold, challenge duration)
**Effort:** Medium (1 day)

### 5.3 Whitelist Initial Tokens
**Task:** Prepare list of tokens for initial whitelist with verified:
- Token addresses
- Symbols
- Oracle feed availability
**Effort:** Low (2 hours)

### 5.4 Testnet Deployment
**Task:** Deploy full system to testnet (Arbitrum Sepolia) and:
- Create test pools
- Run full user flows
- Test pause/unpause
- Test governance functions
**Effort:** High (2-3 days)

---

## Priority 6: External Audit (Highly Recommended)

### 6.1 Professional Security Audit
**Task:** Engage professional audit firm for formal review  
**Scope:** All contracts in scope  
**Effort:** 2-4 weeks + remediation  
**Cost:** $20,000 - $100,000+

### 6.2 Bug Bounty Program
**Task:** Set up bug bounty program on Immunefi or similar  
**Scope:** Mainnet contracts  
**Budget:** Recommend $50,000+ pool

---

## Checklist Summary

### Must Complete Before Mainnet
- [x] NEW-1: Fee payment access control
- [x] NEW-4: MinimumPoolTime bounds validation
- [ ] Testnet deployment and testing
- [ ] Multisig setup for governance

### Should Complete Before Mainnet
- [ ] PREV-2: Clear TokenInfo on removal
- [ ] NEW-5: Semantic NFT errors
- [ ] Additional test coverage
- [ ] Deployment runbook

### Highly Recommended
- [ ] Professional security audit
- [ ] Bug bounty program
- [ ] Invariant/fuzz testing

---

## Timeline Estimate

| Phase | Tasks | Duration |
|-------|-------|----------|
| Security Fixes | Priority 1 | 1-2 days |
| Code Quality | Priority 2 | 1 day |
| Testing | Priority 3 | 3-5 days |
| Documentation | Priority 4 | 2 days |
| Deployment Prep | Priority 5 | 3-5 days |
| External Audit | Priority 6 | 2-4 weeks |

**Minimum Path to Mainnet:** 2 weeks (Priorities 1, 5, testnet)  
**Recommended Path:** 4-6 weeks (All priorities)  
**With External Audit:** 6-10 weeks

---

## Risk Assessment

### Current Risk Level: **Medium-Low**

**Strengths:**
- All critical/high severity issues addressed
- Comprehensive reentrancy protection
- Robust access control
- Multiple audit iterations completed

**Remaining Risks:**
- No external professional audit
- Oracle front-running window (acknowledged)
- Combined fees can theoretically reach 80% (individual bounds enforced, governance-controlled)

**Mitigations:**
- Governance controlled by multisig
- Pausability for emergencies
- Timelock on sensitive operations

---

*This plan should be reviewed and updated as tasks are completed.*

