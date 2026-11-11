# Weekend Guard 🛡️

**Liquidation protection for tokenized-stock borrowers on Robinhood Chain.**

Stocks don't trade on weekends; onchain lending does. When Monday opens 15% lower, Morpho borrowers using Stock Tokens as collateral get liquidated before they can react. Weekend Guard lets them pre-authorize a bounded, non-custodial top-up or repayment. Keepers execute it automatically, *before* the Monday open.

- Built on **Morpho Blue** markets on **Robinhood Chain**
- Non-custodial: funds go straight from the user's wallet into their own position
- Needs **no** Morpho authorization, so it can never withdraw or borrow for you
- User-defined trigger, target, per-action cap, total budget and cooldown

> ⚠️ Unaudited. Testnet only.

See [docs/SPEC.md](docs/SPEC.md) for the full design.

## Quick start

```bash
# 1. Install Foundry (once)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 2. Install dependencies
git init
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts

# 3. Build & test
forge build
forge test -vv
```

## Deploy to Robinhood Chain testnet

```bash
export ROBINHOOD_TESTNET_RPC=<rpc url from Robinhood Chain docs>
export MORPHO_ADDRESS=<Morpho Blue address on Robinhood Chain testnet>
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --interactive
```

Use a fresh testnet-only wallet. Testnet ETH: https://faucet.testnet.chain.robinhood.com/

### Deployments

| Network | Chain ID | Contract | Address |
|---|---|---|---|
| Robinhood Chain testnet | 46630 | WeekendGuard (verified) | [`0x7A0f008C5e8e69D57562c0d129dd90a898eC4cB7`](https://explorer.testnet.chain.robinhood.com/address/0x7A0f008C5e8e69D57562c0d129dd90a898eC4cB7) |
| Robinhood Chain testnet | 46630 | Morpho Blue (third-party instance) | `0xCff25c2c38c1D8966Fc9A205692B57Bde52A33Bb` |

The canonical Morpho Blue address (`0xBBBB…FFCb`) has no code on this testnet. The Morpho instance above was deployed by a third-party project, so it is a stand-in, not an official deployment.

### Live demo (testnet)

[`script/LiveDemo.s.sol`](script/LiveDemo.s.sol) runs the full flow onchain from one wallet. It creates a Morpho market (borrow dUSD against dSTOCK, LLTV 77%), opens a position, opts into WeekendGuard, drops the oracle price, and lets `protect()` restore the position.

| Step | Health factor |
|---|---|
| 10 dSTOCK collateral at $200, 1,200 dUSD debt | 1.283 |
| Oracle drops to $170 | **1.091** (below trigger 1.15) |
| `protect()` adds 2.834 dSTOCK (keeper fee 0.0085) | **1.400** (target) |

- `protect` tx: [`0x41fa79d2…bacbeee`](https://explorer.testnet.chain.robinhood.com/tx/0x41fa79d23fa1651df798faf066251c265780c82f49377c63507e759a8bacbeee)
- Market id: `0x7b0758e06eac7771c83af65c54a485fe249cf82965069ecdb53f0caf7e50facd`
- dSTOCK `0x86AbadcaCeb21d2b34FA451b17E2b5B633819324`, dUSD `0xeEeFe2BDBb6C7EB28D5CC2ecCd7c7F93D0136448`, oracle `0x645306e7e05F6316D9026e14Dee7e7dEe7034348` (demo mocks, freely mintable / settable)

```bash
forge script script/LiveDemo.s.sol --rpc-url robinhood_testnet --broadcast --interactive
```

## How it works

1. User calls `setConfig(marketId, config)` and approves the guard on the collateral token (or loan token for REPAY mode).
2. A keeper watches positions with `check(user, marketId)`.
3. When HF < trigger (computed on a *stressed* price during the weekend window), the keeper calls `protect(user, marketId)`.
4. The guard pulls the exact amount needed to restore `targetHf` (capped), supplies or repays on Morpho, and pays the keeper a small fee.

## Repository layout

```
src/WeekendGuard.sol          core contract
src/interfaces/IMorpho.sol    minimal Morpho Blue interface
test/WeekendGuard.t.sol       Foundry tests
test/mocks/Mocks.sol          mock Morpho / oracle / tokens
script/Deploy.s.sol           deployment script
script/LiveDemo.s.sol         end-to-end testnet demo
docs/SPEC.md                  specification
```

## License

MIT
