---
name: flap-vault-spec-checker
description: 'Audits Solidity vault contracts for compliance with the Flap VaultPortal protocol specification. Use when asked to "audit my vault", "check flap spec compliance", "review vault contract", "validate vault implementation", "run solidity audit", or "verify vault rules".'
argument-hint: 'Path to vault contract file or directory (e.g. src/MyVault.sol)'
user-invocable: true
disable-model-invocation: false
---

# Flap Vault Spec Checker

Audits Solidity vault contracts for compliance with the Flap VaultPortal protocol specification.

## When to Use

- User says "audit my vault", "check my flap vault", "does my contract comply with Flap spec?"
- User provides or pastes a vault Solidity file for review
- User invokes this skill by name in any supported agent environment (VS Code Copilot, Claude Code, or other compatible agents)
- User wants to verify spec compliance before deploying to Flap.sh

## Locating the Contracts

**Do not assume a fixed directory.** Resolve the target contract(s) by priority:

1. **Argument / explicit path** — if the user passes a path (e.g. `src/MyVault.sol`), use it.
2. **Pasted source** — if Solidity code is pasted inline, analyse it directly.
3. **Ask the user** — if neither is provided, ask:
   > Which file or directory contains the vault contract(s) you want audited?

## Audit Procedure

### Step 1 — Read all rules

Read **every** file in [`./references/rules/`](./references/rules/):

| File | Topic |
|------|-------|
| [001-vault-rules.md](./references/rules/001-vault-rules.md) | VaultBaseV2 inheritance, guardian access, no-DOS |
| [002-vault-factory-rules.md](./references/rules/002-vault-factory-rules.md) | VaultFactoryBaseV2 inheritance, commission fee |
| [003-fairness-rule.md](./references/rules/003-fairness-rule.md) | Fairness & sandwich-risk |
| [004-ui-friendly-rules.md](./references/rules/004-ui-friendly-rules.md) | Literal error strings, multi-language |
| [005-receive-gas-limit.md](./references/rules/005-receive-gas-limit.md) | `receive()` ≤ 1,000,000 gas |
| [006-integration-test-coverage.md](./references/rules/006-integration-test-coverage.md) | Critical-flow integration test coverage |
| [007-ai-oracle-integration.md](./references/rules/007-ai-oracle-integration.md) | AI oracle callback/lifecycle safety |
| [008-trigger-service-integration.md](./references/rules/008-trigger-service-integration.md) | Trigger callback/replay safety |
| [009-emergency-risk-controls.md](./references/rules/009-emergency-risk-controls.md) | Emergency withdraw + auto-forward controls |
| [010-v3-erc20-quote-accounting.md](./references/rules/010-v3-erc20-quote-accounting.md) | V3 (ERC20-quote) balance-delta accounting |

### Step 2 — Read the contract(s)

Read the vault (and factory, if present) provided by the user. If the contract imports Flap base contracts, resolve them from [`./references/prelude/`](./references/prelude/) — import path names do not need to match exactly; match by content/interface. Flattened copies of base contracts in the vault are also acceptable if the interface is identical.

### Step 3 — Run the compliance checklist

Work through every item below. Report PASS ✅ / FAIL ❌ / WARNING ⚠️.

#### Inheritance
- [ ] Vault inherits `VaultBaseV2` (or flattens it correctly) — see [001](./references/rules/001-vault-rules.md)
- [ ] Factory (if present) inherits `VaultFactoryBaseV2` — see [002](./references/rules/002-vault-factory-rules.md)

#### `receive()` gas limit ⚠️ CRITICAL

> **Scope rule: ONLY analyse the `receive()` function body and any internal functions it directly or transitively calls. External calls that exist elsewhere in the contract (e.g., in `claimReward`, `unstake*`, or internal helpers that are NOT reachable from `receive()`) are completely irrelevant to Rule 005. Do NOT flag them as `receive()` violations.**

- [ ] Read `receive()` line-by-line. Trace every internal call it makes. Build the full call tree. Only flag patterns found within that call tree.
- [ ] No unbounded loops inside the `receive()` call tree
- [ ] No external calls (`.call`, `.transfer`, token transfers, interface calls) inside the `receive()` call tree
- [ ] No `delegatecall` inside the `receive()` call tree
- [ ] Worst-case gas ≤ 1,000,000 — see [005](./references/rules/005-receive-gas-limit.md)

#### V3 (ERC20-quote) accounting ⚠️ CRITICAL — only if the vault implements `vaultQuoteToken()`
- [ ] Revenue recognized only as `balance - baseline`; raw balance never credited as new revenue — see [010](./references/rules/010-v3-erc20-quote-accounting.md)
- [ ] Zero-delta wakes are silent no-ops (no revert)
- [ ] Every outflow decrements the baseline in the same transaction
- [ ] Every revenue-dependent custom function syncs before acting
- [ ] `vaultQuoteToken()` is stable, non-reverting, and matches the launch quote
- [ ] `receive()` body is accounting + event only and fits Rule 005's 1,000,000 budget (the ping forwards dispatcher gas — see [010](./references/rules/010-v3-erc20-quote-accounting.md))

#### `description()` implementation
- [ ] Overrides `description() public view returns (string memory)`
- [ ] Returns any non-reverting string — static / placeholder strings are **acceptable per Rule 001** (the legacy field is deprecated; the UI uses `vaultUISchema` instead). Do NOT flag a static description as a finding. Only flag if the function is missing entirely.

#### `vaultUISchema()` implementation
- [ ] `schema.vaultType` and `schema.description` are non-empty
- [ ] Every user-facing function is listed in `schema.methods`
- [ ] Each `VaultMethodSchema` has: non-empty `name`/`description`, correct `inputs`/`outputs`, `isWriteMethod` flag, initialised `approvals` array
- [ ] `fieldType` uses only spec types: `string`, `address`, `uint16`, `uint128`, `uint256`, `time`, `bool`, `bytes`, `bytes32`
- [ ] `decimals` is `18` for BNB/token amounts, `0` for raw integers

#### `vaultDataSchema()` (factory)
- [ ] `schema.description` non-empty; `schema.fields` matches `newVault()` `vaultData` ABI

#### `newVault()` guards (factory)
- [ ] Reverts when `msg.sender != _getVaultPortal()`
- [ ] `vaultData` decoded with `abi.decode` matching schema

#### Guardian access control ⚠️ CRITICAL — see [001](./references/rules/001-vault-rules.md)

> **The implementation pattern depends on the access control mechanism the vault uses. Do NOT apply OZ-AccessControl-specific checks to contracts that use custom modifiers.**

**For contracts using OpenZeppelin `AccessControl`:**
- [ ] `_getGuardian()` address is granted every privileged role at construction
- [ ] `revokeRole()` is overridden to revert when `account == _getGuardian()`

**For contracts using custom modifiers (e.g. `onlyOwner`, `onlyOwnerOrGuardian`):**
- [ ] Every privileged modifier includes a `msg.sender == _getGuardian()` branch — Guardian must be able to call all permissioned functions
- [ ] No function allows removing or replacing the Guardian address (Guardian is hardcoded in `VaultBaseV2._getGuardian()` — this is automatically satisfied when VaultBaseV2 is correctly inherited or flattened)
- [ ] Do NOT flag "revokeRole() not overridden" on contracts that do not use OZ AccessControl — this is a false positive

#### `isQuoteTokenSupported()` (factory)
- [ ] Implements `isQuoteTokenSupported(address) external view returns (bool)`

#### Commission fee (factory) — see [002](./references/rules/002-vault-factory-rules.md)
- [ ] Follows recommended fee formula, or justification is requested

#### Fairness — see [003](./references/rules/003-fairness-rule.md)
- [ ] No privileged path lets insiders extract value at user expense
- [ ] Sandwich-risk from privileged parameter changes is explicitly assessed

#### UI-friendly — see [004](./references/rules/004-ui-friendly-rules.md)
- [ ] All reverts use `require()` with literal strings (no custom errors)
- [ ] Multi-language strings include all languages inline

#### AI oracle (if present) — see [007](./references/rules/007-ai-oracle-integration.md)
- [ ] Callback ≤ 2M gas; lifecycle safety enforced

#### Trigger service (if present) — see [008](./references/rules/008-trigger-service-integration.md)
- [ ] Callback ≤ 2M gas; replay protection enforced

#### Emergency controls (if present) — see [009](./references/rules/009-emergency-risk-controls.md)

> **When writing recommendations for emergency function violations, you MUST use the exact function signatures and patterns from Rule 009 verbatim. Do NOT invent alternative signatures, parameter names, or access modifiers. Copy the reference implementation exactly.**

> **Upgradeable/proxy exception:** If the vault itself is deployed behind a proxy or otherwise intentionally upgradeable (e.g. BeaconProxy / ERC1967 / Transparent / UUPS), do **NOT** require `emergencyWithdrawNative`, `emergencyWithdrawToken`, `autoForwardEnabled`, `forwardAddress`, or `setAutoForward`. For these vaults, instead verify that any upgrade/admin authority is retained by the Guardian only.

- [ ] **For non-upgradeable vaults:** `emergencyWithdrawNative(address to)` exists with signature matching Rule 009 **exactly** — `onlyGuardian`, `nonReentrant`, drains full balance, emits `EmergencyWithdrawNative(to, bal)`
- [ ] **For non-upgradeable vaults:** `emergencyWithdrawToken(address token, address to)` exists with signature matching Rule 009 **exactly** — `onlyGuardian`, `nonReentrant`, drains full balance via `safeTransfer`, emits `EmergencyWithdrawToken(token, to, bal)`
- [ ] **For non-upgradeable vaults:** both emergency functions are `onlyGuardian` (NOT `onlyOwnerOrGuardian` — owner must NOT be able to call these)
- [ ] **For non-upgradeable vaults:** neither function accepts an `amount` parameter — they must drain the **full balance**
- [ ] **For non-upgradeable vaults:** destination address is a **caller-supplied `address to` parameter**, never hardcoded to `_owner` or any other fixed address
- [ ] **For non-upgradeable vaults:** both functions have `nonReentrant`
- [ ] `autoForwardEnabled` defaults to `false` (if auto-forward is implemented on a non-upgradeable vault)
- [ ] `setAutoForward` is `onlyGuardian` (if auto-forward is implemented on a non-upgradeable vault)
- [ ] **For upgradeable/proxy vaults:** upgrade/admin authority is Guardian-only; no non-Guardian owner, proxy admin, beacon owner, upgrader role, or equivalent authority may remain

#### Integration tests — see [006](./references/rules/006-integration-test-coverage.md)
- [ ] Test suite covers: `receive()` gas budget, critical write happy/revert paths, view methods, `description()`, `vaultUISchema()`, guardian access, role revocation guard

### Step 4 — Security review

Beyond spec compliance, audit for general Solidity/OWASP vulnerabilities by severity:

**Critical / High**
- Reentrancy attacks
- Integer overflow / underflow
- Access control bypasses
- Front-running vulnerabilities
- Flash loan attacks
- Price manipulation vulnerabilities
- Logic errors that could lead to fund loss
- DOS vulnerabilities that could lock funds or break functionality

**Medium**
- Improper input validation
- Gas optimisation issues
- Race conditions
- Timestamp dependencies
- Unchecked external calls

**Low / Info**
- Code quality and best practices
- Gas inefficiencies
- Unused variables or functions
- Missing events for critical functions
- Inconsistent naming conventions

**Analysis guidelines**
- Examine every function, modifier, and state variable
- Think like an attacker — consider all exploit vectors
- Analyse imported contracts and external calls
- Verify business logic matches intended functionality
- Assess upgradeability implications
- Consider tokenomics and economic attack vectors

### Step 5 — Write the audit report

Produce a Markdown file named `audit_<model>.md` (e.g. `audit_claude_sonnet_4.md`). Place it in the same directory the user is working from, or wherever the user specifies. **Rule violations always appear first** in the findings list, above generic security issues.

Use this report structure:

```markdown
# Smart Contract Audit Report

**Auditor**: [AI Model Name]
**Contract(s)**: [List of audited contracts]

> NOTE: This report is generated by an AI model and should be reviewed by a human auditor for accuracy and completeness.

## Executive Summary
[Brief overview of findings and overall security assessment]

## Scope
[List of files and contracts audited]

## Findings Summary
| Severity | Count | Description |
|----------|-------|-------------|
| Critical | X     | Issues that pose immediate risk to funds |
| High     | X     | Significant security vulnerabilities |
| Medium   | X     | Moderate security concerns |
| Low      | X     | Minor issues and optimizations |
| Info     | X     | Informational findings |

## Detailed Findings

### Critical Issues
#### C-01: [Issue Title]
**Severity**: Critical
**Status**: Open
**File**: [filename:line_number]
**Description**: [Detailed description]
**Impact**: [Potential impact and attack scenarios]
**Proof of Concept**:
```solidity
// Example exploit code
```
**Recommendation**: [Specific fix steps]

### [Repeat for High, Medium, Low, and Info severity levels]

## Centralization Analysis
### Admin Controls
### Upgrade Mechanisms
### Emergency Functions
### Decentralization Recommendations

## Gas Optimization Recommendations

## Best Practices and Code Quality
### Positive Observations
### Areas for Improvement

## Testing and Verification Recommendations

## Conclusion

## Disclaimer
This audit does not guarantee the absence of bugs or vulnerabilities. Smart contracts should undergo multiple audits and extensive testing before mainnet deployment.
```

---

## Rules Summary

| # | Rule | Severity if violated |
|---|------|----------------------|
| 001 | Vault must inherit `VaultBaseV2`; `vaultUISchema()` required | Critical |
| 001 | Guardian must have access to all privileged functions | Critical |
| 001 | Guardian's role must not be revocable by others | Critical |
| 001 | No DOS via parameter manipulation | High |
| 002 | Factory must inherit `VaultFactoryBaseV2` | Critical |
| 002 | Factory must follow commission fee recommendation | High |
| 003 | Vault mechanism must be fair to users (sandwich-risk analysis) | High/Critical |
| 004 | Error strings must be literals (no custom errors) | Medium |
| 004 | Multi-language strings must include all languages inline | Low |
| 005 | `receive()` must use ≤ 1,000,000 gas | Critical |
| 006 | Integration tests must cover critical vault/factory flows | High |
| 007 | AI oracle: callback + lifecycle safety; ≤ 2M gas | High/Critical |
| 008 | Trigger service: callback + replay safety; ≤ 2M gas | High/Critical |
| 009 | Emergency controls: guardian-only, inactive by default | High/Critical |

---

## References

- [rules/](./references/rules/) — all 9 compliance rule files (read during every audit)
- [prelude/](./references/prelude/) — canonical Flap V2 base contracts and interfaces
- [flap-v2-spec.md](./references/flap-v2-spec.md) — Flap V2 protocol overview
- [receive-gas-rule.md](./references/receive-gas-rule.md) — detailed `receive()` gas guidance
- [integration-test-guide.md](./references/integration-test-guide.md) — integration test guidance
