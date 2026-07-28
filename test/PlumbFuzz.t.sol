// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {TickLib} from "../src/interfaces/midnight/TickLib.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

/// @notice Vault invariants, exercised by fuzzing on a fork.
///
/// Unit tests check chosen scenarios; these check properties, on inputs I did not choose.
/// Four properties carry Plumb's economic safety:
///
///   1. Plumb never pays above its target price, whatever the rate and maturity.
///   2. The book cap is never crossed, whatever the sequence of buys.
///   3. An immediate deposit/withdraw round trip cannot create value.
///   4. A lot's marked value stays bounded by its face value and grows with time.
contract PlumbFuzzTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");

    PlumbVault vault;
    QuoteModule quote;

    uint256 tenorAtFork;

    function setUp() public {
        _forkSetUp();
        tenorAtFork = MATURITY - block.timestamp;

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
        _configure(900);
        vault.setBlueMarket(blueMarket());
        vault.setOperator(OPERATOR);
        vault.setRiskParams(6000, 200_000e6);
        vm.stopPrank();

        vm.prank(OPERATOR);
        vault.openEpoch(500_000e6);

        vm.startPrank(LP);
        IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);
        vault.deposit(200_000e6, LP);
        vm.stopPrank();
    }

    function _configure(uint256 rateBps) internal {
        quote.setMarketConfig(
            id,
            QuoteModule.MarketConfig({
                enabled: true,
                rateBps: uint16(rateBps),
                volSpreadBps: 0,
                skewBps: 0,
                minTenor: 1 days,
                maxTenor: 90 days,
                maxUnits: 400_000e6
            })
        );
    }

    // ---------------------------------------------------------------------
    // 1. The quote never exceeds the target
    // ---------------------------------------------------------------------

    /// @dev Property: the quoted tick is always strictly below the target price, and it is the
    ///      best possible — the next notch up would exceed it. Without the upper bound, Plumb
    ///      could be rounded *above* its target and buy at a loss; without the lower bound, it
    ///      would quote needlessly low and never get taken.
    function testFuzz_QuoteStaysUnderTargetAndIsTight(uint16 rateBps, uint256 elapsed) public {
        rateBps = uint16(bound(rateBps, quote.MIN_RATE_BPS(), quote.MAX_RATE_BPS()));
        // We advance time to sweep every admissible residual maturity.
        elapsed = bound(elapsed, 0, tenorAtFork - 1 days);
        vm.prank(OWNER);
        _configure(rateBps);
        vm.warp(block.timestamp + elapsed);

        uint8 spacing = MIDNIGHT.tickSpacing(id);
        uint256 remaining = MATURITY - block.timestamp;
        // The target is discounted at the *effective* rate, not the configured one: the Blue floor
        // may legitimately have raised it. What must never happen is the effective rate coming out
        // below the configured one — that would be the vault paying more than its own policy.
        uint256 effective = quote.effectiveRateBps(id);
        assertGe(effective, rateBps, "an adjustment can only raise the demanded rate");
        uint256 target = 1e18 - (effective * 1e18 * remaining) / (10_000 * 365 days);

        uint256 tick = quote.maxTick(id, MATURITY, spacing);
        assertLe(TickLib.tickToPrice(tick), target, "Plumb must never quote above its target");
        assertGt(TickLib.tickToPrice(tick + spacing), target, "the next notch must exceed: the quote is tight");
    }

    /// @dev Property: outside the rate bounds, the config is refused. A compromised owner cannot
    ///      move the price arbitrarily — the constants are immutable.
    function testFuzz_QuoteRefusesRateOutOfBounds(uint16 rateBps) public {
        vm.assume(rateBps < quote.MIN_RATE_BPS() || rateBps > quote.MAX_RATE_BPS());
        vm.prank(OWNER);
        vm.expectRevert(QuoteModule.RateOutOfBounds.selector);
        _configure(rateBps);
    }

    // ---------------------------------------------------------------------
    // 2. The book cap holds over any sequence of buys
    // ---------------------------------------------------------------------

    /// @dev Property: after an arbitrary sequence of buys — sizes and time spacing not chosen —
    ///      the book stays under `maxBookBps` of NAV. This is the killer risk identified from the
    ///      start: an entire book of stuck positions and zero liquidity.
    function testFuzz_BookCapHoldsOverAnySequence(uint128[4] memory sizes, uint32[4] memory gaps) public {
        for (uint256 i; i < 4; ++i) {
            uint256 units = bound(sizes[i], 1_000e6, 150_000e6);
            uint256 gap = bound(gaps[i], 0, 5 days);
            vm.warp(block.timestamp + gap);
            if (MATURITY - block.timestamp < 2 days) break;

            _tryBuy(units);

            // The invariant is re-read from public state, assuming nothing about the path taken.
            assertLe(vault.bookValue() * 10_000, vault.totalAssets() * vault.maxBookBps(), "the book exceeds its cap");
            assertLe(vault.bookValue(), vault.totalAssets(), "the book cannot exceed NAV");
        }
        // Without a completed buy, everything above is `0 <= X`.
        vm.assume(fills > 0);
    }

    /// @dev Property: a withdrawal never touches unmatured credit. The previous formulation —
    ///      `maxWithdraw <= idle + blue` — was true by construction: `maxWithdraw` is literally
    ///      defined as the minimum of those two terms. No input could falsify it, so it tested
    ///      nothing. The real property is behavioral: after a withdrawal as large as the vault
    ///      allows, the credit position must be intact.
    function testFuzz_WithdrawalsNeverTouchUnmaturedCredit(uint128 size, uint256 frac) public {
        _tryBuy(bound(size, 1_000e6, 150_000e6));
        vm.assume(fills > 0);

        uint256 bookBefore = vault.bookValue();
        (uint128 creditBefore,,) = MIDNIGHT.updatePositionView(midnightMarket(), id, address(vault));
        assertGt(creditBefore, 0, "there must be credit to protect");

        uint256 want = bound(frac, 1, vault.maxWithdraw(LP));
        vm.prank(LP);
        vault.withdraw(want, LP, LP);

        (uint128 creditAfter,,) = MIDNIGHT.updatePositionView(midnightMarket(), id, address(vault));
        assertEq(creditAfter, creditBefore, "a withdrawal gave up credit units");
        assertGe(vault.bookValue(), bookBefore, "the book was eaten into by a withdrawal");
    }

    /// @notice Number of buys actually executed since the start of the test.
    /// @dev A property checked on an empty book checks nothing. Tests that call `_tryBuy`
    ///      therefore require at least one completed buy.
    uint256 internal fills;

    /// @dev Buys if the market allows it. A fuzzed sequence will inevitably hit bounds —
    ///      exhausted budget, cap reached, no more collateral — and that is a success, not a
    ///      failure. But only those reasons are acceptable: any other revert is a real defect,
    ///      and swallowing it would make the test green no matter what. So we list what we
    ///      tolerate.
    function _tryBuy(uint256 units) internal {
        if (units > vault.remainingBudget()) return;
        if (units > vault.maxSingleFill()) return;

        try this.originateAndSell(units) {
            fills += 1;
        } catch (bytes memory err) {
            assertTrue(_isExpectedRefusal(err), "a buy failed for an unexpected reason");
        }
    }

    /// @dev Expected refusals: Plumb's caps, and Midnight's counters when a sequence replays an
    ///      already consumed budget.
    function _isExpectedRefusal(bytes memory err) internal pure returns (bool) {
        return _contains(err, PlumbVault.BookCapExceeded.selector) || _contains(err, PlumbVault.FillTooLarge.selector)
            || _contains(err, PlumbVault.TooManyMarkets.selector) || _contains(err, IMidnight.ConsumedUnits.selector)
            || _contains(err, IMidnight.AlreadyConsumed.selector)
            || _contains(err, IMidnight.TickNotAccessible.selector);
    }

    function _contains(bytes memory haystack, bytes4 needle) internal pure returns (bool) {
        if (haystack.length < 4) return false;
        for (uint256 i; i + 4 <= haystack.length; ++i) {
            if (
                haystack[i] == needle[0] && haystack[i + 1] == needle[1] && haystack[i + 2] == needle[2]
                    && haystack[i + 3] == needle[3]
            ) return true;
        }
        return false;
    }

    /// @dev Externalized to be `try`-able: the borrower originates, the seller resells to Plumb.
    function originateAndSell(uint256 units) external {
        require(msg.sender == address(this));
        _originate(SELLER, units, 1200);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        uint128 credit = MIDNIGHT.credit(id, SELLER);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", credit, SELLER, SELLER, address(0), "");
    }

    // ---------------------------------------------------------------------
    // 3. A round trip does not create value
    // ---------------------------------------------------------------------

    /// @dev Property: depositing then immediately withdrawing returns strictly less than the
    ///      stake. If the inequality flipped, an attacker would loop the vault to drain the other
    ///      depositors.
    ///
    ///      Fuzzing surfaced the exact reason it does not flip: a deposit is immediately pushed to
    ///      Blue, whose assets→shares conversion rounds down. The round trip thus returns a few
    ///      wei less than the stake, and `maxRedeem` already reflects that shortfall — hence the
    ///      capping below, which is not a workaround but the correct behavior: you cannot withdraw
    ///      value that Blue never credited.
    function testFuzz_RoundTripNeverMintsValue(uint256 assets) public {
        assets = bound(assets, 1e6, 500_000e6);
        deal(address(USDC), address(this), assets);
        IERC20Like(address(USDC)).approve(address(vault), assets);

        uint256 shares = vault.deposit(assets, address(this));
        uint256 redeemable = vault.maxRedeem(address(this));
        assertLe(redeemable, shares, "you cannot redeem more shares than you hold");

        uint256 back = vault.redeem(redeemable, address(this), address(this));
        assertLe(back, assets, "a round trip must never return more than the stake");
    }

    /// @dev Property: the rounding loss suffered by existing depositors on a deposit is
    ///      **bounded by a constant**, independent of the deposit size.
    ///
    ///      This is the invariant that really matters. Blue's rounding loses at most one Blue
    ///      share per transaction, whatever the amount: an attacker repeating the operation could
    ///      not amplify the leak, and would pay more gas each time than they extract. If the loss
    ///      were proportional, the vault could be looted in a loop.
    function testFuzz_DepositRoundingLossIsBoundedByConstant(uint256 assets) public {
        assets = bound(assets, 1e6, 500_000e6);
        uint256 navBefore = vault.totalAssets();

        deal(address(USDC), address(this), assets);
        IERC20Like(address(USDC)).approve(address(vault), assets);
        vault.deposit(assets, address(this));

        uint256 credited = vault.totalAssets() - navBefore;
        assertLe(credited, assets, "NAV cannot gain more than the deposit");
        // The shortfall is in wei of USDC, not a percentage of the deposit.
        assertGe(credited + 10, assets, "the rounding loss must stay constant, not proportional");
    }

    // ---------------------------------------------------------------------
    // 4. The mark stays bounded and monotone
    // ---------------------------------------------------------------------

    /// @dev Property: a lot's marked value never exceeds its face value — otherwise Plumb would
    ///      show a NAV higher than what it can collect at maturity — and grows with time.
    function testFuzz_MarkIsBoundedAndMonotone(uint128 size, uint32 step) public {
        _tryBuy(bound(size, 10_000e6, 100_000e6));
        (uint128 units,,,) = vault.book(id);
        vm.assume(units > 0);

        uint256 markBefore = vault.previewMark(id);
        assertLe(markBefore, units, "the marked value cannot exceed face value");

        uint256 gap = bound(step, 1, 30 days);
        vm.warp(block.timestamp + gap);

        uint256 markAfter = vault.previewMark(id);
        assertGe(markAfter, markBefore, "accretion must be monotone");
        assertLe(markAfter, units, "even after maturity, a lot is worth at most par");
    }
}
