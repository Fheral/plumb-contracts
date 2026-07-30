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

script/Admin.s.sol          builds the privileged calls; signs and broadcasts nothing
script/DeployMainnet.s.sol  deploys on Base, and refuses a local RPC or a deployer keeping any role
script/DeployLocal.s.sol    deploys on a local anvil fork, and refuses to run anywhere else

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
BASE_RPC_URL=https://mainnet.base.org forge test          # 101 tests
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

## Deploying

```sh
DEPLOYER_PRIVATE_KEY=… OWNER=… OPERATOR=… FEE_RECIPIENT=… \
  forge script script/DeployMainnet.s.sol --rpc-url base --broadcast --verify
```

The script deploys the two contracts, owned by the multisig from the first
block, and stops there. It quotes nothing: `setVault`, `setBasePolicy`,
`setCollateralPolicy`, `setBlueMarket`, `setRiskParams`, `setOperator` and finally `openEpoch` are
`onlyOwner` calls, so they are the multisig's — it prints them in order, and
`script/Admin.s.sol` builds each one. `openEpoch` is last and deliberate: it is
what starts the quoting.

It refuses to run on any chain that is not Base, on a local RPC, and — the
check that matters — if the deployer would end up holding ownership, the
operator role or the fee stream. Copying the local invocation is the likely
accident, and the only one that cannot be undone.

The parameters it deploys with, and the reasoning behind each number, are in
[`CALIBRATION.md`](CALIBRATION.md).

## Governing a deployed vault

`owner` is a multisig, so every privileged call has to become a Safe
transaction. `script/Admin.s.sol` builds them — one entry point per action —
and does nothing else: no key, no broadcast, no signature. It simulates the
call against current chain state first and refuses to print a proposal that
would revert, then outputs the `to` / `value` / `data` triplet to paste into
the Transaction Builder.

```sh
VAULT=0x… forge script script/Admin.s.sol --sig 'state()' --rpc-url base
VAULT=0x… OPERATOR=0x… forge script script/Admin.s.sol --sig 'setOperator()' --rpc-url base
```

The point is that a proposal becomes a command line — reviewable in a PR,
reproducible, and checked before four people are asked to approve it, rather
than a form filled in once in a browser. The kill switch has its own
ready-to-copy command in the `kill()` NatSpec; it is the only action where
seconds count.

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

## Deployed on Base

| Contract | Address |
|----------|---------|
| PlumbVault (ERC-4626, USDC) | [`0xc57C5D7f73f3C0e2d84cb545D8c60f98B6E52648`](https://basescan.org/address/0xc57C5D7f73f3C0e2d84cb545D8c60f98B6E52648) |
| QuoteModule | [`0x4f380a37071eAC1453A0d84F4eEaa2bE0c88793f`](https://basescan.org/address/0x4f380a37071eAC1453A0d84F4eEaa2bE0c88793f) |
| Operator (bot key — quotes only, no funds) | [`0xE9513DD76b8f265Ff2ca1eA94d5070ed5F19DcBB`](https://basescan.org/address/0xE9513DD76b8f265Ff2ca1eA94d5070ed5F19DcBB) |

Market id: `0x9b7fed2a6b24c47b8995dfa4fb2b4bc87fe245c10fb842865e568611a96804aa`.
The vault is governed by a multisig from its first block. It is deployed and
wired, but does not quote yet: `openEpoch` — the last, deliberate step — has not
been called.

## Status

Development phases 1–3 are complete (vault, pricing policy, offchain
service). In progress: public fork shakedown, then a capped mainnet launch.
An external audit is planned before any cap raise. **Do not deposit funds
you cannot afford to lose.**
