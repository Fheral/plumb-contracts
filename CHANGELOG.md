# Changelog

All notable changes to the Plumb contracts are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Contracts are immutable once deployed, so a version here describes *source*,
not a live deployment. A release becomes real on Base only when the addresses
below list it.

- **MAJOR** — a change to the on-chain policy, the ratification rules, the
  accounting, or any external signature. Integrators must re-read the code.
- **MINOR** — new external surface that does not change existing behaviour.
- **PATCH** — comments, NatSpec, tests, tooling. No bytecode-relevant change.

## [Unreleased]

## [0.2.0] — 2026-07-28

The source cut for the Phase 4 capped mainnet run: the Base deployment and
admin tooling, plus two breaking corrections to how Midnight's continuous fee
is bounded and accounted for. Still **not deployed** — cutting this release is
what keeps the public mirror matching the bytecode that goes on-chain; mainnet
addresses are listed here on release, once Phase 4 completes.

### Added

- `script/DeployMainnet.s.sol` — the Base deployment. Deploys the vault and the
  policy owned by the multisig from the first block, then stops: everything
  after that is `onlyOwner`, so it prints the calls in order rather than
  performing them, and `openEpoch` — the call that starts the quoting — is left
  to a deliberate moment. Refuses any chain but Base, a local RPC, and a
  deployer that would keep ownership, the operator role or the fee stream.
- `CALIBRATION.md` — the parameters the policy is deployed with and the
  reasoning that produced each one, including what is *not* known: Midnight is
  too young to fit anything against, so every value is derived from a stated
  principle and carries the observation that would move it.
- `script/Admin.s.sol` — builds every privileged call of a deployed vault
  (`unpause`, `setOperator`, `setBlueMarket`, `setRiskParams`, `setFee`,
  `kill`, `openEpoch`, and the `QuoteModule` knobs) as a Safe-ready
  `to`/`value`/`data` triplet. It holds no key and broadcasts nothing: it
  simulates the call against current chain state, refuses to print a proposal
  that reverts, and prints the calldata. `state()` dumps what the two
  contracts hold today, which is what a parameter change has to be read
  against.

### Changed

- **Breaking (policy)** — an offer's `continuousFeeCap` is now bounded by
  `QuoteModule.continuousFeeCap()` instead of the `type(uint256).max / 2`
  arithmetic ceiling. Midnight's continuous fee is set by its governance, at
  any time, and applies to offers already broadcast; the previous bound let it
  take an unbounded share of the depositors' yield without Plumb redeploying or
  even rebroadcasting. The policy now states what Plumb accepts to pay, and
  `isRatified` refuses anything above it.

  The default is **zero**, which is the fee every Base market prices today. If
  Midnight ever switches it on, takes revert until the owner prices the fee in
  via `setContinuousFeeCap` — an outage rather than a silent leak. The cap is
  denominated in Midnight's own units and bounded by
  `MAX_CONTINUOUS_FEE_CAP = 317_097_919`, Midnight's own
  `ConstantsLib.MAX_CONTINUOUS_FEE` (1% a year, i.e. at most 24.66 bps of a lot
  over a 90-day tenor). Anything above it is a fee no market could ever charge.

- **Breaking (accounting)** — a lot is now marked at `credit - pendingFee`
  rather than `credit`. Midnight's `credit` is net of the continuous fee
  accrued *so far*; the remainder sits in `pendingFee` and comes out of
  `credit` by maturity, so the par a lot accretes toward is the difference.
  Marking against `credit` alone counted Midnight's fee as depositors' value
  for a lot's whole life.

  The gap is bounded by `pendingFee` and closes to exactly zero at maturity, so
  it never shows in a settled amount — only in the share price of anyone
  entering or leaving mid-life. It is also zero in practice today: with
  `continuousFeeCap` at zero no lot can carry a `pendingFee` at all.
  `PlumbVault._redeemable` is therefore a no-op that has to exist *before*
  that cap is ever raised. The two are a pair.

## [0.1.0] — 2026-07-28

First tagged release. Phases 1–3 complete: the vault, the pricing policy and
the full test suite are in place. **Not yet deployed to Base mainnet** —
Phase 4 (fork rehearsal, then a capped mainnet run) and the external audit
come first.

### Added

- `PlumbVault` — ERC-4626 vault (USDC) that holds the standing bid on the
  Morpho Midnight order book. It is its own `ratifier` and its own
  `buyCallback`: offers are validated field by field against the on-chain
  policy, with no signature involved, and `onBuy()` withdraws from Morpho
  Blue, records the lot and enforces the book cap atomically — rejecting
  before any capital moves.
- `QuoteModule` — the pricing policy: target rate → Midnight tick, bounded by
  `maxTick()`, which ratification enforces.
- `src/interfaces/midnight/` — the reverse-engineered Midnight surface
  (`IMidnight`, `IRatifier`, `ICallbacks`, `IdLib`, `TickLib`) and
  `IMorphoBlue`.
- Epoch budgets keyed by `group = keccak256("plumb.bid", vault, epoch)`, with
  `kill()` exhausting the budget in one transaction (every live offer dies at
  once) and `openEpoch(budget)` reopening.
- Role split: `owner` (multisig) sets parameters, caps and fees; `operator`
  (the bot key) sets no price and can withdraw no funds.
- Test suite running against a Base fork — Midnight is not mocked: lifecycle,
  caps, kill switch, bypass attempts, borrower default and NAV absorption,
  field-by-field ratification, "Blue dry" degradation, up to 8 active
  markets, fuzz-tested properties and stateful invariants.

### Deployments

None yet. Mainnet addresses will be listed here, per release, once Phase 4
completes.

[Unreleased]: https://github.com/Fheral/plumb-contracts/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/Fheral/plumb-contracts/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Fheral/plumb-contracts/releases/tag/v0.1.0
