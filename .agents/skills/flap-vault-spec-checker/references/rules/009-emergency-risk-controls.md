# Rule 009: Emergency Risk Controls

## Rule

> **Non-upgradeable vaults MUST implement emergency risk-control functions** for use in critical situations. These functions must be strictly guardian-guarded, inactive by default, and must not compromise normal operation or violate the `receive()` gas limit.
>
> **Upgradeable/proxy vaults (e.g. BeaconProxy) are fully exempt** from this requirement — they rely on the Guardian-controlled upgrade path as their emergency mechanism instead.

For **non-upgradeable vaults**, missing emergency controls are a **Medium** severity finding. Poorly protected or actively dangerous implementations are **High**.

> **Upgradeable/proxy exception:** If the vault is intentionally upgradeable and deployed behind a proxy (for example BeaconProxy / ERC1967 / Transparent / UUPS), the vault **does not need** to implement `emergencyWithdrawNative`, `emergencyWithdrawToken`, `autoForwardEnabled`, `forwardAddress`, or `setAutoForward`. Rule 009 is considered **not applicable** for such vaults. The auditor must instead verify under Rule 001 that all upgrade/admin authority is strictly Guardian-only — this becomes the sole emergency-control check for proxy vaults.

---

## Rationale

Vault contracts hold user funds in potentially adversarial conditions. Black-swan events — oracle failures, protocol exploits, stuck funds — require an operator escape hatch. Emergency controls let the Guardian recover funds or stop damage without requiring a contract upgrade.

These functions are intentionally infrequent. Their presence improves safety; their misuse is a fairness/access-control issue covered by Rule 001 and Rule 003.

---

## Required Emergency Functions

> ⚠️ The functions in this section are **mandatory for non-upgradeable vaults**. Proxy-upgradeable vaults (BeaconProxy, ERC1967, Transparent, UUPS) are **fully exempt** and must omit them entirely — see the exception above.

### 1. `emergencyWithdrawNative`

Allows the Guardian to drain accumulated native currency (BNB/ETH) to a safe address in an emergency.

```solidity
event EmergencyWithdrawNative(address indexed to, uint256 amount);

function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant {
    require(to != address(0), "Zero address");
    uint256 bal = address(this).balance;
    if (bal > 0) {
        (bool ok,) = to.call{value: bal}("");
        require(ok, "Native transfer failed");
        emit EmergencyWithdrawNative(to, bal);
    }
}
```

### 2. `emergencyWithdrawToken`

Allows the Guardian to recover any ERC-20 token (e.g. tax token, reward token) that is stuck in the vault.

```solidity
event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);

function emergencyWithdrawToken(address token, address to) external onlyGuardian nonReentrant {
    require(token != address(0) && to != address(0), "Zero address");
    uint256 bal = IERC20(token).balanceOf(address(this));
    if (bal > 0) {
        IERC20(token).safeTransfer(to, bal);
        emit EmergencyWithdrawToken(token, to, bal);
    }
}
```

---

## Optional: Auto-Forward (`receive()` Risk-Control Mode)

> This section applies only to **non-upgradeable vaults** that choose to implement auto-forward. Proxy-upgradeable vaults are fully exempt from this mode under the exception above.

Some vaults may support an emergency auto-forward mode that immediately re-routes incoming BNB to a safe address. This is useful when the vault's normal accumulation logic is compromised or the vault itself is at risk.

### State

```solidity
/// @notice If true, incoming BNB will be automatically forwarded to `forwardAddress`. Only settable by the Guardian. MUST default to false.
bool public autoForwardEnabled = false;
/// @notice Address to forward incoming BNB when auto-forward mode is enabled.
address public forwardAddress;
```

### receive()

```solidity
receive() external payable {
    if (autoForwardEnabled && forwardAddress != address(0)) {
        (bool success,) = payable(forwardAddress).call{value: msg.value}("");
        require(success, "Forward failed");
    }
    // normal vault logic here (e.g. accumulate pendingRevenue)
}
```

> ⚠️ **Gas limit warning:** When `autoForwardEnabled` is `true`, `receive()` makes an external call. This must still stay within the **1,000,000 gas** cap (Rule 005). The forward target must be a simple EOA or a contract with a trivial `receive()`. Auditors must flag this if the forward target is unknown or can be set to an arbitrary contract.

### Setter

```solidity
/// @notice Sets the auto-forward mode and target address. Only callable by the Guardian.
function setAutoForward(bool enabled, address _forwardAddress) external onlyGuardian {
    autoForwardEnabled = enabled;
    if (enabled) {
        require(_forwardAddress != address(0), "Invalid forward address");
        forwardAddress = _forwardAddress;
    }
}
```

---

## What to Check

| Check | Finding if violated |
|---|---|
| **Proxy-upgradeable vaults:** confirm vault is deployed behind a proxy (BeaconProxy / ERC1967 / Transparent / UUPS) | N/A — Rule 009 not applicable; skip emergency-function checks |
| **Proxy-upgradeable vaults:** all upgrade/admin authority is Guardian-only | Critical (non-Guardian upgrade authority bypasses Rule 001 and emergency-control intent) |
| **Non-upgradeable vaults:** `emergencyWithdrawNative` exists and is `onlyGuardian` | Medium (missing emergency native currency escape) |
| **Non-upgradeable vaults:** `emergencyWithdrawToken` exists and is `onlyGuardian` | Medium (missing stuck-token recovery) |
| **Non-upgradeable vaults:** both emergency functions have `nonReentrant` | High (reentrancy on fund-movement path) |
| **Non-upgradeable vaults with auto-forward:** `autoForwardEnabled` defaults to `false` | High (active auto-forward on deploy is an immediate DoS / fund-routing risk) |
| **Non-upgradeable vaults with auto-forward:** `setAutoForward` is `onlyGuardian` | Critical (anyone can redirect all incoming BNB) |
| **Non-upgradeable vaults with auto-forward:** when `autoForwardEnabled = true`, `receive()` stays within 1M gas | High (see Rule 005) |
| **Non-upgradeable vaults with auto-forward:** forward target restricted or validated | Medium (unrestricted target allows rerouting funds to attacker-controlled address) |
| Where emergency functions exist, they remain accessible by Guardian | Critical (Rule 001 — Guardian must reach all privileged functions) |

---

## Severity Classification

| Scenario | Severity |
|---|---|
| Proxy-upgradeable vault: Rule 009 emergency function checks | N/A — not applicable |
| Proxy-upgradeable vault: upgrade authority retained by non-Guardian | Critical |
| Non-upgradeable vault: emergency withdraw functions missing entirely | Medium |
| Emergency withdraw not protected by Guardian/privileged role | Critical |
| Non-upgradeable vault: `nonReentrant` missing on fund-movement emergency functions | High |
| Non-upgradeable vault: `autoForwardEnabled` defaults to `true` | High |
| Non-upgradeable vault: `setAutoForward` callable by non-Guardian | Critical |
| Non-upgradeable vault: `receive()` can exceed 1M gas when auto-forward is active | High |

