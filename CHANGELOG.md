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

[Unreleased]: https://github.com/Fheral/plumb-contracts/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Fheral/plumb-contracts/releases/tag/v0.1.0
