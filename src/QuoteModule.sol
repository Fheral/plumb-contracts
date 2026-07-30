// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TickLib, MAX_TICK} from "./interfaces/midnight/TickLib.sol";
import {Market, CollateralParams} from "./interfaces/midnight/IMidnight.sol";
import {IdLib} from "./interfaces/midnight/IdLib.sol";

/// @notice The vault state `QuoteModule` prices against.
/// @dev Deliberately narrow: the quoting policy reads Plumb's own book and Plumb's own opportunity
///      cost, nothing else. Declared as an interface rather than importing the vault to keep the
///      dependency one-way at the type level.
interface IQuoteContext {
    function book(bytes32 id) external view returns (uint128 units, uint128 value, uint64 lastMark, uint64 maturity);
    function blueSupplyRateBps() external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

/// @notice Plumb's quoting policy.
///
/// Converts a target annualized rate into a Midnight tick. This is the only place a price is
/// decided: neither the operator nor the bot can choose a tick, they can only observe this one.
///
/// ## Eligibility is derived, not declared
///
/// Midnight mints **one market per maturity**. An allowlist keyed by market id is therefore a
/// treadmill: every new maturity of the same collateral pair is another id to approve by hand, for
/// a risk that is byte-for-byte identical. Worse, the treadmill is what actually gets skipped —
/// which is how Plumb ended up quoting a market with 10 USDC of lifetime volume while its twin,
/// same collateral and same oracles, carried 215k.
///
/// So eligibility is not stored per market. It is *read off the descriptor*, which Midnight makes
/// fully self-describing: loan token, collateral set with their LLTVs and oracles, maturity, and
/// the two permission gates. A market is quotable when every one of its collaterals is allowed,
/// none exceeds its LLTV ceiling, neither gate is set, and the tenor is in range.
///
/// The owner therefore approves **collateral, not markets** — a list that moves once a quarter
/// instead of once a maturity. New maturities of an approved pair are quotable the moment Midnight
/// creates them, with no transaction at all.
///
/// This does not widen what a compromised bot key can do. The bot never selects anything: it
/// broadcasts what `buildBid` produces, and `isRatified` re-derives this policy at take time. The
/// gate simply moved from a stored boolean to a function of the descriptor — and the descriptor
/// cannot be forged, since `IdLib.toId` makes the market id the hash of the struct itself.
///
/// ## The rate quoted is not the configured one
///
/// Three adjustments apply, in this order:
///
///  1. **Collateral spread** — the premium of the *worst* collateral in the market's basket. A lot
///     backed by cbBTC and a lot backed by an RWA do not carry the same default risk; a single
///     target rate would price them alike, which is wrong in both directions. A basket is only as
///     good as the weakest thing that can be posted against it, hence the max rather than a mean.
///  2. **Inventory skew** — the bid steps back as the market fills up. A cap alone says
///     "yes, yes, yes, NO"; the skew says "yes, a little worse, distinctly worse". Self-limitation
///     becomes progressive, and the seller pays for the concentration instead of the depositors
///     wearing it.
///  3. **Blue floor** — the rate can never fall below what the idle sleeve already earns on Morpho
///     Blue, plus a margin. Buying a lot at 6% while Blue pays 7% destroys value; this makes that
///     mistake structurally impossible rather than merely visible after the fact.
///
/// The target rate is hard-bounded by immutable constants. A compromised owner can therefore
/// neither dump the book (rate > MAX) nor overpay for positions (rate < MIN). The adjustments
/// preserve both bounds by construction: they are *additive and non-negative*, so they can only
/// move the rate up — away from MIN, never past MAX, which is clamped.
contract QuoteModule is Ownable2Step {
    /// @dev Immutable bounds on the annualized bid rate, in basis points.
    uint256 public constant MIN_RATE_BPS = 500; // 5%  — below this, Plumb does not take the duration risk
    uint256 public constant MAX_RATE_BPS = 3000; // 30% — above this, the counterparty is being fleeced
    uint256 public constant MAX_TENOR = 90 days;
    /// @dev Upper bound on each adjustment. Not a risk limit — the MAX clamp is — but a guard
    ///      against a fat-fingered config that would silently pin every market at MAX_RATE_BPS.
    uint256 public constant MAX_ADJUSTMENT_BPS = 2000;
    uint256 internal constant WAD = 1e18;

    /// @notice What Plumb accepts to take as collateral, and at what premium.
    /// @dev Keyed by token, not by market: this is the unit at which collateral risk actually
    ///      exists. `maxLltv` is the ceiling on how much a borrower may draw against it — a higher
    ///      LLTV is a thinner equity buffer, hence a market Plumb may want to refuse even on
    ///      collateral it otherwise accepts.
    struct CollateralPolicy {
        bool allowed;
        uint16 volSpreadBps; // risk premium for this collateral, added flat
        uint64 maxLltv; // WAD. Above this, the market is refused whatever the premium
    }

    /// @notice The part of the policy that does not depend on the market.
    /// @dev `maxUnitsBps` is a fraction of NAV rather than an absolute: it is the only way a
    ///      per-market cap can exist without a per-market number to maintain, and it keeps the skew
    ///      meaningful as the vault grows. An absolute cap sized for a vault in regime makes the
    ///      skew inert on a small vault — at 25,000 USDC of cap on a 214 USDC vault, the skew
    ///      saturates at 1.2 bps and the mechanism may as well not exist.
    struct BasePolicy {
        uint16 rateBps; // base target annualized rate
        uint16 skewBps; // added in full when a market is at its unit cap, pro rata below
        uint32 minTenor; // below this, the gain covers neither gas nor settlement risk
        uint32 maxTenor; // above this, we refuse to carry the duration
        uint16 maxUnitsBps; // per-market unit cap, in bps of NAV
    }

    BasePolicy internal _base;

    mapping(address token => CollateralPolicy) internal _collateral;

    /// @notice Markets the owner refuses regardless of their descriptor.
    /// @dev The escape hatch, and deliberately the only per-market switch left. Eligibility is
    ///      derived, so there has to be a way to say "not this one" about a market that passes
    ///      every structural check and is still known to be bad. It can only ever *remove*, never
    ///      add: blocking is safe in a way that enabling is not.
    mapping(bytes32 id => bool) public blocked;

    /// @notice The vault whose book and opportunity cost this policy prices against.
    IQuoteContext public vault;

    /// @notice Margin required above Blue's supply rate, in basis points.
    /// @dev Applies to every market: it prices Plumb's own illiquidity, not the collateral's risk.
    uint256 public blueFloorMarginBps = 200;

    /// @notice Highest Midnight continuous fee Plumb agrees to pay, in Midnight's own units.
    ///
    /// @dev Every offer carries this value as its `continuousFeeCap`, and Midnight refuses the
    ///      `take` if the market's fee exceeds it. The fee is Midnight governance's to set, at any
    ///      time, on live offers Plumb has already broadcast — so this is the only place Plumb gets
    ///      to say how much of the depositors' yield it accepts to hand over.
    ///
    ///      The exposure is bounded by Midnight itself: `ConstantsLib.MAX_CONTINUOUS_FEE` is an
    ///      immutable 1% a year, checked in both `setMarketContinuousFee` and
    ///      `setDefaultContinuousFee`, i.e. at most 24.66 bps of a lot over Plumb's 90-day maximum
    ///      tenor. So the question this cap answers is not "how much could we lose" — that is
    ///      known — but "do we accept to pay it before having measured it".
    ///
    ///      The default is **zero**, and the answer is no: the fee is zero on every Base market
    ///      today, and `feeSetter` is `address(0)`, so no one can currently set one at all. Zero
    ///      means the day that changes, Plumb's takes revert instead of quietly paying — an outage
    ///      the owner resolves by pricing the fee in and raising this cap, which is a decision, not
    ///      an accident.
    ///
    ///      **Raising it requires `PlumbVault._redeemable` to already be in place**: a nonzero fee
    ///      is the only thing that gives a lot a `pendingFee`, and marking against `credit` alone
    ///      would then overstate the book. The two changes belong together.
    ///
    ///      Denominated in raw Midnight units, because that is what the offer field is compared
    ///      against.
    uint256 public continuousFeeCap;

    /// @notice The most this cap can be set to: Midnight's own `MAX_CONTINUOUS_FEE`.
    /// @dev `uint32(uint256(0.01e18) / uint256(365 days))`. A cap above this could not change any
    ///      outcome — Midnight rejects such a fee at the setter — so allowing it would only let the
    ///      owner write a number that reads like a policy and is not one.
    uint256 public constant MAX_CONTINUOUS_FEE_CAP = 317_097_919;

    event SetBasePolicy(BasePolicy policy);
    event SetCollateralPolicy(address indexed token, CollateralPolicy policy);
    event SetBlocked(bytes32 indexed id, bool blocked);
    event SetVault(address indexed vault);
    event SetBlueFloorMargin(uint256 marginBps);
    event SetContinuousFeeCap(uint256 cap);

    error RateOutOfBounds();
    error TenorOutOfBounds();
    error InvalidTenorRange();
    error InvalidSpacing();
    error NoAcceptableTick();
    error AdjustmentOutOfBounds();
    error ZeroUnitCap();
    error VaultNotSet();
    error BelowBlueFloor();
    error ZeroAddress();
    error FeeCapOutOfBounds();
    error MarketBlocked();
    error MarketPermissioned();
    error NoCollateral();
    error CollateralNotAllowed();
    error LltvTooHigh();

    constructor(address owner_) Ownable(owner_) {}

    // -------------------------------------------------------------------------
    // Policy
    // -------------------------------------------------------------------------

    function basePolicy() external view returns (BasePolicy memory) {
        return _base;
    }

    function collateralPolicy(address token) external view returns (CollateralPolicy memory) {
        return _collateral[token];
    }

    function setBasePolicy(BasePolicy calldata p) external onlyOwner {
        require(p.rateBps >= MIN_RATE_BPS && p.rateBps <= MAX_RATE_BPS, RateOutOfBounds());
        require(p.skewBps <= MAX_ADJUSTMENT_BPS, AdjustmentOutOfBounds());
        require(p.minTenor > 0 && p.minTenor < p.maxTenor, InvalidTenorRange());
        require(p.maxTenor <= MAX_TENOR, TenorOutOfBounds());
        // The skew divides by the unit cap: a zero cap could not be priced, and would also mean a
        // policy that accepts markets it can never fill.
        require(p.maxUnitsBps > 0 && p.maxUnitsBps <= 10_000, ZeroUnitCap());
        _base = p;
        emit SetBasePolicy(p);
    }

    /// @notice Approves — or withdraws approval from — a collateral token.
    /// @dev This is the whole of the market-selection surface. Approving a token makes every
    ///      present and future Midnight market built on it quotable, at any maturity, with no
    ///      further transaction.
    function setCollateralPolicy(address token, CollateralPolicy calldata p) external onlyOwner {
        require(token != address(0), ZeroAddress());
        if (p.allowed) {
            require(p.volSpreadBps <= MAX_ADJUSTMENT_BPS, AdjustmentOutOfBounds());
            require(p.maxLltv > 0 && p.maxLltv <= WAD, LltvTooHigh());
        }
        _collateral[token] = p;
        emit SetCollateralPolicy(token, p);
    }

    /// @notice Refuses a specific market whatever its descriptor says.
    function setBlocked(bytes32 id, bool value) external onlyOwner {
        blocked[id] = value;
        emit SetBlocked(id, value);
    }

    /// @notice Points the policy at its vault. Set once, right after deployment.
    /// @dev The vault takes the module's address in its constructor, so the link can only be closed
    ///      from this side. Until it is, `maxTick` reverts rather than quoting an unskewed,
    ///      unfloored price — failing closed is the whole point of the module.
    function setVault(address newVault) external onlyOwner {
        require(newVault != address(0), ZeroAddress());
        vault = IQuoteContext(newVault);
        emit SetVault(newVault);
    }

    function setBlueFloorMargin(uint256 marginBps) external onlyOwner {
        require(marginBps <= MAX_ADJUSTMENT_BPS, AdjustmentOutOfBounds());
        blueFloorMarginBps = marginBps;
        emit SetBlueFloorMargin(marginBps);
    }

    /// @notice Sets the highest Midnight continuous fee Plumb agrees to pay. See `continuousFeeCap`.
    /// @dev Raising this is an economic decision — it hands part of the depositors' yield to
    ///      Midnight governance — hence `onlyOwner`, i.e. the multisig, never the bot.
    function setContinuousFeeCap(uint256 cap) external onlyOwner {
        require(cap <= MAX_CONTINUOUS_FEE_CAP, FeeCapOutOfBounds());
        continuousFeeCap = cap;
        emit SetContinuousFeeCap(cap);
    }

    // -------------------------------------------------------------------------
    // Eligibility
    // -------------------------------------------------------------------------

    /// @notice Reverts unless this market is one Plumb accepts to price at all.
    /// @dev Every check reads the descriptor, and the descriptor cannot lie: the caller's `id` is
    ///      `IdLib.toId(market)`, so a market struct and its id are the same fact stated twice.
    ///
    ///      Gates are refused outright rather than priced. A permissioned market is one where a
    ///      third party can decide whether Plumb may enter, or whether anyone may liquidate the
    ///      borrower who backs Plumb's lot — neither is a risk a spread can express, because both
    ///      are exercised *after* the position is taken and there is no price at which being
    ///      unable to exit is acceptable.
    function requireEligible(Market memory market) public view {
        bytes32 id = IdLib.toId(market);
        require(!blocked[id], MarketBlocked());
        require(market.enterGate == address(0) && market.liquidatorGate == address(0), MarketPermissioned());

        uint256 n = market.collateralParams.length;
        require(n > 0, NoCollateral());
        for (uint256 i = 0; i < n; ++i) {
            CollateralPolicy memory cp = _collateral[market.collateralParams[i].token];
            require(cp.allowed, CollateralNotAllowed());
            require(market.collateralParams[i].lltv <= cp.maxLltv, LltvTooHigh());
        }
    }

    /// @notice The collateral premium this market carries: the worst of its basket.
    /// @dev Assumes `requireEligible` has passed, i.e. every collateral is allowed.
    function volSpreadBps(Market memory market) public view returns (uint256 worst) {
        uint256 n = market.collateralParams.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 s = _collateral[market.collateralParams[i].token].volSpreadBps;
            if (s > worst) worst = s;
        }
    }

    /// @notice Cap on the units Plumb holds on any single market, given a NAV.
    ///
    /// @dev Takes the NAV as an argument rather than reading it, because the two callers disagree
    ///      on what the NAV *is* and both are right. Outside a fill, it is `totalAssets()`. Inside
    ///      `onBuy` the buyer's assets are still in the vault — Midnight collects them when the
    ///      callback returns — so the caller must net them out first, exactly as it already does
    ///      for the book cap. Reading `totalAssets()` here would silently use the inflated one.
    ///
    ///      Units are compared against a cap derived from assets. At a price below par a unit costs
    ///      less than an asset, so this is marginally permissive in unit terms; the binding
    ///      constraint on capital is the vault's own book cap, in assets, which is not.
    function marketUnitCap(uint256 nav) public view returns (uint256) {
        return (nav * _base.maxUnitsBps) / 10_000;
    }

    // -------------------------------------------------------------------------
    // Pricing
    // -------------------------------------------------------------------------

    /// @notice The annualized rate Plumb actually demands on this market at this instant, in bps.
    /// @dev Exposed on its own because it is the number a human reads to understand a quote — the
    ///      tick only says what it costs, not why.
    function effectiveRateBps(Market memory market) public view returns (uint256) {
        require(address(vault) != address(0), VaultNotSet());
        requireEligible(market);

        uint256 cap = marketUnitCap(vault.totalAssets());
        (uint128 held,,,) = vault.book(IdLib.toId(market));
        uint256 skew;
        if (cap > 0) {
            // Held units above the cap are possible without anyone acting, since the cap follows
            // the NAV: a drawdown shrinks it under a book that has not moved. The skew saturates
            // rather than overshooting, and the cap in `onBuy` refuses the fill anyway.
            uint256 heldForSkew = held > cap ? cap : held;
            skew = (uint256(_base.skewBps) * heldForSkew) / cap;
        } else if (held > 0) {
            // A cap of zero means a NAV of zero, and units held against it. That is the saturated
            // case taken to its limit, not a division to perform.
            skew = _base.skewBps;
        }
        // Nothing held and no NAV: the skew prices inventory, and there is none. Leaving it at zero
        // matters — an empty vault must quote its base rate, not the top of its band.

        uint256 rate = uint256(_base.rateBps) + volSpreadBps(market) + skew;
        if (rate > MAX_RATE_BPS) rate = MAX_RATE_BPS;

        uint256 floorRate = vault.blueSupplyRateBps() + blueFloorMarginBps;
        if (rate < floorRate) {
            // Demanding more than MAX_RATE_BPS is not something this policy will do — that bound is
            // the counterparty's protection. So when the idle sleeve out-earns anything Plumb may
            // legitimately bid, Plumb does not bid at all.
            require(floorRate <= MAX_RATE_BPS, BelowBlueFloor());
            rate = floorRate;
        }
        return rate;
    }

    /// @notice Highest tick (hence highest price) Plumb accepts to pay at this instant.
    /// @dev The target price is the linear discounting of par at the effective rate. Tick rounding
    ///      is always downward: Plumb will never pay more than its target price, even if that means
    ///      quoting a notch too low and missing the trade.
    function maxTick(Market memory market, uint8 spacing) public view returns (uint256) {
        require(spacing > 0 && MAX_TICK % spacing == 0, InvalidSpacing());

        uint256 remaining = market.maturity > block.timestamp ? market.maturity - block.timestamp : 0;
        require(remaining >= _base.minTenor && remaining <= _base.maxTenor, TenorOutOfBounds());

        uint256 discount = (effectiveRateBps(market) * WAD * remaining) / (10_000 * 365 days);
        uint256 targetPrice = WAD - discount; // discount < WAD as long as rate <= 3000 and remaining <= 90d

        uint256 tick = TickLib.priceToTick(targetPrice, spacing);
        // priceToTick rounds up (price >= target). Step down one notch to stay under the target.
        if (TickLib.tickToPrice(tick) > targetPrice) {
            require(tick >= spacing, NoAcceptableTick());
            tick -= spacing;
        }
        return tick;
    }

    /// @notice Unit price (WAD) actually paid at the quoted tick. Useful to offchain monitoring.
    function maxPrice(Market memory market, uint8 spacing) external view returns (uint256) {
        return TickLib.tickToPrice(maxTick(market, spacing));
    }
}
