// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626, IERC20, Math} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IMidnight, Market, Offer} from "./interfaces/midnight/IMidnight.sol";
import {IBuyCallback} from "./interfaces/midnight/ICallbacks.sol";
import {IRatifier} from "./interfaces/midnight/IRatifier.sol";
import {IdLib} from "./interfaces/midnight/IdLib.sol";
import {TickLib} from "./interfaces/midnight/TickLib.sol";
import {QuoteModule} from "./QuoteModule.sol";
import {IMorphoBlue, BlueMarketParams, BlueLib} from "./interfaces/IMorphoBlue.sol";

/// @title PlumbVault
/// @notice ERC-4626 vault holding the standing bid on the Morpho Midnight order book.
///
/// Plumb does not seek out sellers: it posts resting buy offers. A lender who wants out before
/// maturity takes the bid, hands over their credit units, and Plumb carries them to maturity where
/// they are worth par. The spread is the depositors' yield.
///
/// Three things hold the design together:
///
///  1. The vault is its own `ratifier`. An offer is only valid if `isRatified` recognizes it, and
///     `isRatified` checks it against the on-chain policy (QuoteModule + caps). No signature enters
///     the validation: the bot merely broadcasts structs, it does not authorize them. A compromised
///     bot key therefore cannot quote anything the policy would not have quoted.
///
///  2. The vault is its own `buyCallback`. At the instant of the `take`, Midnight calls it: the
///     vault withdraws from Morpho Blue exactly what it must pay, records the lot, and checks the
///     book cap. This is the only moment capital leaves Blue.
///
///  3. Midnight's `group` budget caps the cumulative exposure of all live offers. `kill()`
///     exhausts it in one transaction: every offer dies at once.
///
/// Every function that writes the book is `nonReentrant`. No known path re-enters today — neither
/// Midnight nor Blue calls back into the vault on these calls — but Plumb exposes a callback
/// (`onBuy`) invoked by a third-party contract in the middle of a transaction it did not initiate.
/// That is exactly the shape where a future reentrancy would be costly, and the lock is cheap.
contract PlumbVault is ERC4626, Ownable2Step, Pausable, ReentrancyGuard, IBuyCallback, IRatifier {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using Math for uint256;
    using BlueLib for IMorphoBlue;

    bytes32 internal constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_MARKETS = 8;
    uint256 public constant MAX_PERF_FEE_BPS = 2000;
    /// @notice Release period for a gain recognized ahead of schedule. See `lockedProfit()`.
    uint256 public constant PROFIT_UNLOCK = 7 days;

    IMidnight public immutable MIDNIGHT;
    IMorphoBlue public immutable BLUE;
    QuoteModule public immutable QUOTE;

    /// @notice Plumb's credit position on a Midnight market.
    /// @dev `units` is the notional held (1 unit = 1 asset at maturity), `value` its marked value,
    ///      which accretes linearly toward `units` from the purchase price. No oracle: the yield is
    ///      fixed at purchase.
    struct Book {
        uint128 units;
        uint128 value;
        uint64 lastMark;
        uint64 maturity;
    }

    mapping(bytes32 id => Book) public book;
    EnumerableSet.Bytes32Set internal _activeMarkets;

    // --- Risk parameters ---

    /// @notice Maximum share of NAV that may be tied up in unmatured credit.
    /// @dev This is the hard book cap: the rest must stay mobilizable for depositor withdrawals.
    uint256 public maxBookBps = 6000;
    /// @notice Cap on units purchasable in a single `take`.
    uint128 public maxSingleFill;
    /// @notice Performance fee on share-price outperformance, in basis points.
    uint256 public perfFeeBps = 1500;
    address public feeRecipient;
    /// @notice All-time high of the share price, in assets per 1e18 shares.
    uint256 public highWaterMark = WAD;

    /// @dev Gain recognized at the last `_lockProfit`, and the instant it was. The still-locked
    ///      portion decays linearly from that instant.
    uint256 internal _lockedProfit;
    uint64 public lockedProfitAt;

    address public operator;
    BlueMarketParams public blueMarket;
    bool public blueMarketSet;

    /// @notice Offer-budget epoch. Midnight's `consumed` counter is monotonic: to reclaim budget
    ///         you must change `group`, hence change epoch.
    uint96 public epoch;
    /// @notice Unit budget of the current epoch — the exact `maxUnits` value required on offers.
    uint128 public epochBudget;

    event SetOperator(address indexed operator);
    event SetRiskParams(uint256 maxBookBps, uint128 maxSingleFill);
    event SetFee(uint256 perfFeeBps, address indexed recipient);
    event SetBlueMarket(address collateralToken, address oracle, address irm, uint256 lltv);
    event OpenEpoch(uint96 indexed epoch, bytes32 group, uint128 budget);
    event Killed(bytes32 group);
    event Bought(bytes32 indexed id, uint256 units, uint256 assets);
    event Settled(bytes32 indexed id, uint256 units, uint256 assets);
    event Marked(bytes32 indexed id, uint128 units, uint128 value);
    event AccrueFee(uint256 shares, uint256 newHighWaterMark);
    event ProfitLocked(uint256 gain, uint256 totalLocked);

    error NotOperator();
    error NotMidnight();
    error NotSelf();
    error BlueMarketNotSet();
    error WrongLoanToken();
    error TooManyMarkets();
    error BookCapExceeded();
    error FillTooLarge();
    error FeeTooHigh();
    error ZeroAddress();
    error NothingToSettle();
    // --- ratification rejections ---
    error OfferNotABid();
    error OfferWrongMaker();
    error OfferWrongRatifier();
    error OfferWrongCallback();
    error OfferWrongGroup();
    error OfferWrongBudget();
    error OfferWrongMarket();
    error OfferReduceOnly();
    error OfferReceiverNotZero();
    error OfferTickTooHigh();
    error OfferFeeCapTooHigh();

    modifier onlyOperator() {
        require(msg.sender == operator || msg.sender == owner(), NotOperator());
        _;
    }

    /// @dev One vault per loan asset, mirroring Midnight's own market structure. Nothing below
    ///      assumes a specific token or decimal count: accounting is in the asset's raw units, and
    ///      every market is checked against `asset()`. The share name and symbol are the only
    ///      asset-specific values, so they are deployment parameters (e.g. "Plumb Exit Liquidity
    ///      USDC" / "plUSDC").
    constructor(
        string memory name_,
        string memory symbol_,
        address asset_,
        address midnight_,
        address blue_,
        address quote_,
        address owner_,
        address feeRecipient_
    ) ERC20(name_, symbol_) ERC4626(IERC20(asset_)) Ownable(owner_) {
        require(feeRecipient_ != address(0), ZeroAddress());
        MIDNIGHT = IMidnight(midnight_);
        BLUE = IMorphoBlue(blue_);
        QUOTE = QuoteModule(quote_);
        feeRecipient = feeRecipient_;

        // The vault is its own ratifier: Midnight requires the maker to have authorized its ratifier.
        MIDNIGHT.setIsAuthorized(address(this), true, address(this));
        IERC20(asset_).forceApprove(midnight_, type(uint256).max);
        IERC20(asset_).forceApprove(blue_, type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // Accounting
    // -------------------------------------------------------------------------

    /// @notice NAV = idle cash + Blue position + marked book value — minus the still-locked gain.
    function totalAssets() public view override returns (uint256) {
        uint256 liquid = idleAssets() + blueAssets();
        uint256 locked = lockedProfit();
        // The locked gain can only be deferred against *liquid* value actually present. Without
        // this ceiling, book accretion pushes the NAV up, depositors withdraw against it, and the
        // liquid sleeve ends up below the locked amount: the NAV would then fall below the book's
        // value, which makes no accounting sense and tightens the cap for no reason. Found by the
        // stateful campaign, not by reasoning.
        //
        // The ceiling does not weaken the defense: an early settlement has, precisely, just
        // returned cash to Blue, so the liquid sleeve is at its maximum at the instant the gain is
        // locked. And where there is no liquid value left, there is nothing left to capture.
        if (locked > liquid) locked = liquid;
        return liquid + bookValue() - locked;
    }

    /// @notice Portion of a gain recognized ahead of schedule that is not yet reflected in the NAV.
    ///
    /// @dev Without this mechanism, an early settlement makes the NAV jump from one block to the
    ///      next: the repaid units come back at par while the book carried them only at their
    ///      discounted value. The lot's entire residual carry is then recognized at once, and
    ///      anyone can capture it in a single transaction — deposit massive capital just before,
    ///      call `settle`, exit just after. Tested and measured: without the lock, 395 USDC
    ///      extracted from incumbent depositors with a 2M flash loan against a 100k lot.
    ///
    ///      The gain is therefore released linearly over `PROFIT_UNLOCK`. It remains fully owed to
    ///      depositors — only the *instant* of recognition changes. Capturing anything would
    ///      require staying exposed for days, i.e. being an ordinary depositor who carries the
    ///      book's risk. The arbitrage disappears.
    ///
    ///      A settlement at maturity locks nothing: the marked value is already at par there, the
    ///      gain is zero by construction. The lock only bites on the early path, which is the only
    ///      discontinuous one.
    function lockedProfit() public view returns (uint256) {
        uint256 elapsed = block.timestamp - lockedProfitAt;
        if (elapsed >= PROFIT_UNLOCK) return 0;
        return (_lockedProfit * (PROFIT_UNLOCK - elapsed)) / PROFIT_UNLOCK;
    }

    /// @dev Adds a gain to the lock, starting over from whatever was still locked.
    function _lockProfit(uint256 gain) internal {
        if (gain == 0) return;
        _lockedProfit = lockedProfit() + gain;
        lockedProfitAt = uint64(block.timestamp);
        emit ProfitLocked(gain, _lockedProfit);
    }

    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function blueAssets() public view returns (uint256) {
        if (!blueMarketSet) return 0;
        return BLUE.expectedSupplyAssets(blueMarket, address(this));
    }

    /// @notice What the idle sleeve earns on Blue, annualized, in basis points.
    /// @dev Read by `QuoteModule` as the floor on the bid rate: capital that sits on Blue already
    ///      earns this, so a lot bought below it is a loss dressed up as a trade. Zero with no Blue
    ///      market set — there is no opportunity cost to beat when the sleeve earns nothing.
    function blueSupplyRateBps() public view returns (uint256) {
        if (!blueMarketSet) return 0;
        return BLUE.supplyRateBps(blueMarket);
    }

    /// @notice Sum of marked values, projected to the current instant without writing state.
    function bookValue() public view returns (uint256 total) {
        uint256 n = _activeMarkets.length();
        for (uint256 i; i < n; ++i) {
            total += previewMark(_activeMarkets.at(i));
        }
    }

    /// @notice Book value of a market at the current instant, losses included.
    function previewMark(bytes32 id) public view returns (uint256) {
        Book memory b = book[id];
        if (b.units == 0) return 0;

        (uint128 credit,,) = MIDNIGHT.updatePositionView(MIDNIGHT.toMarket(id), id, address(this));
        uint256 units = b.units;
        uint256 value = b.value;
        // Slashing: the credit may have melted. The loss is taken pro rata, immediately.
        if (credit < units) {
            value = (value * credit) / units;
            units = credit;
        }
        if (block.timestamp >= b.maturity) return units;
        // Linear accretion from purchase price to par, over the time left since the last mark.
        return value + ((units - value) * (block.timestamp - b.lastMark)) / (b.maturity - b.lastMark);
    }

    /// @dev Writes the mark. Calls `updatePosition` to materialize slashing and continuous fees.
    function _mark(bytes32 id, Market memory market) internal returns (Book storage b) {
        b = book[id];
        if (b.units == 0) return b;

        (uint128 credit,,) = MIDNIGHT.updatePosition(market, address(this));
        if (credit < b.units) {
            b.value = uint128((uint256(b.value) * credit) / b.units);
            b.units = credit;
        }
        if (b.units == 0) {
            // A fully wiped market — total socialized loss — must free its slot. `settle` cannot
            // clean up after it: it requires `units > 0`. Without this exit, the market would
            // occupy one of the 8 slots forever and `bookValue()` would keep paying an external
            // call per deposit and per withdrawal for a null position.
            _activeMarkets.remove(id);
            delete book[id];
            emit Marked(id, 0, 0);
            return b;
        } else if (block.timestamp >= b.maturity) {
            b.value = b.units;
        } else if (block.timestamp > b.lastMark) {
            b.value += uint128(
                ((uint256(b.units) - b.value) * (block.timestamp - b.lastMark)) / (b.maturity - b.lastMark)
            );
        }
        b.lastMark = uint64(block.timestamp);
        emit Marked(id, b.units, b.value);
    }

    /// @notice Refreshes a market's mark. Permissionless: marking can only tell the truth.
    function mark(Market memory market) external nonReentrant {
        _mark(IdLib.toId(market), market);
    }

    // -------------------------------------------------------------------------
    // Ratification — the quoting policy, enforced on-chain
    // -------------------------------------------------------------------------

    /// @notice Midnight calls this before any `take`. An offer only exists if it passes here.
    /// @dev Deliberately signature-free: an offer's validity derives entirely from on-chain state.
    ///      An offer that has become too generous stops being takeable on its own as soon as the
    ///      target tick moves, with no cancellation transaction needed.
    function isRatified(Offer memory offer, bytes memory, address) external view returns (bytes32) {
        _requireNotPaused();
        require(offer.buy, OfferNotABid());
        require(offer.maker == address(this), OfferWrongMaker());
        require(offer.ratifier == address(this), OfferWrongRatifier());
        require(offer.callback == address(this), OfferWrongCallback());
        require(offer.receiverIfMakerIsSeller == address(0), OfferReceiverNotZero());
        require(!offer.reduceOnly, OfferReduceOnly());
        require(offer.group == currentGroup(), OfferWrongGroup());
        // The budget is shared: all live offers carry the same cap, hence the same `consumed`
        // counter. An offer declaring its own cap would escape the global one.
        require(offer.maxUnits == epochBudget && offer.maxAssets == 0, OfferWrongBudget());
        require(offer.continuousFeeCap <= type(uint256).max / 2, OfferFeeCapTooHigh());

        Market memory m = offer.market;
        require(m.midnight == address(MIDNIGHT) && m.loanToken == asset(), OfferWrongMarket());

        bytes32 id = IdLib.toId(m);
        uint8 spacing = MIDNIGHT.tickSpacing(id);
        require(offer.tick <= QUOTE.maxTick(id, m.maturity, spacing), OfferTickTooHigh());

        return CALLBACK_SUCCESS;
    }

    /// @notice The current epoch's `group` — the shared budget counter on the Midnight side.
    function currentGroup() public view returns (bytes32) {
        return keccak256(abi.encode("plumb.bid", address(this), epoch));
    }

    /// @notice Units still purchasable against the epoch's budget.
    function remainingBudget() public view returns (uint256) {
        uint256 used = MIDNIGHT.consumed(address(this), currentGroup());
        return used >= epochBudget ? 0 : epochBudget - used;
    }

    /// @notice Builds Plumb's canonical offer on a market. The bot only has to broadcast it.
    /// @dev Pure view of the policy: anything else the bot could craft would be rejected by
    ///      `isRatified`. It chooses nothing, it transcribes.
    function buildBid(Market memory market, uint256 expiry) external view returns (Offer memory offer) {
        bytes32 id = IdLib.toId(market);
        offer = Offer({
            market: market,
            buy: true,
            maker: address(this),
            start: 0,
            expiry: expiry,
            tick: QUOTE.maxTick(id, market.maturity, MIDNIGHT.tickSpacing(id)),
            group: currentGroup(),
            callback: address(this),
            callbackData: "",
            receiverIfMakerIsSeller: address(0),
            ratifier: address(this),
            reduceOnly: false,
            maxUnits: epochBudget,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max / 2
        });
    }

    // -------------------------------------------------------------------------
    // Execution — capital only leaves Blue here
    // -------------------------------------------------------------------------

    /// @notice Called by Midnight at the exact moment of the `take`.
    /// @dev Midnight positions are already up to date when we enter here: `credit` includes the
    ///      units just bought. So we mark before folding in the lot, otherwise the new units would
    ///      accrete retroactively.
    function onBuy(
        bytes32 id,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256,
        address buyer,
        bytes memory
    ) external nonReentrant returns (bytes32) {
        require(msg.sender == address(MIDNIGHT), NotMidnight());
        require(buyer == address(this), NotSelf());
        require(blueMarketSet, BlueMarketNotSet());
        require(market.loanToken == asset(), WrongLoanToken());
        require(units <= maxSingleFill, FillTooLarge());

        Book storage b = _mark(id, market);
        if (b.units == 0) {
            require(_activeMarkets.length() < MAX_MARKETS, TooManyMarkets());
            _activeMarkets.add(id);
            b.lastMark = uint64(block.timestamp);
            b.maturity = uint64(market.maturity);
        }
        b.units += uint128(units);
        b.value += uint128(buyerAssets);

        QuoteModule.MarketConfig memory c = QUOTE.config(id);
        require(b.units <= c.maxUnits, BookCapExceeded());

        // The cap is checked before touching Blue. A lot larger than the NAV would overflow
        // Morpho's share math on an impossible withdrawal, and the refusal would surface as an
        // unreadable arithmetic panic from Blue rather than a Plumb error. Refuse first, move
        // capital second.
        //
        // Midnight will only collect `buyerAssets` when this callback returns: the cash is still
        // here while the lot is already on the book. So the in-flight amount is subtracted from
        // the NAV, otherwise the cap would be measured against a NAV inflated by double counting.
        uint256 nav = totalAssets();
        require(buyerAssets <= nav, BookCapExceeded());
        require(bookValue() * 10_000 <= (nav - buyerAssets) * maxBookBps, BookCapExceeded());

        uint256 idle = idleAssets();
        if (buyerAssets > idle) BLUE.withdraw(blueMarket, buyerAssets - idle, 0, address(this), address(this));

        emit Bought(id, units, buyerAssets);
        return CALLBACK_SUCCESS;
    }

    /// @notice Collects at maturity: withdraws par on the repaid units and returns the cash to Blue.
    function settle(Market memory market) external nonReentrant returns (uint256 withdrawn) {
        bytes32 id = IdLib.toId(market);
        Book storage b = _mark(id, market);
        require(b.units > 0, NothingToSettle());

        // `withdrawable` is what borrowers have actually repaid. We take no more than that.
        uint256 avail = MIDNIGHT.withdrawable(id);
        withdrawn = avail < b.units ? avail : b.units;
        require(withdrawn > 0, NothingToSettle());

        MIDNIGHT.withdraw(market, withdrawn, address(this), address(this));

        // The withdrawn value leaves the book at its pro-rata marked value. Before maturity that
        // is below par: the difference is a gain recognized ahead of schedule, which gets locked
        // instead of being recognized at once. At maturity, `_mark` has already brought the value
        // to par and the difference is zero.
        uint128 valueOut = uint128((uint256(b.value) * withdrawn) / b.units);
        _lockProfit(withdrawn - valueOut);
        b.units -= uint128(withdrawn);
        b.value -= valueOut;
        if (b.units == 0) {
            _activeMarkets.remove(id);
            delete book[id];
        }

        _accrueFee();
        if (blueMarketSet) BLUE.supply(blueMarket, idleAssets(), 0, address(this), "");
        emit Settled(id, withdrawn, withdrawn);
    }

    // -------------------------------------------------------------------------
    // Treasury
    // -------------------------------------------------------------------------

    function supplyToBlue(uint256 assets) external onlyOperator {
        require(blueMarketSet, BlueMarketNotSet());
        BLUE.supply(blueMarket, assets == type(uint256).max ? idleAssets() : assets, 0, address(this), "");
    }

    function withdrawFromBlue(uint256 assets) external onlyOperator {
        require(blueMarketSet, BlueMarketNotSet());
        BLUE.withdraw(blueMarket, assets, 0, address(this), address(this));
    }

    // -------------------------------------------------------------------------
    // Deposits / withdrawals
    // -------------------------------------------------------------------------

    /// @dev Withdrawals are served by idle cash and the Blue sleeve only. Unmatured credit cannot
    ///      be redeemed early — guaranteeing there is enough left to serve is precisely the book
    ///      cap's job.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 liquid = idleAssets() + _blueLiquidity();
        uint256 own = super.maxWithdraw(owner_);
        return own < liquid ? own : liquid;
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return _convertToShares(maxWithdraw(owner_), Math.Rounding.Floor);
    }

    function _blueLiquidity() internal view returns (uint256) {
        if (!blueMarketSet) return 0;
        uint256 mine = BLUE.expectedSupplyAssets(blueMarket, address(this));
        uint256 free = BLUE.marketLiquidity(blueMarket);
        return mine < free ? mine : free;
    }

    /// @dev Fees must be materialized before the share count is computed, otherwise the fee shares
    ///      retroactively dilute the entrant. Hence the public overrides.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        _accrueFee();
        return super.redeem(shares, receiver, owner_);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _requireNotPaused();
        super._deposit(caller, receiver, assets, shares);
        if (blueMarketSet) BLUE.supply(blueMarket, idleAssets(), 0, address(this), "");
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        uint256 idle = idleAssets();
        if (assets > idle) BLUE.withdraw(blueMarket, assets - idle, 0, address(this), address(this));
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @dev Performance fee on the share price's high-water mark. Charged in shares, so without
    ///      touching liquidity, and never on a mere recovery of a loss.
    function _accrueFee() internal {
        uint256 supply = totalSupply();
        if (supply == 0 || perfFeeBps == 0) return;
        uint256 pps = totalAssets().mulDiv(WAD, supply);
        if (pps <= highWaterMark) return;

        uint256 gain = (pps - highWaterMark).mulDiv(supply, WAD);
        uint256 fee = gain.mulDiv(perfFeeBps, 10_000);
        uint256 shares = fee.mulDiv(supply, totalAssets() - fee, Math.Rounding.Floor);
        // The high-water mark only rises if fees were actually charged. Raising it without
        // charging would subtract that gain from the fee base forever: repeated on sub-unit
        // gains, it would deprive the recipient of its fees at no cost to anyone. Left in place,
        // the tiny gain accumulates until it is worth at least one share.
        if (shares == 0) return;
        _mint(feeRecipient, shares);
        highWaterMark = totalAssets().mulDiv(WAD, totalSupply());
        emit AccrueFee(shares, highWaterMark);
    }

    // -------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------

    /// @notice Opens a new budget epoch. Every offer from the previous epoch dies.
    function openEpoch(uint128 budget) external onlyOperator {
        epoch += 1;
        epochBudget = budget;
        emit OpenEpoch(epoch, currentGroup(), budget);
    }

    /// @notice Kill switch: exhausts the epoch's budget and pauses the vault.
    /// @dev One transaction is enough to pull every live offer, whatever their number.
    function kill() external onlyOperator {
        bytes32 g = currentGroup();
        MIDNIGHT.setConsumed(g, epochBudget, address(this));
        _pause();
        emit Killed(g);
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Appoints the operator. `address(0)` is valid: it is revocation, leaving the owner
    ///         alone entitled to open an epoch or trigger the kill switch.
    function setOperator(address newOperator) external onlyOwner {
        operator = newOperator;
        emit SetOperator(newOperator);
    }

    function setBlueMarket(BlueMarketParams calldata p) external onlyOwner {
        require(p.loanToken == asset(), WrongLoanToken());
        blueMarket = p;
        blueMarketSet = true;
        emit SetBlueMarket(p.collateralToken, p.oracle, p.irm, p.lltv);
    }

    function setRiskParams(uint256 newMaxBookBps, uint128 newMaxSingleFill) external onlyOwner {
        require(newMaxBookBps <= 10_000, BookCapExceeded());
        maxBookBps = newMaxBookBps;
        maxSingleFill = newMaxSingleFill;
        emit SetRiskParams(newMaxBookBps, newMaxSingleFill);
    }

    function setFee(uint256 newPerfFeeBps, address newRecipient) external onlyOwner {
        require(newPerfFeeBps <= MAX_PERF_FEE_BPS, FeeTooHigh());
        require(newRecipient != address(0), ZeroAddress());
        _accrueFee();
        perfFeeBps = newPerfFeeBps;
        feeRecipient = newRecipient;
        emit SetFee(newPerfFeeBps, newRecipient);
    }

    function activeMarkets() external view returns (bytes32[] memory) {
        return _activeMarkets.values();
    }
}
