# Rule 010: V3 ERC20-Quote Vaults — Balance-Delta Accounting

## Rule

> A vault that declares a revenue currency via `vaultQuoteToken()` (a **V3 vault**,
> inheriting `VaultBaseV3`) **MUST** implement the balance-delta accounting model
> specified in `src/flap/VaultBaseV3.sol`:
>
> 1. Recognize revenue only as `currentBalance - accountedBaseline`, never from
>    `msg.value` and never by crediting the raw balance as new revenue.
> 2. A wake with zero delta MUST be a silent no-op (idempotency).
> 3. Every outflow MUST decrement the baseline by the amount spent, in the same
>    transaction.
> 4. Every function whose behavior depends on available revenue MUST run the sync
>    routine before acting ("recognize before you act").
> 5. `vaultQuoteToken()` MUST be stable for the life of the vault, MUST NOT revert,
>    and MUST equal the quote token of the tax token the vault serves.

This is a **Critical** rule. Violations must be reported as Critical findings.

Rule 010 applies only to V3 vaults. Pre-V3 vaults (no `vaultQuoteToken()`) are
native-only and exempt; check them under Rules 001–009 as usual.

---

## Rationale

ERC20 quote revenue arrives as a bare `safeTransfer` — the vault gets **no
execution** and `msg.value` is always zero. The TaxProcessor therefore follows
every ERC20 payout with a zero-value, empty-calldata "ping" that invokes the
vault's `receive()`. The ping carries no amount: the only way the vault can know
how much arrived is to compare its quote balance against a stored baseline.

Getting this wrong fails **silently**:

- Crediting the raw balance as "new revenue" double-counts everything already
  recognized. Example: a split vault receives 50, distributes 50 to recipients;
  later receives 30 and credits `balanceOf == 80` → recipients are granted 130
  against 80 of real funds — the vault is now insolvent.
- Forgetting to decrement the baseline on an outflow leaves the baseline above
  the real balance, so `balance <= baseline` suppresses recognition **forever**
  — the vault deadlocks with funds accumulating unseen.

The reference implementation is `src/FreeCoinV3Beacon.sol`
(`_syncRevenue()` / `sync()` / the baseline decrement in `claim()`).

---

## What to Check

### 1. Static analysis (always required)

Scan every function of a V3 vault for these patterns; each is a **violation**:

| Pattern | Finding |
|---|---|
| `balanceOf(address(this))` (or `address(this).balance`) credited into a counter, share, or distribution **without** subtracting a stored baseline | Critical |
| `msg.value` used to recognize revenue on a vault whose `vaultQuoteToken()` can be an ERC20 | Critical |
| A function that transfers quote out (native `call{value:}` / `safeTransfer`) without decrementing the baseline in the same function | Critical |
| A custom function that spends, pays out, or gates on available revenue without first invoking the sync routine | High |
| `vaultQuoteToken()` that can revert, or whose value can change after initialization | Critical |
| Baseline recognition that reverts (instead of returning) when the delta is zero | High — breaks ping idempotency |

Reading the raw balance for **display-only views** (e.g. a `getNextReward()`
preview) is acceptable and is NOT a violation; the rule governs state-changing
logic.

### 2. `receive()` budget under the ping

The protocol does not cap the wake call — it forwards the dispatch caller's
remaining gas (EIP-150). The protocol keeper, however, drives the ENTIRE
dispatch (swaps, dividends, burn, up to four wallet payouts) under one fixed
per-call gas budget, so a heavy `receive()` starves keeper-driven dispatch for
the vault's own token until someone re-dispatches with a higher gas limit.
For a V3 vault, analyse the `receive()` body (same scope rule as Rule 005)
against Rule 005's **1,000,000** budget as the hard bound, and report a body
that goes beyond accounting plus an event as a **High** finding: swaps,
staking, and buybacks belong behind explicit public functions.

### 3. Test verification (if test suite is present)

Verify tests exist covering, at minimum:

- a bare ERC20 transfer alone is NOT auto-recognized, and a zero-value ping
  (sent with a bounded, keeper-realistic gas allotment) recognizes it;
- repeated pings with no new revenue change nothing (idempotency);
- after an outflow, the baseline decreased by exactly the amount spent, and
  subsequent revenue is still recognized (no deadlock).

See `test/FreeCoinV3.t.sol` for the reference test shapes
(`test_Erc20Revenue_TransferAloneIsSilent_PingRecognizes`,
`test_ZeroDeltaPing_IsSilentNoOp`, `test_Claim_RecognizesPendingRevenueFirst`).
