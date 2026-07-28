// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {TickLib} from "../src/interfaces/midnight/TickLib.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

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
    uint128 constant MARKET_CAP = 100_000e6;
    uint128 constant BUDGET = 300_000e6;

    function setUp() public {
        _forkSetUp();

        quote = new QuoteModule(OWNER);
        vault = new PlumbVault(
            "Plumb Exit Liquidity USDC", "plUSDC", address(USDC), address(MIDNIGHT), BLUE, address(quote), OWNER, FEES
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
        quote.setMarketConfig(
            id,
            QuoteModule.MarketConfig({
                enabled: true,
                rateBps: rateBps,
                volSpreadBps: volSpreadBps,
                skewBps: skewBps,
                minTenor: 1 days,
                maxTenor: 90 days,
                maxUnits: MARKET_CAP
            })
        );
    }

    /// @dev The seller originates a loan then hands `units` to Plumb at its own bid.
    function _hitBid(uint256 units) internal {
        _originate(SELLER, units, 2500);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", units, SELLER, SELLER, address(0), "");
    }

    function _tick() internal view returns (uint256) {
        return quote.maxTick(id, MATURITY, MIDNIGHT.tickSpacing(id));
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
        uint256 rateEmpty = quote.effectiveRateBps(id);
        uint256 tickEmpty = _tick();
        assertEq(rateEmpty, RATE_BPS, "an empty book must quote the configured rate exactly");

        _hitBid(25_000e6); // a quarter of the market cap
        uint256 rateQuarter = quote.effectiveRateBps(id);
        uint256 tickQuarter = _tick();

        // A different size on purpose: `_originate` derives its offer group from the size and the
        // timestamp, and reusing both in the same block would exhaust the group's budget.
        _hitBid(30_000e6);
        uint256 rateHalf = quote.effectiveRateBps(id);
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
            rateQuarter, RATE_BPS + (uint256(SKEW_BPS) * 25_000e6) / MARKET_CAP, 1, "the skew must be pro rata"
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
    /// @dev Reachable in one move: the owner lowers `maxUnits` under a book already built.
    function test_SkewSaturatesWhenHeldExceedsTheCap() public {
        _hitBid(60_000e6);

        vm.prank(OWNER);
        quote.setMarketConfig(
            id,
            QuoteModule.MarketConfig({
                enabled: true,
                rateBps: RATE_BPS,
                volSpreadBps: 0,
                skewBps: SKEW_BPS,
                minTenor: 1 days,
                maxTenor: 90 days,
                maxUnits: 10_000e6 // now well below what is held
            })
        );

        assertEq(quote.effectiveRateBps(id), RATE_BPS + SKEW_BPS, "the skew must saturate, not overshoot");
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
        vm.prank(OWNER);
        _configure(minRate, 0, 0);

        uint256 effective = quote.effectiveRateBps(id);
        assertEq(effective, blueRate + margin, "under the floor, the floor is what is demanded");
        assertGt(effective, blueRate, "Plumb must never bid at or below its own opportunity cost");
    }

    /// @notice Above the floor, the floor is inert — it is a floor, not a peg.
    function test_FloorDoesNotTouchARateAlreadyAboveIt() public view {
        uint256 blueRate = vault.blueSupplyRateBps();
        assertGt(RATE_BPS, blueRate + quote.blueFloorMarginBps(), "test premise: the configured rate clears the floor");
        assertEq(quote.effectiveRateBps(id), RATE_BPS, "a rate above the floor must pass through untouched");
    }

    /// @notice When Blue out-earns anything Plumb may legitimately bid, Plumb stops quoting.
    ///
    /// @dev The alternative would be to clamp at MAX_RATE_BPS and keep buying below the floor —
    ///      exactly the value destruction the floor forbids. Refusing to quote is the only honest
    ///      answer. Blue paying 35% does not happen on the fork, hence the mock.
    function test_FloorAboveTheHardMaxStopsTheQuote() public {
        vm.mockCall(address(vault), abi.encodeWithSignature("blueSupplyRateBps()"), abi.encode(uint256(3500)));

        vm.expectRevert(QuoteModule.BelowBlueFloor.selector);
        quote.effectiveRateBps(id);

        // The spacing read is hoisted: a nested external call in an argument list consumes the
        // pending `expectRevert`.
        uint8 spacing = MIDNIGHT.tickSpacing(id);
        vm.expectRevert(QuoteModule.BelowBlueFloor.selector);
        quote.maxTick(id, MATURITY, spacing);

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

        vm.prank(OWNER);
        _configure(RATE_BPS, 400, SKEW_BPS);

        assertEq(quote.effectiveRateBps(id), RATE_BPS + 400, "the spread must add to the demanded rate");
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

        vm.prank(OWNER);
        _configure(rateBps, vol, skew);

        // The book is mocked rather than filled: this property is about arithmetic, and filling
        // would bound `held` to what the cap and the NAV allow.
        vm.mockCall(
            address(vault),
            abi.encodeWithSignature("book(bytes32)", id),
            abi.encode(held, uint128(0), uint64(0), uint64(MATURITY))
        );

        uint256 effective = quote.effectiveRateBps(id);
        assertGe(effective, quote.MIN_RATE_BPS(), "the rate can never fall under the immutable floor");
        assertLe(effective, quote.MAX_RATE_BPS(), "the rate can never exceed the immutable ceiling");
        assertGe(effective, rateBps, "an adjustment can only raise the demanded rate");
    }

    /// @notice A rate configured above the adjustment bounds is refused outright.
    function test_OwnerCannotConfigureAnUnboundedAdjustment() public {
        uint16 tooMuch = uint16(quote.MAX_ADJUSTMENT_BPS() + 1);

        vm.prank(OWNER);
        vm.expectRevert(QuoteModule.AdjustmentOutOfBounds.selector);
        _configure(RATE_BPS, tooMuch, 0);

        vm.prank(OWNER);
        vm.expectRevert(QuoteModule.AdjustmentOutOfBounds.selector);
        _configure(RATE_BPS, 0, tooMuch);
    }

    /// @notice An enabled market with no cap cannot be priced, so it cannot be configured.
    function test_EnabledMarketNeedsANonZeroCap() public {
        vm.prank(OWNER);
        vm.expectRevert(QuoteModule.ZeroMaxUnits.selector);
        quote.setMarketConfig(
            id,
            QuoteModule.MarketConfig({
                enabled: true,
                rateBps: RATE_BPS,
                volSpreadBps: 0,
                skewBps: 0,
                minTenor: 1 days,
                maxTenor: 90 days,
                maxUnits: 0
            })
        );
    }

    /// @notice Without its vault, the policy refuses to quote rather than quoting unadjusted.
    /// @dev Failing closed matters here: an unskewed, unfloored quote is precisely the static bid
    ///      this whole mechanism replaces, and a half-finished deployment must not produce one.
    function test_PolicyWithoutVaultRefusesToQuote() public {
        QuoteModule fresh = new QuoteModule(OWNER);
        vm.prank(OWNER);
        fresh.setMarketConfig(
            id,
            QuoteModule.MarketConfig({
                enabled: true,
                rateBps: RATE_BPS,
                volSpreadBps: 0,
                skewBps: 0,
                minTenor: 1 days,
                maxTenor: 90 days,
                maxUnits: MARKET_CAP
            })
        );

        uint8 spacing = MIDNIGHT.tickSpacing(id);
        vm.expectRevert(QuoteModule.VaultNotSet.selector);
        fresh.maxTick(id, MATURITY, spacing);
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
    // 5. What it costs
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
