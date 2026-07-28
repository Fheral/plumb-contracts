// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TickLib, MAX_TICK} from "./interfaces/midnight/TickLib.sol";

/// @notice The vault state `QuoteModule` prices against.
/// @dev Deliberately narrow: the quoting policy reads Plumb's own book and Plumb's own opportunity
///      cost, nothing else. Declared as an interface rather than importing the vault to keep the
///      dependency one-way at the type level.
interface IQuoteContext {
    function book(bytes32 id) external view returns (uint128 units, uint128 value, uint64 lastMark, uint64 maturity);
    function blueSupplyRateBps() external view returns (uint256);
}

/// @notice Plumb's quoting policy.
///
/// Converts a target annualized rate into a Midnight tick. This is the only place a price is
/// decided: neither the operator nor the bot can choose a tick, they can only observe this one.
///
/// The rate quoted is not the configured one. Three adjustments apply, in this order:
///
///  1. **Collateral spread** — a flat premium per market. A lot backed by cbBTC and a lot backed by
///     an RWA do not carry the same default risk; a single target rate would price them alike,
///     which is wrong in both directions.
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

    struct MarketConfig {
        bool enabled;
        uint16 rateBps; // base target annualized rate for this market
        uint16 volSpreadBps; // collateral risk premium, added flat
        uint16 skewBps; // added in full when the market is at `maxUnits`, pro rata below
        uint32 minTenor; // below this, the gain covers neither gas nor settlement risk
        uint32 maxTenor; // above this, we refuse to carry the duration
        uint128 maxUnits; // cap on units held on this market
    }

    mapping(bytes32 id => MarketConfig) internal _config;

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

    event SetMarketConfig(bytes32 indexed id, MarketConfig config);
    event SetVault(address indexed vault);
    event SetBlueFloorMargin(uint256 marginBps);
    event SetContinuousFeeCap(uint256 cap);

    error MarketDisabled();
    error RateOutOfBounds();
    error TenorOutOfBounds();
    error InvalidTenorRange();
    error InvalidSpacing();
    error NoAcceptableTick();
    error AdjustmentOutOfBounds();
    error ZeroMaxUnits();
    error VaultNotSet();
    error BelowBlueFloor();
    error ZeroAddress();
    error FeeCapOutOfBounds();

    constructor(address owner_) Ownable(owner_) {}

    function config(bytes32 id) external view returns (MarketConfig memory) {
        return _config[id];
    }

    function setMarketConfig(bytes32 id, MarketConfig calldata c) external onlyOwner {
        if (c.enabled) {
            require(c.rateBps >= MIN_RATE_BPS && c.rateBps <= MAX_RATE_BPS, RateOutOfBounds());
            require(c.volSpreadBps <= MAX_ADJUSTMENT_BPS && c.skewBps <= MAX_ADJUSTMENT_BPS, AdjustmentOutOfBounds());
            require(c.minTenor > 0 && c.minTenor < c.maxTenor, InvalidTenorRange());
            require(c.maxTenor <= MAX_TENOR, TenorOutOfBounds());
            // The skew divides by `maxUnits`: a market enabled with a zero cap could not be priced.
            require(c.maxUnits > 0, ZeroMaxUnits());
        }
        _config[id] = c;
        emit SetMarketConfig(id, c);
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

    /// @notice The annualized rate Plumb actually demands on this market at this instant, in bps.
    /// @dev Exposed on its own because it is the number a human reads to understand a quote — the
    ///      tick only says what it costs, not why.
    function effectiveRateBps(bytes32 id) public view returns (uint256) {
        MarketConfig memory c = _config[id];
        require(c.enabled, MarketDisabled());
        require(address(vault) != address(0), VaultNotSet());

        (uint128 held,,,) = vault.book(id);
        // Held units above the cap are possible after the owner lowers it: the skew saturates
        // rather than overshooting, and the cap in `onBuy` refuses the fill anyway.
        uint256 heldForSkew = held > c.maxUnits ? c.maxUnits : held;
        uint256 skew = (uint256(c.skewBps) * heldForSkew) / c.maxUnits;

        uint256 rate = uint256(c.rateBps) + c.volSpreadBps + skew;
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
    function maxTick(bytes32 id, uint256 maturity, uint8 spacing) public view returns (uint256) {
        MarketConfig memory c = _config[id];
        require(c.enabled, MarketDisabled());
        require(spacing > 0 && MAX_TICK % spacing == 0, InvalidSpacing());

        uint256 remaining = maturity > block.timestamp ? maturity - block.timestamp : 0;
        require(remaining >= c.minTenor && remaining <= c.maxTenor, TenorOutOfBounds());

        uint256 discount = (effectiveRateBps(id) * WAD * remaining) / (10_000 * 365 days);
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
    function maxPrice(bytes32 id, uint256 maturity, uint8 spacing) external view returns (uint256) {
        return TickLib.tickToPrice(maxTick(id, maturity, spacing));
    }
}
