// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

contract PlumbVaultTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");

    PlumbVault vault;
    QuoteModule quote;

    uint16 constant RATE_BPS = 900; // Plumb bids at 9% annualized
    uint128 constant BUDGET = 300_000e6;

    function setUp() public {
        _forkSetUp();

        quote = new QuoteModule(OWNER);
        vault = new PlumbVault(
            "Plumb Exit Liquidity USDC", "plUSDC", address(USDC), address(MIDNIGHT), BLUE, address(quote), OWNER, FEES
        );

        vm.startPrank(OWNER);
        quote.setVault(address(vault));
        quote.setMarketConfig(
            id,
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
        vault.setBlueMarket(blueMarket());
        vault.setOperator(OPERATOR);
        vault.setRiskParams(6000, 200_000e6);
        vm.stopPrank();

        vm.prank(OPERATOR);
        vault.openEpoch(BUDGET);

        vm.startPrank(LP);
        IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);
        vault.deposit(200_000e6, LP);
        vm.stopPrank();
    }

    /// @dev The seller takes Plumb's bid for `units`.
    function _hitBid(uint256 units) internal returns (uint256 proceeds) {
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        uint256 before = USDC.balanceOf(SELLER);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", units, SELLER, SELLER, address(0), "");
        proceeds = USDC.balanceOf(SELLER) - before;
    }

    // -------------------------------------------------------------------------
    // Full lifecycle
    // -------------------------------------------------------------------------

    function test_FullLifecycle() public {
        // Capital sits on Blue from the moment of deposit.
        assertApproxEqAbs(vault.blueAssets(), 200_000e6, 1, "cash must be supplied to Blue");
        assertEq(vault.totalAssets(), vault.blueAssets() + vault.idleAssets(), "no book yet");

        // A lender enters at 3.7% (the market), then wants out 15 days later.
        _originate(SELLER, 100_000e6, 370);
        uint128 sellerCredit = MIDNIGHT.credit(id, SELLER);
        vm.warp(block.timestamp + 15 days);

        uint256 navBefore = vault.totalAssets();
        uint256 proceeds = _hitBid(sellerCredit);

        assertEq(MIDNIGHT.credit(id, SELLER), 0, "seller has exited");
        assertEq(MIDNIGHT.debt(id, SELLER), 0, "exit without taking on debt");
        assertEq(MIDNIGHT.credit(id, address(vault)), sellerCredit, "Plumb carries the claim");

        // The purchase is NAV-neutral: cash is swapped for credit at the price paid.
        (uint128 units, uint128 value,,) = vault.book(id);
        assertEq(units, sellerCredit, "units on the book");
        assertEq(value, proceeds, "marked value = price paid");
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e15, "NAV unchanged on purchase");

        // The book accretes toward par over time.
        vm.warp(block.timestamp + 30 days);
        uint256 navMid = vault.totalAssets();
        assertGt(navMid, navBefore, "the book must accrete");
        assertLt(vault.previewMark(id), units, "below par before maturity");

        // At maturity the borrower repays, Plumb collects par.
        vm.warp(MATURITY + 1);
        _repayAll();

        uint256 sharesBefore = vault.totalSupply();
        vault.settle(midnightMarket());

        assertEq(MIDNIGHT.credit(id, address(vault)), 0, "position closed out");
        assertEq(vault.activeMarkets().length, 0, "book empty");
        assertGt(vault.totalSupply(), sharesBefore, "perf fee charged in shares");

        uint256 nav = vault.totalAssets();
        uint256 profit = nav - 200_000e6;
        console2.log("Final NAV          :", nav);
        console2.log("Profit             :", profit);
        console2.log("Fee shares         :", vault.balanceOf(FEES));
        assertGt(profit, 0, "the vault must have earned");

        // The LP can redeem everything.
        uint256 maxR = vault.maxRedeem(LP);
        assertApproxEqAbs(maxR, vault.balanceOf(LP), 1e6, "empty book => everything is liquid");
        vm.prank(LP);
        uint256 got = vault.redeem(maxR, LP, LP);
        assertGt(got, 200_000e6, "the LP exits at a gain");
    }

    function _repayAll() internal {
        deal(address(USDC), BORROWER, 1_000_000e6);
        vm.prank(BORROWER);
        IERC20Like(address(USDC)).approve(address(MIDNIGHT), type(uint256).max);
        uint128 d = MIDNIGHT.debt(id, BORROWER);
        vm.prank(BORROWER);
        MIDNIGHT.repay(midnightMarket(), d, BORROWER, address(0), "");
    }

    // -------------------------------------------------------------------------
    // The quoting policy
    // -------------------------------------------------------------------------

    /// @dev Plumb must never pay more than its target price, not even by one tick.
    function test_QuoteNeverPaysAboveTarget() public view {
        uint8 spacing = MIDNIGHT.tickSpacing(id);
        uint256 remaining = MATURITY - block.timestamp;
        uint256 target = 1e18 - (uint256(RATE_BPS) * 1e18 * remaining) / (10_000 * 365 days);
        assertLe(quote.maxPrice(id, MATURITY, spacing), target, "rounding must disfavor the vault");
    }

    function test_QuoteRejectsRateOutOfBounds() public {
        vm.startPrank(OWNER);
        QuoteModule.MarketConfig memory c = QuoteModule.MarketConfig({
            enabled: true,
            rateBps: 100,
            volSpreadBps: 0,
            skewBps: 0,
            minTenor: 1 days,
            maxTenor: 90 days,
            maxUnits: 1e12
        });
        vm.expectRevert(QuoteModule.RateOutOfBounds.selector);
        quote.setMarketConfig(id, c);
        c.rateBps = 5000;
        vm.expectRevert(QuoteModule.RateOutOfBounds.selector);
        quote.setMarketConfig(id, c);
        vm.stopPrank();
    }

    function test_QuoteRejectsTooLongTenor() public {
        vm.prank(OWNER);
        quote.setMarketConfig(
            id,
            QuoteModule.MarketConfig({
                enabled: true,
                rateBps: RATE_BPS,
                volSpreadBps: 0,
                skewBps: 0,
                minTenor: 1 days,
                maxTenor: 30 days,
                maxUnits: 500_000e6
            })
        );
        // NB: hoist the nested call out of expectRevert, otherwise it consumes it.
        uint8 spacing = MIDNIGHT.tickSpacing(id);
        vm.expectRevert(QuoteModule.TenorOutOfBounds.selector);
        quote.maxTick(id, MATURITY, spacing);
    }

    // -------------------------------------------------------------------------
    // Ratification: what a compromised bot cannot do
    // -------------------------------------------------------------------------

    /// @dev The crux of the security model: nobody can make the vault pay more than the tick the
    ///      policy computed, even by crafting the offer from scratch.
    function test_CannotOverpay() public {
        _originate(SELLER, 100_000e6, 370);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        bid.tick += MIDNIGHT.tickSpacing(id); // one notch more expensive

        vm.prank(SELLER);
        vm.expectRevert(PlumbVault.OfferTickTooHigh.selector);
        MIDNIGHT.take(bid, "", 10_000e6, SELLER, SELLER, address(0), "");
    }

    function test_CannotEscapeSharedBudget() public {
        _originate(SELLER, 100_000e6, 370);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        bid.group = keccak256("some other budget");

        vm.prank(SELLER);
        vm.expectRevert(PlumbVault.OfferWrongGroup.selector);
        MIDNIGHT.take(bid, "", 10_000e6, SELLER, SELLER, address(0), "");
    }

    function test_CannotRaiseOwnBudget() public {
        _originate(SELLER, 100_000e6, 370);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        bid.maxUnits = BUDGET * 10;

        vm.prank(SELLER);
        vm.expectRevert(PlumbVault.OfferWrongBudget.selector);
        MIDNIGHT.take(bid, "", 10_000e6, SELLER, SELLER, address(0), "");
    }

    function test_CannotDivertFunds() public {
        _originate(SELLER, 100_000e6, 370);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        bid.callback = address(0); // would pay from the vault balance without going through onBuy

        vm.prank(SELLER);
        vm.expectRevert(PlumbVault.OfferWrongCallback.selector);
        MIDNIGHT.take(bid, "", 10_000e6, SELLER, SELLER, address(0), "");
    }

    // -------------------------------------------------------------------------
    // Caps and kill switch
    // -------------------------------------------------------------------------

    function test_BudgetCapsTotalExposure() public {
        _originate(SELLER, 400_000e6, 370);
        vm.warp(block.timestamp + 1 days);

        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        vm.expectRevert(IMidnight.ConsumedUnits.selector);
        MIDNIGHT.take(bid, "", uint256(BUDGET) + 1, SELLER, SELLER, address(0), "");
    }

    function test_BookCapRefusesBeyondRatio() public {
        // 200k NAV, 60% cap: beyond ~120k of marked credit, the purchase must be refused.
        _originate(SELLER, 200_000e6, 370);
        vm.warp(block.timestamp + 1 days);

        vm.prank(OWNER);
        vault.setRiskParams(6000, 200_000e6);

        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        vm.expectRevert(PlumbVault.BookCapExceeded.selector);
        MIDNIGHT.take(bid, "", 180_000e6, SELLER, SELLER, address(0), "");

        // Below the cap, the same purchase goes through.
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", 100_000e6, SELLER, SELLER, address(0), "");
        assertLe(vault.bookValue() * 10_000, vault.totalAssets() * 6000, "book cap respected");
    }

    function test_MaxSingleFill() public {
        _originate(SELLER, 200_000e6, 370);
        vm.warp(block.timestamp + 1 days);
        vm.prank(OWNER);
        vault.setRiskParams(6000, 10_000e6);

        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        vm.expectRevert(PlumbVault.FillTooLarge.selector);
        MIDNIGHT.take(bid, "", 10_001e6, SELLER, SELLER, address(0), "");
    }

    /// @dev One transaction must be enough to pull every live offer.
    function test_KillSwitchRetiresAllOffers() public {
        _originate(SELLER, 100_000e6, 370);
        vm.warp(block.timestamp + 1 days);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);

        vm.prank(OPERATOR);
        vault.kill();
        assertEq(vault.remainingBudget(), 0, "budget exhausted");

        // Even once the pause is lifted, offers from the killed epoch stay dead: the `group`
        // budget is consumed on the Midnight side, it no longer depends on vault state.
        vm.prank(OWNER);
        vault.unpause();
        vm.prank(SELLER);
        vm.expectRevert(IMidnight.ConsumedUnits.selector);
        MIDNIGHT.take(bid, "", 1_000e6, SELLER, SELLER, address(0), "");
    }

    /// @dev Reopening an epoch restores budget without touching Midnight's monotonic counter.
    function test_NewEpochRestoresBudget() public {
        vm.prank(OPERATOR);
        vault.kill();
        vm.prank(OWNER);
        vault.unpause();
        vm.prank(OPERATOR);
        vault.openEpoch(BUDGET);
        assertEq(vault.remainingBudget(), BUDGET, "budget restored");

        _originate(SELLER, 50_000e6, 370);
        vm.warp(block.timestamp + 1 days);
        _hitBid(50_000e6);
        assertEq(MIDNIGHT.credit(id, address(vault)), 50_000e6, "purchase possible on the new epoch");
    }

    function test_PausedVaultDoesNotQuote() public {
        _originate(SELLER, 100_000e6, 370);
        vm.warp(block.timestamp + 1 days);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);

        vm.prank(OWNER);
        vault.kill(); // pauses the vault

        vm.prank(SELLER);
        vm.expectRevert();
        MIDNIGHT.take(bid, "", 1_000e6, SELLER, SELLER, address(0), "");
    }

    // -------------------------------------------------------------------------
    // Withdrawal liquidity
    // -------------------------------------------------------------------------

    /// @dev Unmatured credit is not redeemable: it is the book cap that guarantees there is
    ///      enough left to serve depositors, not a queue.
    function test_WithdrawLimitedToLiquidPart() public {
        _originate(SELLER, 120_000e6, 370);
        vm.warp(block.timestamp + 1 days);
        _hitBid(110_000e6);

        uint256 liquid = vault.idleAssets() + vault.blueAssets();
        assertEq(vault.maxWithdraw(LP), liquid, "only the liquid sleeve is withdrawable");
        assertLt(vault.maxWithdraw(LP), vault.convertToAssets(vault.balanceOf(LP)), "the book locks the rest");

        vm.prank(LP);
        vault.withdraw(liquid, LP, LP);
        assertGt(vault.balanceOf(LP), 0, "the LP keeps shares against the book");
    }
}
