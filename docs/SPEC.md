# Weekend Guard: Specification v0.1

## Problem

Tokenized stocks on Robinhood Chain are used as collateral in Morpho Blue lending markets. Onchain markets run 24/7, but the underlying stocks trade only during US market hours. Between Friday's close and Monday's open, news piles up and the oracle price stays flat. Then Monday's open can **gap** 10–20% in a single print, and borrowers are liquidated before they can react. They lose the liquidation incentive (up to 15% on Morpho) on top of the price move.

## Solution

Borrowers pre-authorize a **bounded, non-custodial** rescue:

- **ADD_COLLATERAL**: pull more of the stock token from the user's wallet and supply it to their Morpho position.
- **REPAY**: pull stablecoin (e.g. USDG) from the user's wallet and repay part of the debt.

Any keeper can call `protect(user, marketId)` when the position's health factor is below the user's trigger. Inside the **weekend window** (Fri 19:00 UTC to Mon 14:30 UTC), the health factor is computed against a **stressed price** (`spot × (1 − weekendGapBps)`). That way the position is de-risked *before* Monday's open, not after.

## Why Robinhood Chain

- The problem is specific to tokenized equities with market-hours pricing, which is Robinhood Chain's core asset class.
- Morpho is the largest protocol on Robinhood Chain by TVL, and stock-token collateral is already live there.
- Making stock-backed borrowing safer increases demand for Stock Tokens, Morpho liquidity and USDG.

## Contract: `WeekendGuard`

### User config (per user, per Morpho market)

| Field | Meaning | Constraint |
|---|---|---|
| `mode` | ADD_COLLATERAL or REPAY | |
| `triggerHf` | protect when HF < trigger | > 1.0 |
| `targetHf` | HF restored after protection | > trigger, ≤ 10 |
| `weekendGapBps` | stressed price drop in the weekend window | ≤ 50% |
| `keeperFeeBps` | reward to caller, on top of amount | ≤ 1% |
| `cooldown` | min seconds between protections | |
| `maxPerAction` | cap per protection (token units) | > 0 |
| `budgetLeft` | total cap incl. fees, decreases on use | > 0 |

The user also `approve`s WeekendGuard on the relevant token. Effective exposure = min(allowance, budgetLeft).

### Health factor

```
debt  = borrowShares × (totalBorrowAssets + 1) / (totalBorrowShares + 1e6)   (rounded up, Morpho math)
price = oracle.price() × (1 − gap)                                          (gap = 0 outside window)
HF    = collateral × price / 1e36 × lltv / debt
```

### Amount

- ADD_COLLATERAL: `needed = targetHf × debt / lltv × 1e36 / price`, `amount = needed − collateral`
- REPAY: `maxDebt = collateral × price / 1e36 × lltv / targetHf`, `amount = debt − maxDebt`

Then capped by `maxPerAction` and `budgetLeft` (fee included).

### Security properties

1. **Non-custodial.** Tokens go user wallet → guard → Morpho in one transaction. The guard holds nothing between calls.
2. **No Morpho authorization.** `supplyCollateral` and `repay` on behalf of a user need none, so the guard can never withdraw or borrow for a user.
3. **Bounded.** Per-action cap, total budget, cooldown, fee cap.
4. **Only helps.** `protect` only runs when HF < trigger and only ever *improves* the user's position.
5. **Opt-in.** Users without an active config cannot be touched, even if they approved the guard.
6. Reentrancy guard; SafeERC20; approval reset to 0 after each call.

### Known limitations (v0.1)

- Market holidays are not in the onchain window. The keeper handles them off-chain (it can call during weekdays only if HF < trigger at spot).
- The weekend window is a fixed UTC range that ignores DST precisely and is deliberately wide.
- Oracle staleness is not checked (Morpho oracles expose no timestamp). It is inherited from the market's oracle.
- Keeper fee is paid in the protected token.
- **Unaudited.** Testnet only until audited.

## Roadmap

1. **v0.1 (now).** Contract + tests + testnet deploy.
2. Keeper bot (TypeScript, viem): scans configs via events, calls `check`/`protect`, Friday pre-close sweep.
3. Frontend: connect wallet, see Morpho positions, one-click "Protect my weekend".
4. Market-holiday calendar + per-asset gap defaults from historical Monday gaps.
5. v0.2: hedge mode (buy a put / short-dated protection instead of adding collateral).
6. Audit → mainnet.
