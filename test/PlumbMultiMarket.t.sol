// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {IdLib} from "../src/interfaces/midnight/IdLib.sol";
import {TickLib} from "../src/interfaces/midnight/TickLib.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

/// @notice Multi-market load up to `MAX_MARKETS = 8`.
///
/// The cap of 8 was tested; its *consequence* was not. `bookValue()` loops over the active
/// markets and makes one external call to Midnight per iteration — and `bookValue()` is inside
/// `totalAssets()`, hence on the path of every deposit, withdrawal, mark and `onBuy`. The risk is
/// not exceeding the block limit: it is an `onBuy` becoming expensive enough that a seller gives
/// up on taking the bid, or a depositor withdrawal that gas makes prohibitive at the worst moment.
///
/// We build 8 genuinely distinct Midnight markets (`rcfThreshold` variants, hence 8 different
/// `id`s for the same collateral/maturity pair), fill them all, and measure.
contract PlumbMultiMarketTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");

    PlumbVault vault;
    QuoteModule quote;

    uint16 constant RATE_BPS = 900;
    uint128 constant BUDGET = 400_000e6;
    uint256 constant N = 8; // = PlumbVault.MAX_MARKETS
    uint256 constant LOT = 12_000e6;

    bytes32[] ids;
    uint256 _nonce;

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
        vault.setBlueMarket(blueMarket());
        vault.setOperator(OPERATOR);
        vault.setRiskParams(6000, 200_000e6);
        vm.stopPrank();

        // 9 markets: 8 to fill, the 9th to prove the cap refuses.
        deal(WETH, BORROWER, 20_000e18);
        vm.prank(OWNER);
        quote.setVault(address(vault));
        for (uint256 i; i <= N; ++i) {
            Market memory m = _variant(i);
            bytes32 mid = MIDNIGHT.touchMarket(m);
            ids.push(mid);

            vm.prank(OWNER);
            quote.setMarketConfig(
                mid,
                QuoteModule.MarketConfig({
                    enabled: true,
                    rateBps: RATE_BPS,
                    volSpreadBps: 0,
                    skewBps: 0,
                    minTenor: 1 days,
                    maxTenor: 90 days,
                    maxUnits: 500_000e6
                })
            );

            // Each market has its own collateral accounting: the borrower must take a position in it.
            vm.prank(BORROWER);
            MIDNIGHT.supplyCollateral(m, 0, 300e18, BORROWER);
        }

        vm.prank(OPERATOR);
        vault.openEpoch(BUDGET);

        vm.startPrank(LP);
        IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);
        vault.deposit(400_000e6, LP);
        vm.stopPrank();
    }

    /// @dev Market variant: only `rcfThreshold` moves, so the `id` changes and nothing else. The
    ///      8 markets are thus comparable — the gas measurement does not mix two configurations.
    function _variant(uint256 k) internal pure returns (Market memory m) {
        m = midnightMarket();
        m.rcfThreshold = 3e9 + k;
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
            group: keccak256(abi.encode("origination", m.rcfThreshold, units, _nonce++)),
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

    /// @dev Opens a lot on market `k`: the seller originates then takes Plumb's bid.
    function _fill(uint256 k) internal returns (uint256 gasUsed) {
        _originateOn(_variant(k), SELLER, LOT, 1200);
        uint128 credit = MIDNIGHT.credit(ids[k], SELLER);
        Offer memory bid = vault.buildBid(_variant(k), type(uint256).max);

        vm.prank(SELLER);
        uint256 g0 = gasleft();
        MIDNIGHT.take(bid, "", credit, SELLER, SELLER, address(0), "");
        gasUsed = g0 - gasleft();
    }

    // -------------------------------------------------------------------------

    /// @notice The cost of `onBuy` grows with the number of active markets, and we want to know by how much.
    function test_TakeGasScalesWithActiveMarkets() public {
        uint256 first;
        uint256 last;

        for (uint256 k; k < N; ++k) {
            uint256 g = _fill(k);
            if (k == 0) first = g;
            if (k == N - 1) last = g;
            console2.log("take #", k + 1, "gas", g);
            assertEq(vault.activeMarkets().length, k + 1, "market not registered");
        }

        console2.log("overhead of 8th take vs the 1st", last - first);

        // The 8th `take` stays far below the Base block gas limit (30M) and below the threshold
        // where a seller would give up. The bound is deliberately loose: it serves as an alarm if
        // a change made the loop quadratic, not as a performance measurement.
        assertLt(last, 3_000_000, "the 8-market take must remain practical");

        // Growth must be linear: each additional market adds one `updatePosition` and one set
        // read, nothing more. The 8th therefore costs less than twice the 1st.
        assertLt(last, first * 2, "the bookValue loop must stay linear");
    }

    /// @notice `bookValue()` is on the path of every deposit and every withdrawal.
    function test_DepositWithdrawGasWithFullBook() public {
        for (uint256 k; k < N; ++k) {
            _fill(k);
        }
        assertEq(vault.activeMarkets().length, N, "all 8 markets must be active");

        address user = makeAddr("LATE_LP");
        deal(address(USDC), user, 50_000e6);
        vm.startPrank(user);
        IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);

        uint256 g0 = gasleft();
        vault.deposit(50_000e6, user);
        uint256 gasDeposit = g0 - gasleft();

        uint256 want = vault.maxWithdraw(user);
        g0 = gasleft();
        vault.withdraw(want, user, user);
        uint256 gasWithdraw = g0 - gasleft();
        vm.stopPrank();

        console2.log("deposit with 8 markets, gas", gasDeposit);
        console2.log("withdraw with 8 markets, gas", gasWithdraw);

        // A depositor must never be deterred by the book. These bounds are the commitment kept
        // to them: exiting remains an ordinary transaction, even with a full book.
        assertLt(gasDeposit, 2_000_000, "depositing must stay cheap with a full book");
        assertLt(gasWithdraw, 2_000_000, "withdrawing must stay cheap with a full book");
    }

    /// @notice The 9th market is refused, and the refusal damages nothing.
    function test_NinthMarketIsRefusedWithoutSideEffect() public {
        for (uint256 k; k < N; ++k) {
            _fill(k);
        }

        uint256 navBefore = vault.totalAssets();
        uint256 bookBefore = vault.bookValue();

        _originateOn(_variant(N), SELLER, LOT, 1200);
        uint128 credit = MIDNIGHT.credit(ids[N], SELLER);
        Offer memory bid = vault.buildBid(_variant(N), type(uint256).max);

        vm.prank(SELLER);
        vm.expectRevert(PlumbVault.TooManyMarkets.selector);
        MIDNIGHT.take(bid, "", credit, SELLER, SELLER, address(0), "");

        assertEq(vault.activeMarkets().length, N, "the refusal must not register the market");
        assertEq(vault.totalAssets(), navBefore, "NAV unchanged after a refusal");
        assertEq(vault.bookValue(), bookBefore, "book unchanged after a refusal");
        assertEq(MIDNIGHT.credit(ids[N], SELLER), credit, "the seller keeps their position");
        assertEq(MIDNIGHT.credit(ids[N], address(vault)), 0, "Plumb acquired nothing");
    }

    /// @notice The book cap is measured on the aggregate, not market by market.
    function test_BookCapIsGlobalAcrossMarkets() public {
        for (uint256 k; k < N; ++k) {
            _fill(k);
            assertLe(vault.bookValue() * 10_000, vault.totalAssets() * vault.maxBookBps(), "global cap exceeded");
        }

        // 8 lots of 12k against a 400k NAV: we are under 60%. We tighten the cap below the
        // current exposure and check that the next market is refused — the aggregate is what
        // bites, while no market taken in isolation exceeds anything.
        uint256 book = vault.bookValue();
        uint256 nav = vault.totalAssets();
        uint256 tight = (book * 10_000) / nav; // exactly the current exposure, plus one wei of margin
        vm.prank(OWNER);
        vault.setRiskParams(tight, 200_000e6);

        // One more lot on an already active market necessarily crosses the tightened cap.
        _originateOn(_variant(0), SELLER, LOT, 1200);
        uint128 credit = MIDNIGHT.credit(ids[0], SELLER);
        Offer memory bid = vault.buildBid(_variant(0), type(uint256).max);
        vm.prank(SELLER);
        vm.expectRevert(PlumbVault.BookCapExceeded.selector);
        MIDNIGHT.take(bid, "", credit, SELLER, SELLER, address(0), "");
    }

    /// @notice Settlement at maturity must remain doable market by market, with a full book.
    function test_SettleAllEightAtMaturity() public {
        for (uint256 k; k < N; ++k) {
            _fill(k);
        }

        vm.warp(_variant(0).maturity + 1);
        deal(address(USDC), BORROWER, 2_000_000e6);
        vm.prank(BORROWER);
        IERC20Like(address(USDC)).approve(address(MIDNIGHT), type(uint256).max);
        for (uint256 k; k < N; ++k) {
            // `debt` is read before the prank: an external call nested in the argument list
            // would consume the pending `vm.prank`.
            uint128 d = MIDNIGHT.debt(ids[k], BORROWER);
            vm.prank(BORROWER);
            MIDNIGHT.repay(_variant(k), d, BORROWER, address(0), "");
        }

        for (uint256 k; k < N; ++k) {
            uint256 g0 = gasleft();
            vault.settle(_variant(k));
            console2.log("settle market", k + 1, g0 - gasleft());
        }

        assertEq(vault.activeMarkets().length, 0, "the book must be empty after settlement");
        assertEq(vault.bookValue(), 0, "nothing left in the book");
        assertGt(vault.totalAssets(), 400_000e6, "the 8 lots must have earned");
    }
}
