# Plumb — contracts

**Plumb is an exit-liquidity vault for Morpho Midnight on Base.**

A Midnight lender who wants out before maturity has no natural counterparty.
Plumb is one, permanently: the vault holds the standing bid on the order book
and buys credit units at a discount. That discount is the depositors' yield;
capital waiting to be deployed earns on Morpho Blue in the meantime.

> This repository is a **read-only mirror**, synced automatically from the
> main monorepo on every merge. Pull requests opened here would be
> overwritten by the next sync.

## How it works

1. Depositors enter the vault (ERC-4626, USDC). Idle capital is supplied to
   Morpho Blue.
2. The offchain service broadcasts bids into the Midnight Mempool — but it
   sets no prices: every offer is built by `vault.buildBid()` from the
   on-chain policy.
3. When a seller executes an offer (`take`), Midnight calls
   `PlumbVault.isRatified()`: the offer is checked field by field against the
   on-chain policy, including `tick <= QuoteModule.maxTick(...)`. **No
   signature is involved.**
4. `onBuy()` then withdraws the required amount from Blue, records the lot
   and enforces the book cap — atomically, rejecting **before** any capital
   moves.
5. At maturity, positions are settled and proceeds return to the vault.

A consequence of this design: a compromised bot key cannot quote anything the
on-chain policy would not have quoted. The `operator` sets no prices and can
withdraw no funds; only the `owner` (a multisig) sets parameters, caps and
fees. `kill()` exhausts the epoch budget in one transaction and pulls every
live offer.

## Layout

```
src/PlumbVault.sol         the vault: accounting, ratification, execution, caps
src/QuoteModule.sol        the pricing policy: target rate → Midnight tick
src/interfaces/            Morpho Blue + the reverse-engineered Midnight surface

test/PlumbVault.t.sol        lifecycle, caps, kill switch, bypass attempts
test/PlumbDefault.t.sol      borrower default: real slashing, NAV absorption
test/PlumbAdversarial.t.sol  field-by-field ratification, access control, value extraction
test/PlumbLiquidity.t.sol    "Blue dry" degradation
test/PlumbMultiMarket.t.sol  load and gas cost up to 8 active markets
test/PlumbFuzz.t.sol         fuzz-tested properties
test/PlumbInvariant.t.sol    stateful invariants: random action sequences
```

## Build and test

Prerequisites: [Foundry](https://getfoundry.sh) (nightly ≥ 1.6.0) and a Base
RPC endpoint. Dependencies install with `forge install`. The whole suite runs
on a Base fork: Midnight is not mocked — tests execute against the contracts
actually deployed on mainnet.

```sh
BASE_RPC_URL=https://mainnet.base.org forge test          # 60 tests
FOUNDRY_PROFILE=mid  BASE_RPC_URL=... forge test          # fuzz 256 runs, 48×64 stateful campaign
```

The fork is pinned to a fixed block (`BASE_FORK_BLOCK` to change it, `0` to
follow the head): without pinning, the fork cache is invalidated on every run
and fuzzing gets rate-limited by the RPC. The `deep` profile needs a
dedicated endpoint.

`evm_version = "osaka"` is **mandatory**: Midnight is compiled for that spec,
and any earlier spec makes `take()` fail with `NotActivated`.

### Two pitfalls that waste time

- **Foundry caches invariant failures** under `cache/invariant/failures` and
  replays them indefinitely, even after the fix. `rm -rf cache/invariant` to
  start clean — otherwise you are debugging a failure that no longer exists.
- **An external call nested in an argument list** consumes the pending
  `vm.prank` or `vm.expectRevert`.
  `vault.setFee(vault.MAX_PERF_FEE_BPS() + 1, x)` therefore executes from the
  wrong address. Always hoist the read into a local variable first.

## Static analysis

```sh
slither .
```

Justified exclusions are pinned in `slither.config.json`; the detailed triage
(remaining findings, uncovered scope) lives in the main monorepo and will be
published alongside the audit report.

## Releases

This mirror tracks the tip of the monorepo's `main`, which is convenient for
reading and useless for depending on. Tagged releases are the fixed points:
each one carries its `CHANGELOG.md` entry and a zip of the ABIs
(`PlumbVault`, `QuoteModule`, `IQuoteContext`) built from that exact source.

See [releases](https://github.com/Fheral/plumb-contracts/releases) and
[`CHANGELOG.md`](CHANGELOG.md). Versions describe *source*, not a live
deployment — a release is on Base only when the changelog entry lists its
addresses.

## Two things to know before reading the code

The vault is **its own ratifier** and **its own buy callback**. An offer is
only valid if `isRatified` recognizes it, and `isRatified` checks it against
on-chain state — not against a signature. The bot only broadcasts what
`buildBid()` produces; it cannot quote anything the policy would not have
quoted.

Midnight's `credit()` getter returns the **stored** value: after a default,
it does not see the loss until an `updatePosition` has run. Any read of the
book — here as well as on the monitoring side — must go through
`updatePositionView`.

## Status

Development phases 1–3 are complete (vault, pricing policy, offchain
service). In progress: public fork shakedown, then a capped mainnet launch.
An external audit is planned before any cap raise. **Do not deposit funds
you cannot afford to lose.**
