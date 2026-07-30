// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {TickLib} from "../src/interfaces/midnight/TickLib.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

/// @dev A vault stand-in whose only job is to say what Blue pays. The floor has to be checked
///      against rates Blue is not printing today — that is the whole point of checking it.
contract BlueRateStub {
    uint256 public blueSupplyRateBps;

    function setRate(uint256 bps) external {
        blueSupplyRateBps = bps;
    }

    function book(bytes32) external pure returns (uint128, uint128, uint64, uint64) {
        return (0, 0, 0, 0);
    }

    /// @dev Any nonzero NAV: the per-market cap is a fraction of it, and only has to be nonzero for
    ///      the skew to divide. This stub's book is empty, so the skew is zero either way.
    function totalAssets() external pure returns (uint256) {
        return 1_000_000e6;
    }
}

/// @notice The bid is not a constant.
///
/// A fixed target rate has the defining flaw of static market making: you only get hit when you are
/// wrong. Quote 9% while the book prints 8% and nobody sells — the vault sleeps on Blue. Quote 9%
/// while the book prints 12% and everyone sells at once, right before rates climb further.
///
/// Three adjustments answer that, and this suite pins each one to an observable consequence rather
/// than to its formula: the inventory skew (the bid steps back as the book fills), the Blue floor
/// (never pay less than the idle sleeve already earns) and the collateral spread (two markets, two
/// risks, two prices).
contract PlumbQuoteDynamicTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");

    PlumbVault vault;
    QuoteModule quote;

    uint16 constant RATE_BPS = 1500; // well clear of the Blue floor, so the skew is what moves
    uint16 constant SKEW_BPS = 600;
    /// @dev 20% of the 500k deposit below: the same 100k the absolute cap used to name.
    uint16 constant MARKET_CAP_BPS = 2_000;
    uint128 constant BUDGET = 300_000e6;

    function setUp() public {
        _forkSetUp();

        quote = new QuoteModule(OWNER);
        vault = new PlumbVault(
            "Plumb Exit Liquidity USDC",
            "plUSDC",
            address(USDC),
            address(MIDNIGHT),
            BLUE,
            address(quote),
            OWNER,
            FEES,
            type(uint256).max
        );

        vm.startPrank(OWNER);
        quote.setVault(address(vault));
        _configure(RATE_BPS, 0, SKEW_BPS);
        vault.setBlueMarket(blueMarket());
        vault.setOperator(OPERATOR);
        vault.setRiskParams(6000, 200_000e6);
        vm.stopPrank();

        vm.prank(OPERATOR);
        vault.openEpoch(BUDGET);

        vm.startPrank(LP);
        IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);
        vault.deposit(500_000e6, LP);
        vm.stopPrank();
    }

    function _configure(uint16 rateBps, uint16 volSpreadBps, uint16 skewBps) internal {
        quote.setBasePolicy(
            QuoteModule.BasePolicy({
                rateBps: rateBps, skewBps: skewBps, minTenor: 1 days, maxTenor: 90 days, maxUnitsBps: MARKET_CAP_BPS
            })
        );
        _allowFixtureCollateral(quote, volSpreadBps);
    }

    /// @dev The per-market cap is a fraction of NAV now, so the tests read it rather than restating
    ///      it: an assertion against a constant would drift the moment the sleeve accrues on Blue.
    function _marketCap() internal view returns (uint256) {
        return quote.marketUnitCap(vault.totalAssets());
    }

    /// @dev The seller originates a loan then hands `units` to Plumb at its own bid.
    function _hitBid(uint256 units) internal {
        _originate(SELLER, units, 2500);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", units, SELLER, SELLER, address(0), "");
    }

    function _tick() internal view returns (uint256) {
        return quote.maxTick(midnightMarket(), MIDNIGHT.tickSpacing(id));
    }

    // -------------------------------------------------------------------------
    // 1. Inventory skew
    // -------------------------------------------------------------------------

    /// @notice The bid steps back as the market fills, instead of holding still then refusing.
    ///
    /// @dev This is the whole point of the skew. The cap is still there and still binds, but the
    ///      approach to it is now priced: each lot is bought a little cheaper than the last, so
    ///      concentration is paid for by the seller who causes it rather than worn by depositors.
    function test_SkewMovesTheBidAsTheBookFills() public {
        uint256 rateEmpty = quote.effectiveRateBps(midnightMarket());
        uint256 tickEmpty = _tick();
        assertEq(rateEmpty, RATE_BPS, "an empty book must quote the configured rate exactly");

        _hitBid(25_000e6); // a quarter of the market cap
        uint256 rateQuarter = quote.effectiveRateBps(midnightMarket());
        uint256 tickQuarter = _tick();

        // A different size on purpose: `_originate` derives its offer group from the size and the
        // timestamp, and reusing both in the same block would exhaust the group's budget.
        _hitBid(30_000e6);
        uint256 rateHalf = quote.effectiveRateBps(midnightMarket());
        uint256 tickHalf = _tick();

        console2.log("rate empty / quarter / half (bps)", rateEmpty, rateQuarter, rateHalf);

        // Demanded rate rises, hence price paid falls, hence tick falls. Monotone, strictly.
        assertGt(rateQuarter, rateEmpty, "a quarter-full book must demand more");
        assertGt(rateHalf, rateQuarter, "a half-full book must demand more still");
        assertLt(tickQuarter, tickEmpty, "a higher demanded rate must lower the tick");
        assertLt(tickHalf, tickQuarter, "the bid must keep stepping back");

        // Pro rata, not arbitrary: a quarter of the cap adds a quarter of the skew. Allow one bp
        // of slack for the truncated division.
        uint256 heldQuarter = _heldUnits();
        assertApproxEqAbs(
            rateQuarter, RATE_BPS + (uint256(SKEW_BPS) * 25_000e6) / _marketCap(), 1, "the skew must be pro rata"
        );
        assertGt(heldQuarter, 0, "the book must actually hold units");
    }

    function _heldUnits() internal view returns (uint256) {
        (uint128 units,,,) = vault.book(id);
        return units;
    }

    /// @notice A bid broadcast before the book filled stops being takeable on its own.
    ///
    /// @dev The offer sitting in the Mempool is a struct with a fixed tick; nothing cancels it. What
    ///      protects the vault is that `isRatified` re-reads the policy at the instant of the take,
    ///      and the policy has moved. Without the skew this could only happen when the owner changed
    ///      the rate; with it, the vault's own fills disarm its stale offers.
    function test_StaleBidIsRefusedOnceTheSkewHasMoved() public {
        Offer memory stale = vault.buildBid(midnightMarket(), type(uint256).max);

        _hitBid(60_000e6);
        assertLt(_tick(), stale.tick, "the skew must have moved the policy below the stale tick");

        _originate(SELLER, 10_000e6, 2500);
        vm.prank(SELLER);
        vm.expectRevert();
        MIDNIGHT.take(stale, "", 10_000e6, SELLER, SELLER, address(0), "");
    }

    /// @notice Held units above the cap saturate the skew rather than overshooting it.
    /// @dev Reachable in one move: the owner lowers the cap under a book already built. It is also
    ///      reachable without anyone acting, since the cap follows the NAV — a drawdown shrinks it
    ///      under a book that has not moved.
    function test_SkewSaturatesWhenHeldExceedsTheCap() public {
        _hitBid(60_000e6);

        // 1% of a 500k NAV is 5k, well under the 60k already held.
        vm.prank(OWNER);
        quote.setBasePolicy(
            QuoteModule.BasePolicy({
                rateBps: RATE_BPS, skewBps: SKEW_BPS, minTenor: 1 days, maxTenor: 90 days, maxUnitsBps: 100
            })
        );

        assertEq(quote.effectiveRateBps(midnightMarket()), RATE_BPS + SKEW_BPS, "the skew must saturate, not overshoot");
    }

    // -------------------------------------------------------------------------
    // 2. Blue floor
    // -------------------------------------------------------------------------

    /// @notice The vault reads a real, non-zero supply rate from the live Blue market.
    /// @dev The floor is worth nothing if the number behind it is a stub. This measures it on the
    ///      fork, against the same USDC/WETH market the idle sleeve actually sits in.
    function test_BlueSupplyRateIsRealAndSane() public view {
        uint256 rate = vault.blueSupplyRateBps();
        console2.log("Blue supply rate (bps)", rate);
        assertGt(rate, 0, "the idle sleeve earns something, and the policy must see it");
        assertLt(rate, 5000, "an implausible rate means the annualization is wrong");
    }

    /// @notice Below the floor, Plumb demands the floor — it never buys under its own idle yield.
    function test_FloorLiftsARateThatWouldDestroyValue() public {
        uint256 blueRate = vault.blueSupplyRateBps();
        uint256 margin = quote.blueFloorMarginBps();

        // Configure deliberately below Blue: the mistake the floor exists to make impossible.
        uint16 minRate = uint16(quote.MIN_RATE_BPS());
        vm.startPrank(OWNER);
        _configure(minRate, 0, 0);
        vm.stopPrank();

        uint256 effective = quote.effectiveRateBps(midnightMarket());
        assertEq(effective, blueRate + margin, "under the floor, the floor is what is demanded");
        assertGt(effective, blueRate, "Plumb must never bid at or below its own opportunity cost");
    }

    /// @notice Above the floor, the floor is inert — it is a floor, not a peg.
    function test_FloorDoesNotTouchARateAlreadyAboveIt() public view {
        uint256 blueRate = vault.blueSupplyRateBps();
        assertGt(RATE_BPS, blueRate + quote.blueFloorMarginBps(), "test premise: the configured rate clears the floor");
        assertEq(
            quote.effectiveRateBps(midnightMarket()), RATE_BPS, "a rate above the floor must pass through untouched"
        );
    }

    /// @notice When Blue out-earns anything Plumb may legitimately bid, Plumb stops quoting.
    ///
    /// @dev The alternative would be to clamp at MAX_RATE_BPS and keep buying below the floor —
    ///      exactly the value destruction the floor forbids. Refusing to quote is the only honest
    ///      answer. Blue paying 35% does not happen on the fork, hence the mock.
    function test_FloorAboveTheHardMaxStopsTheQuote() public {
        vm.mockCall(address(vault), abi.encodeWithSignature("blueSupplyRateBps()"), abi.encode(uint256(3500)));

        vm.expectRevert(QuoteModule.BelowBlueFloor.selector);
        quote.effectiveRateBps(midnightMarket());

        // The spacing read is hoisted: a nested external call in an argument list consumes the
        // pending `expectRevert`.
        uint8 spacing = MIDNIGHT.tickSpacing(id);
        vm.expectRevert(QuoteModule.BelowBlueFloor.selector);
        quote.maxTick(midnightMarket(), spacing);

        // And the vault refuses the offer that a bot might still be broadcasting.
        vm.expectRevert(QuoteModule.BelowBlueFloor.selector);
        vault.buildBid(midnightMarket(), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // 3. Collateral spread
    // -------------------------------------------------------------------------

    /// @notice Two markets, two collateral risks, two prices.
    /// @dev The spread is flat and configured, not inferred — but it is applied by the same
    ///      on-chain path as the rest, so the bot cannot quote around it.
    function test_VolSpreadPricesCollateralRisk() public {
        uint256 tickPlain = _tick();

        vm.startPrank(OWNER);
        _configure(RATE_BPS, 400, SKEW_BPS);
        vm.stopPrank();

        assertEq(quote.effectiveRateBps(midnightMarket()), RATE_BPS + 400, "the spread must add to the demanded rate");
        assertLt(_tick(), tickPlain, "a riskier collateral must be bid lower");
    }

    // -------------------------------------------------------------------------
    // 4. Bounds and wiring
    // -------------------------------------------------------------------------

    /// @notice The adjustments can never breach the immutable bounds.
    /// @dev They are additive and non-negative: MIN is unreachable from above, MAX is clamped.
    function testFuzz_AdjustmentsStayWithinTheImmutableBounds(uint16 rateBps, uint16 vol, uint16 skew, uint128 held)
        public
    {
        rateBps = uint16(bound(rateBps, quote.MIN_RATE_BPS(), quote.MAX_RATE_BPS()));
        vol = uint16(bound(vol, 0, quote.MAX_ADJUSTMENT_BPS()));
        skew = uint16(bound(skew, 0, quote.MAX_ADJUSTMENT_BPS()));

        vm.startPrank(OWNER);
        _configure(rateBps, vol, skew);
        vm.stopPrank();

        // The book is mocked rather than filled: this property is about arithmetic, and filling
        // would bound `held` to what the cap and the NAV allow.
        vm.mockCall(
            address(vault),
            abi.encodeWithSignature("book(bytes32)", id),
            abi.encode(held, uint128(0), uint64(0), uint64(MATURITY))
        );

        uint256 effective = quote.effectiveRateBps(midnightMarket());
        assertGe(effective, quote.MIN_RATE_BPS(), "the rate can never fall under the immutable floor");
        assertLe(effective, quote.MAX_RATE_BPS(), "the rate can never exceed the immutable ceiling");
        assertGe(effective, rateBps, "an adjustment can only raise the demanded rate");
    }

    /// @notice An adjustment configured above the bounds is refused outright — on either half of
    ///         the policy, since the two adjustments now live in different setters.
    function test_OwnerCannotConfigureAnUnboundedAdjustment() public {
        uint16 tooMuch = uint16(quote.MAX_ADJUSTMENT_BPS() + 1);

        vm.startPrank(OWNER);
        vm.expectRevert(QuoteModule.AdjustmentOutOfBounds.selector);
        quote.setCollateralPolicy(
            WETH, QuoteModule.CollateralPolicy({allowed: true, volSpreadBps: tooMuch, maxLltv: 0.86e18})
        );

        vm.expectRevert(QuoteModule.AdjustmentOutOfBounds.selector);
        quote.setBasePolicy(
            QuoteModule.BasePolicy({
                rateBps: RATE_BPS, skewBps: tooMuch, minTenor: 1 days, maxTenor: 90 days, maxUnitsBps: MARKET_CAP_BPS
            })
        );
        vm.stopPrank();
    }

    /// @notice A policy with no per-market cap cannot price the skew, so it cannot be set.
    function test_PolicyNeedsANonZeroUnitCap() public {
        vm.prank(OWNER);
        vm.expectRevert(QuoteModule.ZeroUnitCap.selector);
        quote.setBasePolicy(
            QuoteModule.BasePolicy({rateBps: RATE_BPS, skewBps: 0, minTenor: 1 days, maxTenor: 90 days, maxUnitsBps: 0})
        );
    }

    /// @notice Without its vault, the policy refuses to quote rather than quoting unadjusted.
    /// @dev Failing closed matters here: an unskewed, unfloored quote is precisely the static bid
    ///      this whole mechanism replaces, and a half-finished deployment must not produce one.
    function test_PolicyWithoutVaultRefusesToQuote() public {
        QuoteModule fresh = new QuoteModule(OWNER);
        vm.startPrank(OWNER);
        _configurePolicy(fresh, uint16(RATE_BPS));
        vm.stopPrank();

        uint8 spacing = MIDNIGHT.tickSpacing(id);
        vm.expectRevert(QuoteModule.VaultNotSet.selector);
        fresh.maxTick(midnightMarket(), spacing);
    }

    /// @notice Only the owner moves the policy's own wiring.
    function test_OnlyOwnerSetsVaultAndMargin() public {
        vm.expectRevert();
        quote.setVault(address(vault));

        vm.expectRevert();
        quote.setBlueFloorMargin(100);

        vm.prank(OWNER);
        quote.setBlueFloorMargin(100);
        assertEq(quote.blueFloorMarginBps(), 100, "the owner must be able to retune the margin");
    }

    // -------------------------------------------------------------------------
    // 5. The continuous fee is not a blank cheque
    // -------------------------------------------------------------------------

    /// @notice Plumb starts out refusing to pay any continuous fee at all.
    ///
    /// @dev Midnight's continuous fee is set by its governance, at any time, and applies to offers
    ///      already broadcast. Every Base market prices it at zero today; the point of the default
    ///      is that the day it stops being zero, Plumb's takes revert instead of quietly handing
    ///      the depositors' yield over.
    function test_TheBidPromisesNoContinuousFeeByDefault() public view {
        assertEq(quote.continuousFeeCap(), 0, "the policy must not accept a fee nobody has priced");
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        assertEq(bid.continuousFeeCap, 0, "the offer must carry the policy's cap, not its own");
    }

    /// @notice And ratification enforces it: the bot cannot promise more than the policy accepts.
    function test_RatificationRefusesAnOfferPromisingMoreThanThePolicy() public {
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        bid.continuousFeeCap = 1;

        vm.expectRevert(PlumbVault.OfferFeeCapTooHigh.selector);
        vault.isRatified(bid, "", SELLER);
    }

    /// @notice Raising the cap is the owner's call, and it moves the bid.
    function test_TheOwnerCanPriceInAContinuousFee() public {
        vm.expectRevert();
        quote.setContinuousFeeCap(1000);

        vm.prank(OWNER);
        quote.setContinuousFeeCap(1000);

        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        assertEq(bid.continuousFeeCap, 1000, "the bid must follow the policy up");
        vault.isRatified(bid, "", SELLER);

        bid.continuousFeeCap = 1001;
        vm.expectRevert(PlumbVault.OfferFeeCapTooHigh.selector);
        vault.isRatified(bid, "", SELLER);
    }

    /// @notice The cap cannot be set beyond the fee Midnight would itself accept.
    ///
    /// @dev Pinned against the upstream constant rather than restated: Midnight's
    ///      `ConstantsLib.MAX_CONTINUOUS_FEE` is `uint32(uint256(0.01e18) / uint256(365 days))`,
    ///      enforced in `setMarketContinuousFee` and `setDefaultContinuousFee`. Anything above it
    ///      is a number the owner could write and no market could ever match — a policy that reads
    ///      like a decision without being one.
    function test_TheCapIsBoundedByWhatMidnightWouldAccept() public {
        uint256 max = quote.MAX_CONTINUOUS_FEE_CAP();
        assertEq(max, uint256(0.01e18) / uint256(365 days), "must track Midnight's own ceiling");
        assertEq((max * 90 days * 10_000) / 1e18, 24, "i.e. at most ~24.66 bps over a 90-day tenor");

        vm.startPrank(OWNER);
        quote.setContinuousFeeCap(max);

        vm.expectRevert(QuoteModule.FeeCapOutOfBounds.selector);
        quote.setContinuousFeeCap(max + 1);
        vm.stopPrank();
    }

    /// @notice A fee Plumb has priced in does not block the take.
    /// @dev The end-to-end check that the cap is a ceiling and not a required value: the market's
    ///      fee is zero on the fork, and a non-zero cap must still let a seller through.
    function test_ARaisedCapStillFills() public {
        vm.prank(OWNER);
        quote.setContinuousFeeCap(1000);

        _hitBid(10_000e6);
        (uint128 units,,,) = vault.book(id);
        assertEq(units, 10_000e6, "a cap above the market's fee must not stand in the way");
    }

    // -------------------------------------------------------------------------
    // 6. The Blue floor cannot take the bid offline
    // -------------------------------------------------------------------------

    /// @notice The margin we ship leaves room for a Blue rate far above anything USDC has printed.
    ///
    /// @dev `effectiveRateBps` reverts with `BelowBlueFloor` when `blueRate + margin` exceeds
    ///      `MAX_RATE_BPS`: Plumb refuses to bid rather than quote above the bound that protects
    ///      the counterparty. Correct, and the reason the pair (margin, Blue rate) has to be
    ///      checked as a pair — a margin chosen on its own merits can silently pin the vault
    ///      offline the day Blue spikes.
    ///
    ///      The bound is arithmetic and exact: the bid survives every Blue rate up to
    ///      `MAX_RATE_BPS - margin`. At the shipped margin of 200 bps that is **28%** — Blue's USDC
    ///      supply rate reads 4.6% at the pinned block and its stress peaks are an order of
    ///      magnitude below 28%. What this test pins is the headroom, so that raising the margin
    ///      later is a choice made against a number.
    function test_TheShippedMarginLeavesTwentyEightPointsOfHeadroom() public {
        QuoteModule solo = new QuoteModule(OWNER);
        BlueRateStub stub = new BlueRateStub();

        vm.startPrank(OWNER);
        solo.setVault(address(stub));
        solo.setBasePolicy(
            QuoteModule.BasePolicy({
                rateBps: 900, skewBps: 600, minTenor: 1 days, maxTenor: 90 days, maxUnitsBps: 2_500
            })
        );
        _allowFixtureCollateral(solo, 250);
        vm.stopPrank();

        uint256 margin = solo.blueFloorMarginBps();
        uint256 maxRate = solo.MAX_RATE_BPS();
        assertEq(margin, 200, "the shipped margin");

        // Right at the edge: the floor equals the ceiling, and Plumb still quotes.
        stub.setRate(maxRate - margin);
        assertEq(solo.effectiveRateBps(midnightMarket()), maxRate, "at the edge the bid must survive");

        // One basis point further and it steps aside rather than quoting above MAX_RATE_BPS.
        stub.setRate(maxRate - margin + 1);
        vm.expectRevert(QuoteModule.BelowBlueFloor.selector);
        solo.effectiveRateBps(midnightMarket());
    }

    /// @notice And the three adjustments together never saturate the clamp on their own.
    /// @dev If `rateBps + volSpreadBps + skewBps` reached `MAX_RATE_BPS`, a full book would quote
    ///      the same rate as a half-full one and the skew would stop saying anything. The shipped
    ///      set tops out at 17.5%, well inside the 30% clamp.
    function test_TheShippedAdjustmentsNeverReachTheClamp() public {
        vm.startPrank(OWNER);
        _configure(900, 250, 600);
        vm.stopPrank();
        assertLt(900 + 250 + 600, quote.MAX_RATE_BPS(), "a saturated skew is a skew that says nothing");
    }

    // -------------------------------------------------------------------------
    // 7. What it costs
    // -------------------------------------------------------------------------

    /// @notice The floor puts an IRM call on the critical path of every take. Measure it.
    ///
    /// @dev `isRatified` now reads Blue's rate model on top of the vault's own book. The bound is
    ///      deliberately loose — it is an alarm for a change that made ratification expensive, not
    ///      a performance target. What would be unacceptable is a seller giving up on the take.
    function test_RatificationGasWithTheDynamicPolicy() public view {
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);

        uint256 g0 = gasleft();
        vault.isRatified(bid, "", SELLER);
        uint256 gasRatify = g0 - gasleft();

        console2.log("isRatified with skew + Blue floor, gas", gasRatify);
        assertLt(gasRatify, 200_000, "ratification must stay cheap enough to sit inside a take");
    }
}
