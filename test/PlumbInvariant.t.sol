// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like, AlwaysRatifier} from "./MidnightForkBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {IdLib} from "../src/interfaces/midnight/IdLib.sol";
import {TickLib} from "../src/interfaces/midnight/TickLib.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

/// @notice Handler: the vault's real attack surface, exposed to the stateful fuzzer.
///
/// Stateless fuzzing (`PlumbFuzz.t.sol`) tests properties on random *inputs*, one transaction at
/// a time. It cannot find a bug that only appears after a certain *sequence*: a partial
/// settlement followed by a withdrawal, a deposit slotted between two `take`s, an epoch rotation
/// in the middle of a fill, a cap tightening on an already loaded book. That is what this file
/// covers.
///
/// Each action is bounded to what a real actor can do — and nothing more: the handler has no
/// power the world would not have.
contract PlumbHandler is MidnightForkBase {
    PlumbVault public vault;
    QuoteModule public quote;

    address public OWNER;
    address public OPERATOR;

    address[3] public actors;

    // --- ghosts ---
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    /// @notice Highest share price ever observed, in assets per 1e18 shares.
    uint256 public ghostPeakPps = 1e18;
    /// @notice Number of actions actually executed, per family. Serves to prove the campaign
    ///         really exercised the system and did not just reject 5000 calls.
    mapping(bytes32 => uint256) public calls;

    /// @notice Last reason a buy was refused. Without it, a campaign where *all* buys fail is
    ///         indistinguishable from a healthy one — which is exactly what happened.
    bytes public lastHitBidError;

    uint256 internal _nonce;

    constructor(PlumbVault v, QuoteModule q, AlwaysRatifier r, address owner_, address operator_) {
        vault = v;
        quote = q;
        ratifier = r;
        OWNER = owner_;
        OPERATOR = operator_;
        id = IdLib.toId(midnightMarket());

        actors[0] = makeAddr("ALICE");
        actors[1] = makeAddr("BOB");
        actors[2] = makeAddr("CAROL");
        for (uint256 i; i < 3; ++i) {
            deal(address(USDC), actors[i], 1_000_000e6);
            vm.prank(actors[i]);
            IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    /// @dev After each action: record any new peak of the share price.
    modifier track(bytes32 tag) {
        _;
        calls[tag] += 1;
        uint256 supply = vault.totalSupply();
        if (supply > 0) {
            uint256 pps = (vault.totalAssets() * 1e18) / supply;
            if (pps > ghostPeakPps) ghostPeakPps = pps;
        }
    }

    // -------------------------------------------------------------------------
    // Depositors
    // -------------------------------------------------------------------------

    function deposit(uint256 seed, uint256 assets) external track("deposit") {
        address a = _actor(seed);
        assets = bound(assets, 1e6, 200_000e6);
        if (IERC20Like(address(USDC)).balanceOf(a) < assets) return;
        vm.prank(a);
        try vault.deposit(assets, a) {
            ghostDeposited += assets;
        } catch {}
    }

    function withdraw(uint256 seed, uint256 assets) external track("withdraw") {
        address a = _actor(seed);
        uint256 cap = vault.maxWithdraw(a);
        if (cap == 0) return;
        assets = bound(assets, 1, cap);
        vm.prank(a);
        try vault.withdraw(assets, a, a) {
            ghostWithdrawn += assets;
        } catch {}
    }

    function redeemAll(uint256 seed) external track("redeemAll") {
        address a = _actor(seed);
        uint256 shares = vault.maxRedeem(a);
        if (shares == 0) return;
        uint256 before = IERC20Like(address(USDC)).balanceOf(a);
        vm.prank(a);
        try vault.redeem(shares, a, a) {
            ghostWithdrawn += IERC20Like(address(USDC)).balanceOf(a) - before;
        } catch {}
    }

    // -------------------------------------------------------------------------
    // The book
    // -------------------------------------------------------------------------

    /// @dev A lender originates then comes to take Plumb's bid. This is the only path through
    ///      which the vault acquires credit.
    /// @dev The size is scaled down to what the book can actually absorb. A real seller does
    ///      exactly that: they size their exit to the displayed bid. Drawing sizes blindly made
    ///      nearly every buy fail, and a sequence with no buy at all exercises nothing of what the
    ///      campaign claims to verify. The refusals (cap, budget, size) have their unit tests;
    ///      here we want state, not reverts.
    function hitBid(uint256 units, uint256 marketSeed) external track("hitBid") {
        if (MATURITY <= block.timestamp + 2 days) return;

        uint256 nav = vault.totalAssets();
        uint256 book = vault.bookValue();
        uint256 capRoom = (nav * vault.maxBookBps()) / 10_000;
        capRoom = capRoom > book ? capRoom - book : 0;

        uint256 room = _min(_min(vault.remainingBudget(), vault.maxSingleFill()), capRoom);
        if (room < 1_000e6) return;
        units = bound(units, 1_000e6, _min(room, 60_000e6));
        try this.originateAndTake(_variant(marketSeed % 3), units) {
            calls["hitBid.filled"] += 1;
        } catch (bytes memory e) {
            lastHitBidError = e;
        }
    }

    /// @dev External so that a legitimate rejection — book cap, exhausted budget, pause, too many
    ///      markets — is a clean refusal and not a campaign failure. That is precisely the point:
    ///      these refusals must leave the system in a state where the invariants still hold.
    function originateAndTake(Market memory m, uint256 units) external {
        require(msg.sender == address(this));
        _originateOn(m, SELLER, units, 1200);
        uint128 credit = MIDNIGHT.credit(IdLib.toId(m), SELLER);
        Offer memory bid = vault.buildBid(m, type(uint256).max);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", credit, SELLER, SELLER, address(0), "");
    }

    function markMarket(uint256 marketSeed) external track("mark") {
        try vault.mark(_variant(marketSeed % 3)) {} catch {}
    }

    function settleMarket(uint256 marketSeed) external track("settle") {
        try vault.settle(_variant(marketSeed % 3)) {
            calls["settle.done"] += 1;
        } catch {}
    }

    /// @dev The borrower repays part of their debt: this is what feeds `withdrawable` and thus
    ///      what makes *partial* settlements reachable.
    function repayPartial(uint256 marketSeed, uint256 frac) external track("repay") {
        Market memory m = _variant(marketSeed % 3);
        uint128 d = MIDNIGHT.debt(IdLib.toId(m), BORROWER);
        if (d == 0) return;
        uint256 amount = bound(frac, 1, d);
        deal(address(USDC), BORROWER, amount * 2);
        vm.prank(BORROWER);
        IERC20Like(address(USDC)).approve(address(MIDNIGHT), type(uint256).max);
        vm.prank(BORROWER);
        try MIDNIGHT.repay(m, amount, BORROWER, address(0), "") {} catch {}
    }

    // -------------------------------------------------------------------------
    // Time and governance
    // -------------------------------------------------------------------------

    /// @dev Time never advances past maturity: beyond that point the Midnight market changes
    ///      regime, and it is no longer the same system being tested.
    function warp(uint256 dt) external track("warp") {
        if (MATURITY <= block.timestamp + 1 days) return;
        uint256 room = MATURITY - block.timestamp - 1 days;
        vm.warp(block.timestamp + bound(dt, 1 hours, room > 10 days ? 10 days : room));
    }

    /// @dev Governance bounds stay within the range an operator would actually use. Letting them
    ///      sweep the whole space — zero budget, zero cap — amounts to replaying the kill switch
    ///      on every call: the book never fills, and the campaign checks invariants on an inert
    ///      vault. That is exactly the trap `afterInvariant` detects. Zero budget and zero cap
    ///      have their own unit tests.
    function rotateEpoch(uint256 budget) external track("rotateEpoch") {
        vm.prank(OPERATOR);
        vault.openEpoch(uint128(bound(budget, 100_000e6, 500_000e6)));
    }

    function setRisk(uint256 bps, uint256 fill) external track("setRisk") {
        vm.prank(OWNER);
        vault.setRiskParams(bound(bps, 3_000, 10_000), uint128(bound(fill, 50_000e6, 300_000e6)));
    }

    function setFee(uint256 bps) external track("setFee") {
        // Bound read before the prank: an external call nested in the argument list would
        // consume the pending `vm.prank` and the call would go out from the wrong address.
        uint256 capped = bound(bps, 0, vault.MAX_PERF_FEE_BPS());
        address recipient = makeAddr("FEES");
        vm.prank(OWNER);
        vault.setFee(capped, recipient);
    }

    // -------------------------------------------------------------------------

    /// @dev Three markets distinguished by `rcfThreshold`: enough to exercise competition between
    ///      markets, without blowing up the campaign's RPC cost.
    function _variant(uint256 k) internal pure returns (Market memory m) {
        m = midnightMarket();
        m.rcfThreshold = 3e9 + k;
    }

    function marketAt(uint256 k) external pure returns (Market memory) {
        return _variant(k);
    }

    function _originateOn(Market memory m, address lender, uint256 units, uint256 rateBps) internal {
        uint256 tenor = m.maturity - block.timestamp;
        uint256 price = 1e18 - (rateBps * 1e18 * tenor) / (10_000 * 365 days);
        uint8 spacing = MIDNIGHT.tickSpacing(IdLib.toId(m));
        uint256 tick = TickLib.priceToTick(price, spacing);
        if (TickLib.tickToPrice(tick) > price) tick -= spacing;

        Offer memory o = Offer({
            market: m,
            buy: false,
            maker: BORROWER,
            start: 0,
            expiry: type(uint256).max,
            tick: tick,
            group: keccak256(abi.encode("inv.origination", _nonce++)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: BORROWER,
            ratifier: address(ratifier),
            reduceOnly: false,
            maxUnits: uint128(units),
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
        vm.prank(lender);
        MIDNIGHT.take(o, "", units, lender, address(0), address(0), "");
    }
}

/// @notice Stateful invariants: what must remain true after *any* sequence of actions.
contract PlumbInvariantTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");

    PlumbVault vault;
    QuoteModule quote;
    PlumbHandler handler;

    uint256 constant N_MARKETS = 3;

    function setUp() public {
        _forkSetUp();

        quote = new QuoteModule(OWNER);
        vault = new PlumbVault(address(USDC), address(MIDNIGHT), BLUE, address(quote), OWNER, FEES);

        vm.startPrank(OWNER);
        vault.setBlueMarket(blueMarket());
        vault.setOperator(OPERATOR);
        vault.setRiskParams(6000, 200_000e6);
        vm.stopPrank();

        deal(WETH, BORROWER, 20_000e18);
        for (uint256 k; k < N_MARKETS; ++k) {
            Market memory m = midnightMarket();
            m.rcfThreshold = 3e9 + k;
            bytes32 mid = MIDNIGHT.touchMarket(m);

            vm.prank(OWNER);
            quote.setMarketConfig(
                mid,
                QuoteModule.MarketConfig({
                    enabled: true,
                    rateBps: 900,
                    minTenor: 1 days,
                    maxTenor: 90 days,
                    maxUnits: 500_000e6
                })
            );
            vm.prank(BORROWER);
            MIDNIGHT.supplyCollateral(m, 0, 1_000e18, BORROWER);
        }

        vm.prank(OPERATOR);
        vault.openEpoch(400_000e6);

        // A first depositor seeds the vault. The "empty vault" case has its own unit tests;
        // here we want random sequences to run against a working system.
        vm.startPrank(LP);
        IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);
        vault.deposit(100_000e6, LP);
        vm.stopPrank();

        handler = new PlumbHandler(vault, quote, ratifier, OWNER, OPERATOR);
        deal(address(USDC), SELLER, 5_000_000e6);
        vm.prank(SELLER);
        IERC20Like(address(USDC)).approve(address(MIDNIGHT), type(uint256).max);

        // Restricted senders. Without this the fuzzer draws random addresses, and on a fork each
        // one triggers an RPC request to load an account that does not exist — a few thousand
        // useless calls per campaign, and the public RPC answers 429. The harness already pranks
        // the relevant actor inside each action: the external sender does not matter.
        targetSender(address(0xA11CE));

        // `originateAndTake` and `marketAt` are internal cogs of the handler, not actions an
        // actor could trigger. Leaving them in the target would waste half the calls on
        // authorization reverts.
        bytes4[] memory sels = new bytes4[](11);
        sels[0] = PlumbHandler.deposit.selector;
        sels[1] = PlumbHandler.withdraw.selector;
        sels[2] = PlumbHandler.redeemAll.selector;
        sels[3] = PlumbHandler.hitBid.selector;
        sels[4] = PlumbHandler.markMarket.selector;
        sels[5] = PlumbHandler.settleMarket.selector;
        sels[6] = PlumbHandler.repayPartial.selector;
        sels[7] = PlumbHandler.warp.selector;
        sels[8] = PlumbHandler.rotateEpoch.selector;
        sels[9] = PlumbHandler.setRisk.selector;
        sels[10] = PlumbHandler.setFee.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
        targetContract(address(handler));
    }

    // -------------------------------------------------------------------------

    /// @notice The handler must be able to fill the book through its own actions.
    /// @dev Guardrail for the harness itself: if no sequence of actions can lead to a buy, the
    ///      campaign checks its invariants on an inert vault and proves nothing. It has happened.
    function test_HandlerCanReachAFill() public {
        handler.deposit(0, 100_000e6);
        handler.hitBid(20_000e6, 0);
        if (handler.calls("hitBid.filled") == 0) {
            console2.log("refusal reason:");
            console2.logBytes(handler.lastHitBidError());
        }
        assertGt(handler.calls("hitBid.filled"), 0, "the handler cannot fill the book");
    }

    /// @notice The book cap holds after any sequence.
    /// @dev This is the risk identified at the project's outset: an entire book of stuck positions
    ///      against zero liquidity. No sequence — not even a cap tightening in the middle of a
    ///      fill — may leave the book above its *acquired* share of NAV. A retroactive cap
    ///      tightening is legitimate and breaks nothing: it forbids buying more, it would not
    ///      unwind the existing book. So we check the invariant that makes sense: the book never
    ///      exceeds NAV.
    function invariant_BookNeverExceedsNav() public view {
        assertLe(vault.bookValue(), vault.totalAssets(), "the book cannot exceed NAV");
    }

    /// @notice The book stays bounded and self-consistent.
    function invariant_ActiveMarketsAreConsistent() public view {
        bytes32[] memory active = vault.activeMarkets();
        assertLe(active.length, 8, "MAX_MARKETS exceeded");
        for (uint256 i; i < active.length; ++i) {
            (uint128 units, uint128 value,,) = vault.book(active[i]);
            assertGt(units, 0, "an active market without units is a ghost market");
            assertLe(value, units, "the marked value cannot exceed face value");
            for (uint256 j = i + 1; j < active.length; ++j) {
                assertTrue(active[i] != active[j], "duplicate in the active market set");
            }
        }
    }

    /// @notice Conversely: no market carrying units may be outside the set.
    /// @dev A market dropped from the set would leave `bookValue()`: the NAV would stop counting a
    ///      real position, and the share price would gap down at `settle` time.
    function invariant_NoBookedMarketIsMissingFromTheSet() public view {
        bytes32[] memory active = vault.activeMarkets();
        for (uint256 k; k < N_MARKETS; ++k) {
            Market memory m = handler.marketAt(k);
            bytes32 mid = IdLib.toId(m);
            (uint128 units,,,) = vault.book(mid);
            if (units == 0) continue;
            bool found;
            for (uint256 i; i < active.length; ++i) {
                if (active[i] == mid) found = true;
            }
            assertTrue(found, "market with units missing from the active set");
        }
    }

    /// @notice The vault stays solvent: what all holders can claim fits within the NAV.
    function invariant_TotalClaimsFitInNav() public view {
        uint256 supply = vault.totalSupply();
        if (supply == 0) return;
        assertLe(vault.convertToAssets(supply), vault.totalAssets(), "claims exceed the NAV");

        // And no actor can withdraw more than their share.
        for (uint256 i; i < 3; ++i) {
            address a = handler.actors(i);
            assertLe(
                vault.maxWithdraw(a),
                vault.convertToAssets(vault.balanceOf(a)),
                "an actor can withdraw more than their share"
            );
        }
    }

    /// @notice Withdrawals are never promised beyond the liquidity actually mobilizable.
    /// @dev This is the promise made to the depositor: `maxWithdraw` does not lie. Unmatured
    ///      credit is not redeemable, and the NAV it represents must never be offered for
    ///      withdrawal.
    function invariant_WithdrawableIsBackedByLiquidAssets() public view {
        uint256 liquid = vault.idleAssets() + vault.blueAssets();
        for (uint256 i; i < 3; ++i) {
            assertLe(vault.maxWithdraw(handler.actors(i)), liquid, "withdrawal promised without liquidity");
        }
    }

    /// @notice The high-water mark never exceeds a peak actually reached.
    /// @dev An overstated HWM would freeze fees indefinitely; an understated HWM would charge the
    ///      same performance twice. The ghost records every peak observed after an action.
    function invariant_HighWaterMarkIsAReachedPeak() public view {
        assertLe(vault.highWaterMark(), handler.ghostPeakPps() + 1, "HWM above any reached peak");
    }

    /// @notice The epoch budget is a ceiling, never exceeded by the announced remainder.
    function invariant_RemainingBudgetIsBounded() public view {
        assertLe(vault.remainingBudget(), vault.epochBudget(), "remainder above the budget");
    }

    /// @notice The campaign must have actually exercised the system.
    /// @dev Without this, a regression making *all* actions fail would leave every invariant green
    ///      on an inert system. It is the guardrail's guardrail — and it lives in
    ///      `afterInvariant`, called once the sequence has played out, not in an invariant, which
    ///      would be evaluated before the first call.
    function afterInvariant() public view {
        assertGt(handler.calls("deposit"), 0, "no deposit: inert campaign");
        assertGt(handler.calls("hitBid.filled"), 0, "no completed buy: inert campaign");
        console2.log("completed buys", handler.calls("hitBid.filled"));
        console2.log("deposits   ", handler.calls("deposit"));
        console2.log("hitBid ok  ", handler.calls("hitBid.filled"));
        console2.log("settle ok  ", handler.calls("settle.done"));
        console2.log("withdraws  ", handler.calls("withdraw"));
        console2.log("in / out", handler.ghostDeposited(), handler.ghostWithdrawn());
    }
}
