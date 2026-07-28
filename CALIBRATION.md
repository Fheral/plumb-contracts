# Calibration — the numbers the policy is deployed with

`QuoteModule` decides the price. Its constants (`MIN_RATE_BPS`, `MAX_RATE_BPS`,
`MAX_TENOR`, `MAX_ADJUSTMENT_BPS`) are immutable and need no defence beyond the
code. Its *parameters* do: `rateBps`, `volSpreadBps` and `skewBps` per market,
`blueFloorMarginBps` globally, and the continuous fee cap. Those are the
numbers a Safe transaction can change, so they are the numbers that have to be
written down with the reasoning that produced them.

This file is that reasoning. It is also, deliberately, an admission of what is
not yet known.

## The constraint everything else sits under

Midnight is small. At the time of writing, ~159k USDC outstanding across six
live markets, ~14k USDC of daily take volume, and traded rates of **3.6–3.7%**.
Morpho Blue's USDC supply rate reads **4.60%** at the block the test suite is
pinned to.

There is no series long enough to fit anything against. Every number below is
therefore derived from a stated principle, not estimated from data, and each
one carries the observation that would move it. **The real calibration happens
during Phase 4** — the fork shakedown and then the capped mainnet run — against
fills that actually occurred.

## Method

Four questions, answered in order. Each one bounds the next.

1. **What must Plumb never do?** Bid below what the idle sleeve already earns.
   That fixes the floor: `blueSupplyRateBps + blueFloorMarginBps`.
2. **What is Plumb selling?** Immediacy. A lender exiting early has no natural
   counterparty; the discount is the price of not waiting. That fixes the base
   rate: it sits above both the floor and the rate the book itself prints.
3. **What does the collateral change?** Default risk at maturity, per market.
   That fixes the spread.
4. **What does Plumb's own position change?** A book that is filling up is a
   book concentrating risk. That fixes the skew.

A fifth question — what the *competition* charges — has no answer yet. Nobody
else holds a standing bid on Midnight. The day someone does, the base rate
becomes an observable and this method's step 2 gets replaced.

## The values

| Parameter | Value | Where |
|---|---|---|
| `rateBps` | 900 (9%) | per market, `setMarketConfig` |
| `volSpreadBps` | 150 / 250 | per market, by collateral (below) |
| `skewBps` | 600 (6%) | per market, `setMarketConfig` |
| `blueFloorMarginBps` | 200 (2%) | global, `setBlueFloorMargin` |
| `continuousFeeCap` | 0 | global, `setContinuousFeeCap` |

### `blueFloorMarginBps = 200`

The minimum Plumb charges for its own illiquidity: capital that goes onto the
book stops being withdrawable on demand, and 2% a year over Blue is the
smallest number that makes that trade non-absurd.

The binding check is not the level, it is the **headroom**. `effectiveRateBps`
reverts with `BelowBlueFloor` once `blueRate + margin > MAX_RATE_BPS`: Plumb
stops bidding rather than quote above the bound that protects the seller. At a
200 bps margin the bid survives every Blue rate up to **28%**, against 4.6%
today and stress peaks an order of magnitude below that ceiling.
`test_TheShippedMarginLeavesTwentyEightPointsOfHeadroom` pins both edges.

Anything up to a 1000 bps margin would still leave 20 points of headroom. The
reason not to go there is not safety, it is that the margin would then be doing
the pricing that `rateBps` is supposed to do.

### `rateBps = 900`

The book prints 3.6–3.7%. Plumb bids at 9%, i.e. it buys at a materially wider
discount than the market clears at, which is exactly what a standing bid for
immediacy should do — and that gap **is** the depositors' yield. Below roughly
7% the bid stops being distinguishable from the floor (4.6 + 2 = 6.6% today)
and `rateBps` would be decorative.

Revise it when fills stop happening (too wide — the flow goes elsewhere or
nowhere) or when the book fills instantly and stays full (too narrow — Plumb is
the cheapest exit in the market and is being adversely selected).

### `volSpreadBps` — 150 or 250, by collateral

A flat premium per market, because a lot backed by WETH and a lot backed by a
levered wrapper do not carry the same risk of arriving at maturity impaired.
Midnight's live Base markets use two collaterals:

| Collateral | LLTV | Spread | Why |
|---|---|---|---|
| `WETH` | 86% | **150** | 14 points of buffer before a default touches the lender, on the deepest collateral on Base. |
| `WETH-USDC-collat` | 98% | **250** | 2 points of buffer. A wrapper, and a thinner one: less room between a price move and an impaired position, so more premium — the LLTV being higher is a reason to charge *more*, not less. |

A market that accepts several collaterals takes the **highest** spread of the
ones it accepts: the borrower picks, so the market carries the risk of the
worst one it allows.

This is the parameter with the least evidence behind it. `lossFactor = 0` on
every Midnight market since launch — no default has ever occurred, so the
premium is priced against a distribution nobody has sampled. It is a floor on
what we would charge, not an estimate of what we should.

### `skewBps = 600`

The bid steps back by up to 6 points as the market fills, pro rata. Two bounds
decide the number.

- **Below ~300** the skew is cosmetic: the difference between an empty book and
  a full one is smaller than the tick spacing's effect, and we are back to the
  binary cap the skew exists to replace.
- **`rateBps + volSpreadBps + skewBps` must stay under `MAX_RATE_BPS`.** If the
  sum reached 3000 the clamp would bite before the book was full, a full book
  and a three-quarters-full one would quote identically, and the skew would stop
  saying anything. The shipped set tops out at 900 + 250 + 600 = **1750**, well
  inside. `test_TheShippedAdjustmentsNeverReachTheClamp` pins it.

At 600, a full book demands 15–17.5% against 10.5–11.5% empty: the last lot
bought before the cap is bought far more cheaply than the first, which is the
point — concentration is paid for by the seller causing it, not worn by the
depositors.

### `continuousFeeCap = 0`

Not a calibration, a refusal — but a refusal of something now measured. Midnight
caps its own continuous fee at `MAX_CONTINUOUS_FEE = uint32(0.01e18 / 365 days)`,
an immutable 1% a year, so the worst case is **24.66 bps** of a lot over a 90-day
tenor: about 1.4% of a 1750 bps bid. On Base the fee is zero on every market and
`feeSetter` is `address(0)`, meaning no one can currently set one at all.

Zero is therefore a stance, not an admission of ignorance: we decline to pay a
fee we have not seen priced anywhere, and we would rather stop quoting than pay
it silently. Two conditions before raising it:

- `PlumbVault._redeemable` must be in place, or the book overstates itself by
  the `pendingFee` a nonzero fee creates. It is, and it is a no-op until this
  cap moves — see `SECURITY-NOTES.md`.
- The monitoring alert on `feeSetter != address(0)` must exist, so the decision
  is taken when governance appoints a fee setter rather than after the fact.

## What Phase 4 has to produce

The list below is what turns this document from a set of principles into a
calibration. None of it can be answered before Plumb has traded.

- [ ] **Fill rate against quoted rate.** Every `Take` on a Plumb offer, with the
      effective rate at that instant. Without it, "9% is too wide" and "9% is
      too narrow" are both unfalsifiable.
- [ ] **Missed flow.** Takes on *other* makers' bids that Plumb could have
      served and did not. This is the only direct measure of being uncompetitive.
- [ ] **Realized default rate per collateral**, if any default ever occurs.
      Until then `volSpreadBps` stays a stated policy rather than a price.
- [ ] **Blue rate distribution over the run**, to confirm the floor's headroom
      against something observed rather than assumed.

## Keeping the simulator honest

`lib/simulate.ts` (the public simulator on the front end) carries the same
numbers as defaults. It has to: a simulator that tells a different story from
production is worse than no simulator. When a value changes here, it changes
there, in the same commit.
