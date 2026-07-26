// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {TickLib, MAX_TICK} from "./interfaces/midnight/TickLib.sol";

/// @notice Plumb's quoting policy.
///
/// Converts a target annualized rate into a Midnight tick. This is the only place a price is
/// decided: neither the operator nor the bot can choose a tick, they can only observe this one.
///
/// The target rate is hard-bounded by immutable constants. A compromised owner can therefore
/// neither dump the book (rate > MAX) nor overpay for positions (rate < MIN).
contract QuoteModule is Ownable2Step {
    /// @dev Immutable bounds on the annualized bid rate, in basis points.
    uint256 public constant MIN_RATE_BPS = 500; // 5%  — below this, Plumb does not take the duration risk
    uint256 public constant MAX_RATE_BPS = 3000; // 30% — above this, the counterparty is being fleeced
    uint256 public constant MAX_TENOR = 90 days;
    uint256 internal constant WAD = 1e18;

    struct MarketConfig {
        bool enabled;
        uint16 rateBps; // target annualized rate for this market
        uint32 minTenor; // below this, the gain covers neither gas nor settlement risk
        uint32 maxTenor; // above this, we refuse to carry the duration
        uint128 maxUnits; // cap on units held on this market
    }

    mapping(bytes32 id => MarketConfig) internal _config;

    event SetMarketConfig(bytes32 indexed id, MarketConfig config);

    error MarketDisabled();
    error RateOutOfBounds();
    error TenorOutOfBounds();
    error InvalidTenorRange();
    error InvalidSpacing();
    error NoAcceptableTick();

    constructor(address owner_) Ownable(owner_) {}

    function config(bytes32 id) external view returns (MarketConfig memory) {
        return _config[id];
    }

    function setMarketConfig(bytes32 id, MarketConfig calldata c) external onlyOwner {
        if (c.enabled) {
            require(c.rateBps >= MIN_RATE_BPS && c.rateBps <= MAX_RATE_BPS, RateOutOfBounds());
            require(c.minTenor > 0 && c.minTenor < c.maxTenor, InvalidTenorRange());
            require(c.maxTenor <= MAX_TENOR, TenorOutOfBounds());
        }
        _config[id] = c;
        emit SetMarketConfig(id, c);
    }

    /// @notice Highest tick (hence highest price) Plumb accepts to pay at this instant.
    /// @dev The target price is the linear discounting of par at the target rate. Tick rounding is
    ///      always downward: Plumb will never pay more than its target price, even if that means
    ///      quoting a notch too low and missing the trade.
    function maxTick(bytes32 id, uint256 maturity, uint8 spacing) public view returns (uint256) {
        MarketConfig memory c = _config[id];
        require(c.enabled, MarketDisabled());
        require(spacing > 0 && MAX_TICK % spacing == 0, InvalidSpacing());

        uint256 remaining = maturity > block.timestamp ? maturity - block.timestamp : 0;
        require(remaining >= c.minTenor && remaining <= c.maxTenor, TenorOutOfBounds());

        uint256 discount = (uint256(c.rateBps) * WAD * remaining) / (10_000 * 365 days);
        uint256 targetPrice = WAD - discount; // discount < WAD as long as rateBps <= 3000 and remaining <= 90d

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
