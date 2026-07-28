// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface IOracle2 {
    function price() external view returns (uint256);
}

/// @notice The "someone calls a function they should not" threat model.
///
/// The rest of the suite tests the economic path: the market goes bad, the borrower defaults,
/// Blue runs dry. This file tests the adversary — forged offer fields, unauthorized calls, value
/// extraction around a NAV jump, degenerate book states.
contract PlumbAdversarialTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");
    address LIQUIDATOR = makeAddr("LIQUIDATOR");
    address ATTACKER = makeAddr("ATTACKER");

    PlumbVault vault;
    QuoteModule quote;

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
                rateBps: 900,
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
        vault.openEpoch(300_000e6);

        vm.startPrank(LP);
        IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);
        vault.deposit(200_000e6, LP);
        vm.stopPrank();

        deal(address(USDC), LIQUIDATOR, 1_000_000e6);
        vm.prank(LIQUIDATOR);
        IERC20Like(address(USDC)).approve(address(MIDNIGHT), type(uint256).max);

        deal(address(USDC), ATTACKER, 5_000_000e6);
        vm.prank(ATTACKER);
        IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);
    }

    function _buy(uint256 units) internal returns (uint128 bought) {
        _originate(SELLER, units, 1200);
        bought = MIDNIGHT.credit(id, SELLER);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", bought, SELLER, SELLER, address(0), "");
    }

    // -------------------------------------------------------------------------
    // Ratification: every field, one by one
    // -------------------------------------------------------------------------

    /// @notice Any offer deviating from the policy must be rejected, field by field.
    /// @dev The vault is its own ratifier: this function *is* the system's security. A condition
    ///      that could be removed without turning a test red is not security, it is a comment. So
    ///      we cross every one of them.
    function test_RatificationRejectsEveryMalformedField() public {
        _originate(SELLER, 50_000e6, 1200);
        uint128 credit = MIDNIGHT.credit(id, SELLER);

        _expectRejected(_mutate(0), PlumbVault.OfferNotABid.selector, credit);
        _expectRejected(_mutate(1), PlumbVault.OfferWrongMaker.selector, credit);
        _expectRejected(_mutate(2), PlumbVault.OfferWrongRatifier.selector, credit);
        _expectRejected(_mutate(3), PlumbVault.OfferWrongCallback.selector, credit);
        _expectRejected(_mutate(4), PlumbVault.OfferReceiverNotZero.selector, credit);
        _expectRejected(_mutate(5), PlumbVault.OfferReduceOnly.selector, credit);
        _expectRejected(_mutate(6), PlumbVault.OfferWrongGroup.selector, credit);
        _expectRejected(_mutate(7), PlumbVault.OfferWrongBudget.selector, credit); // maxUnits
        _expectRejected(_mutate(8), PlumbVault.OfferWrongBudget.selector, credit); // maxAssets
        _expectRejected(_mutate(9), PlumbVault.OfferFeeCapTooHigh.selector, credit);
        _expectRejected(_mutate(10), PlumbVault.OfferWrongMarket.selector, credit); // loanToken
    }

    function _mutate(uint256 which) internal view returns (Offer memory o) {
        o = vault.buildBid(midnightMarket(), type(uint256).max);
        if (which == 0) o.buy = false;
        else if (which == 1) o.maker = SELLER;
        else if (which == 2) o.ratifier = address(ratifier);
        else if (which == 3) o.callback = address(0);
        else if (which == 4) o.receiverIfMakerIsSeller = SELLER;
        else if (which == 5) o.reduceOnly = true;
        else if (which == 6) o.group = keccak256("another group");
        else if (which == 7) o.maxUnits = o.maxUnits + 1;
        else if (which == 8) o.maxAssets = 1;
        else if (which == 9) o.continuousFeeCap = type(uint256).max;
        else if (which == 10) o.market.loanToken = WETH;
    }

    /// @dev We query `isRatified` directly rather than going through `take`. Midnight itself
    ///      rejects some fields *before* calling the ratifier — a non-zero
    ///      `receiverIfMakerIsSeller` on a buy offer exits with `UnusedReceiverMustBeZero()`
    ///      without ever reaching Plumb. Going through `take` would make the assertion ambiguous:
    ///      we would not know which of the two barriers bit, and Plumb's barrier could be removed
    ///      without a test turning red. It is Plumb's policy being tested here, not Midnight's.
    function _expectRejected(Offer memory o, bytes4 selector, uint128) internal {
        vm.expectRevert(selector);
        vault.isRatified(o, "", SELLER);
    }

    /// @dev The counterpart: end to end, through Midnight, the rejection is effective.
    function _expectRejectedEndToEnd(Offer memory o, bytes4 selector, uint128 units) internal {
        vm.prank(SELLER);
        try MIDNIGHT.take(o, "", units, SELLER, SELLER, address(0), "") {
            fail();
        } catch (bytes memory err) {
            assertTrue(_contains(err, selector), "wrong rejection reason");
        }
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

    /// @notice The tick exactly at the target must be accepted — otherwise Plumb never quotes.
    /// @dev The indispensable counterpart of `test_CannotOverpay`: without it, turning the
    ///      ratification's `<=` into a strict `<` would pass every test while breaking the product.
    function test_TickExactlyAtTargetIsAccepted() public {
        uint128 bought = _buy(50_000e6);
        assertEq(MIDNIGHT.credit(id, address(vault)), bought, "the bid at the target must be takeable");
    }

    /// @notice An offer broadcast then made too generous by a policy change dies on its own,
    ///         with no cancellation transaction.
    /// @dev This is the central thesis of the vault-as-ratifier architecture. It was asserted in a
    ///      comment and verified nowhere.
    function test_StaleOfferDiesWhenPolicyTightens() public {
        _originate(SELLER, 50_000e6, 1200);
        uint128 credit = MIDNIGHT.credit(id, SELLER);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);

        // Plumb now demands 20% instead of 9%: the target price drops, so the target tick does too.
        vm.prank(OWNER);
        quote.setMarketConfig(
            id,
            QuoteModule.MarketConfig({
                enabled: true,
                rateBps: 2000,
                volSpreadBps: 0,
                skewBps: 0,
                minTenor: 1 days,
                maxTenor: 90 days,
                maxUnits: 500_000e6
            })
        );

        _expectRejectedEndToEnd(bid, PlumbVault.OfferTickTooHigh.selector, credit);
    }

    // -------------------------------------------------------------------------
    // Access control
    // -------------------------------------------------------------------------

    /// @notice `onBuy` writes the book and withdraws from Blue. No one but Midnight calls it.
    function test_OnBuyRejectsDirectCall() public {
        vm.prank(ATTACKER);
        vm.expectRevert(PlumbVault.NotMidnight.selector);
        vault.onBuy(id, midnightMarket(), 1e6, 1e6, 0, address(vault), "");
    }

    /// @notice Even Midnight itself cannot make Plumb buy on behalf of a third party.
    function test_OnBuyRejectsForeignBuyer() public {
        vm.prank(address(MIDNIGHT));
        vm.expectRevert(PlumbVault.NotSelf.selector);
        vault.onBuy(id, midnightMarket(), 1e6, 1e6, 0, ATTACKER, "");
    }

    function test_GovernanceIsClosedToOutsiders() public {
        vm.startPrank(ATTACKER);
        vm.expectRevert(PlumbVault.NotOperator.selector);
        vault.openEpoch(1e12);
        vm.expectRevert(PlumbVault.NotOperator.selector);
        vault.kill();
        vm.expectRevert(PlumbVault.NotOperator.selector);
        vault.supplyToBlue(1e6);
        vm.expectRevert(PlumbVault.NotOperator.selector);
        vault.withdrawFromBlue(1e6);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vault.setRiskParams(10_000, 1e12);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vault.setOperator(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vault.setFee(0, ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ATTACKER));
        vault.setBlueMarket(blueMarket());
        vm.stopPrank();
    }

    /// @notice Revoking the operator really strips their powers.
    function test_RevokedOperatorIsPowerless() public {
        vm.prank(OWNER);
        vault.setOperator(address(0));
        vm.prank(OPERATOR);
        vm.expectRevert(PlumbVault.NotOperator.selector);
        vault.openEpoch(1e12);
        // The owner remains entitled: the revocation cannot doom the vault.
        vm.prank(OWNER);
        vault.openEpoch(1e12);
    }

    /// @notice The ownership transfer really is two-step, and the old owner loses control.
    function test_OwnershipTransferIsTwoStep() public {
        address NEW = makeAddr("NEW_OWNER");
        vm.prank(OWNER);
        vault.transferOwnership(NEW);
        assertEq(vault.owner(), OWNER, "the owner does not change before acceptance");

        vm.prank(NEW);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW));
        vault.setRiskParams(5000, 1e12);

        vm.prank(NEW);
        vault.acceptOwnership();
        assertEq(vault.owner(), NEW, "the owner changes after acceptance");

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        vault.setOperator(ATTACKER);
    }

    // -------------------------------------------------------------------------
    // Pause, independently of the kill switch
    // -------------------------------------------------------------------------

    /// @notice The pause alone is enough to stop quoting, budget intact.
    /// @dev `kill()` does two things — exhaust the budget and pause. Testing the kill switch thus
    ///      does not test the pause: the observed revert comes from Midnight. We reopen an epoch
    ///      to restore the budget and isolate the pause.
    function test_PauseAloneStopsQuoting() public {
        _originate(SELLER, 50_000e6, 1200);
        uint128 credit = MIDNIGHT.credit(id, SELLER);

        vm.prank(OPERATOR);
        vault.kill();
        vm.prank(OPERATOR);
        vault.openEpoch(300_000e6); // budget restored, pause kept
        assertTrue(vault.paused(), "the vault must remain paused");
        assertEq(vault.remainingBudget(), 300_000e6, "the budget must be intact");

        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        _expectRejectedEndToEnd(bid, Pausable.EnforcedPause.selector, credit);
    }

    /// @notice Vault paused: no more entering, but always exiting.
    /// @dev The asymmetry is the point. An emergency brake that locked depositors in would be
    ///      worse than no brake at all.
    function test_PauseBlocksEntryNotExit() public {
        vm.prank(OPERATOR);
        vault.kill();

        vm.prank(ATTACKER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(1_000e6, ATTACKER);

        uint256 before = IERC20Like(address(USDC)).balanceOf(LP);
        vm.prank(LP);
        vault.withdraw(50_000e6, LP, LP);
        assertEq(IERC20Like(address(USDC)).balanceOf(LP) - before, 50_000e6, "exiting stays possible while paused");
    }

    // -------------------------------------------------------------------------
    // Slashing before maturity — the pro-rata branch
    // -------------------------------------------------------------------------

    /// @notice A loss taken before maturity is passed through pro rata, then accretion resumes
    ///         on the surviving units.
    /// @dev The existing default test sits *after* maturity, where `previewMark` returns `units`
    ///      directly: the post-slashing accretion branch was never executed. Yet that is where a
    ///      scaling error would durably overstate the NAV.
    function test_SlashingBeforeMaturityIsProRataThenAccretes() public {
        uint128 bought = _buy(100_000e6);
        (uint128 units0, uint128 value0,,) = vault.book(id);
        assertEq(units0, bought, "the lot is in the book");
        assertLt(value0, units0, "bought below par");

        _crashCollateral(99);

        (uint128 creditAfter,,) = MIDNIGHT.updatePositionView(midnightMarket(), id, address(vault));
        assertLt(creditAfter, bought, "the credit must have been trimmed");
        assertGt(creditAfter, 0, "partial slashing expected, not total");

        // We are before maturity: the value must be the pro-rata amount, not par.
        uint256 expectedValue = (uint256(value0) * creditAfter) / units0;
        uint256 seen = vault.previewMark(id);
        assertApproxEqAbs(seen, expectedValue, 1, "the loss must be applied at the exact pro-rata");
        assertLt(seen, creditAfter, "still below par before maturity");

        // The write must say exactly what the view said.
        vault.mark(midnightMarket());
        (uint128 units1, uint128 value1,,) = vault.book(id);
        assertEq(units1, creditAfter, "units resynchronized");
        assertApproxEqAbs(value1, expectedValue, 1, "view and write must coincide");

        // Then accretion resumes, on the surviving units only.
        uint256 mid = block.timestamp + (MATURITY - block.timestamp) / 2;
        vm.warp(mid);
        uint256 later = vault.previewMark(id);
        assertGt(later, value1, "accretion must resume");
        assertLt(later, creditAfter, "without ever exceeding the surviving face value");
    }

    /// @notice A fully wiped market must release its slot.
    /// @dev Otherwise it forever occupies one of the 8 `MAX_MARKETS` slots, and `bookValue()`
    ///      keeps paying an external call per deposit and per withdrawal for a nil position.
    ///      `settle` cannot clean it up: it requires `units > 0`.
    function test_FullyWipedMarketReleasesItsSlot() public {
        _buy(100_000e6);
        assertEq(vault.activeMarkets().length, 1, "one active market");

        // Total socialized loss: Plumb's `credit` drops to zero. A real liquidation on this
        // market always leaves a residue — so we mock Midnight's return directly, because it is
        // the `credit == 0` branch of `_mark` we want to cross, and it is reachable as soon as bad
        // debt absorbs the market's entire face value.
        vm.mockCall(
            address(MIDNIGHT),
            abi.encodeWithSelector(IMidnight.updatePosition.selector),
            abi.encode(uint128(0), uint128(0), uint128(0))
        );

        vault.mark(midnightMarket());
        vm.clearMockedCalls();
        (uint128 units,,,) = vault.book(id);
        assertEq(units, 0, "no units left");
        assertEq(vault.bookValue(), 0, "no value left");
        assertEq(vault.activeMarkets().length, 0, "a wiped market must release its slot");
    }

    function _crashCollateral(uint256 pct) internal {
        // Two hours after maturity the incentive factor is at its maximum; we then go back
        // before maturity to test the pre-maturity branch.
        uint256 t = block.timestamp;
        vm.warp(MATURITY + 2 hours);
        uint256 spot = IOracle2(ORACLE_WETH).price();
        vm.mockCall(ORACLE_WETH, abi.encodeWithSignature("price()"), abi.encode(spot / 500));
        uint128 collat = uint128((uint256(MIDNIGHT.collateral(id, BORROWER, 0)) * pct) / 100);
        vm.prank(LIQUIDATOR);
        MIDNIGHT.liquidate(midnightMarket(), 0, collat, 0, BORROWER, true, LIQUIDATOR, address(0), "");
        vm.clearMockedCalls();
        vm.warp(t);
    }

    function _repayAll() internal {
        deal(address(USDC), BORROWER, 2_000_000e6);
        vm.prank(BORROWER);
        IERC20Like(address(USDC)).approve(address(MIDNIGHT), type(uint256).max);
        uint128 d = MIDNIGHT.debt(id, BORROWER);
        if (d == 0) return;
        vm.prank(BORROWER);
        MIDNIGHT.repay(midnightMarket(), d, BORROWER, address(0), "");
    }

    // -------------------------------------------------------------------------
    // Fees: the amount, not just the existence
    // -------------------------------------------------------------------------

    /// @notice Fees are exactly `perfFeeBps` of the performance above the high-water mark.
    /// @dev The suite observed that fees were charged; it never checked how much. A rate ten
    ///      times too high would have gone unnoticed.
    function test_FeeIsExactlyPerfFeeBpsOfGainAboveHighWaterMark() public {
        _buy(100_000e6);
        vm.warp(block.timestamp + 30 days);

        uint256 supply = vault.totalSupply();
        uint256 hwm = vault.highWaterMark();
        uint256 pps = (vault.totalAssets() * 1e18) / supply;
        assertGt(pps, hwm, "there must be performance to charge");

        uint256 gain = ((pps - hwm) * supply) / 1e18;
        uint256 expectedFee = (gain * vault.perfFeeBps()) / 10_000;

        vault.mark(midnightMarket()); // does not touch fees
        vm.prank(LP);
        vault.withdraw(1e6, LP, LP); // triggers `_accrueFee`

        uint256 feeValue = vault.convertToAssets(vault.balanceOf(FEES));
        assertApproxEqAbs(feeValue, expectedFee, 2, "fees differ from the announced rate");
    }

    /// @notice The high-water mark does not rise without a single wei of fees being charged.
    /// @dev Otherwise the performance slips under the radar for good: raising the mark without
    ///      charging removes that gain from the fee base forever. Repeated every block on
    ///      sub-unit gains, this deprives the recipient of their fees at no cost to the attacker
    ///      but a little gas.
    function test_HighWaterMarkRisesOnlyWhenFeesAreActuallyCharged() public {
        uint256 hwmBefore = vault.highWaterMark();
        uint256 feeSharesBefore = vault.balanceOf(FEES);

        // A one-wei gain: too small to produce even a single fee share.
        deal(address(USDC), address(vault), vault.idleAssets() + 1);
        vm.prank(LP);
        vault.withdraw(1e6, LP, LP);

        assertEq(vault.balanceOf(FEES), feeSharesBefore, "a one-wei gain cannot be worth a share");
        assertEq(vault.highWaterMark(), hwmBefore, "high-water mark raised without charging");
    }

    /// @notice The bounds of `setFee` are real.
    function test_SetFeeIsBounded() public {
        // Bound read before the `expectRevert`s: an external call nested in the argument list
        // would consume the pending revert expectation.
        uint256 max = vault.MAX_PERF_FEE_BPS();
        vm.startPrank(OWNER);
        vm.expectRevert(PlumbVault.FeeTooHigh.selector);
        vault.setFee(max + 1, FEES);
        vm.expectRevert(PlumbVault.ZeroAddress.selector);
        vault.setFee(1000, address(0));
        vault.setFee(max, FEES); // the exact bound passes
        vm.stopPrank();
        assertEq(vault.perfFeeBps(), max);
    }

    // -------------------------------------------------------------------------
    // Value extraction around a NAV jump
    // -------------------------------------------------------------------------

    /// @notice A deposit followed by a withdrawal, bracketing a settlement, must earn nothing.
    /// @dev The flash-loan scenario: if an early settlement made the NAV jump at once, a huge
    ///      capital entering just before and exiting just after would capture nearly all of it at
    ///      the expense of existing depositors. We measure both: what the attacker walks away
    ///      with, and what the share price does during the operation.
    function test_SandwichingASettlementExtractsNothing() public {
        _buy(100_000e6);
        vm.warp(block.timestamp + 20 days);

        // An early repayment makes part of the face value collectible before maturity.
        deal(address(USDC), BORROWER, 2_000_000e6);
        vm.prank(BORROWER);
        IERC20Like(address(USDC)).approve(address(MIDNIGHT), type(uint256).max);
        uint128 d = MIDNIGHT.debt(id, BORROWER);
        vm.prank(BORROWER);
        MIDNIGHT.repay(midnightMarket(), d / 2, BORROWER, address(0), "");

        uint256 withdrawable = MIDNIGHT.withdrawable(id);
        console2.log("withdrawable before maturity:", withdrawable);

        // We first materialize the accrued performance fees: without this the share price would
        // drop during the operation for a reason unrelated to the sandwich, and the measurement
        // would be skewed by the fee recipient's legitimate dilution.
        vm.prank(LP);
        vault.withdraw(1e6, LP, LP);

        uint256 ppsBefore = vault.convertToAssets(1e18);
        uint256 stake = 2_000_000e6;

        vm.prank(ATTACKER);
        vault.deposit(stake, ATTACKER);
        vault.settle(midnightMarket());
        uint256 redeemable = vault.maxRedeem(ATTACKER);
        vm.prank(ATTACKER);
        uint256 out = vault.redeem(redeemable, ATTACKER, ATTACKER);

        console2.log("stake / recovered:", stake, out);
        assertLe(out, stake, "a sandwich around a settlement must earn nothing");
        assertGe(vault.convertToAssets(1e18), ppsBefore, "existing LPs must not be diluted");
    }

    /// @notice A buy larger than the NAV is refused cleanly, not by an arithmetic panic.
    /// @dev `onBuy` computes `totalAssets() - buyerAssets`: if the lot exceeds the NAV, the
    ///      subtraction overflows. The refusal must stay readable.
    function test_BuyLargerThanNavIsRefusedCleanly() public {
        vm.prank(OWNER);
        vault.setRiskParams(10_000, type(uint128).max);
        vm.prank(OPERATOR);
        vault.openEpoch(type(uint128).max);

        _originate(SELLER, 400_000e6, 1200);
        uint128 credit = MIDNIGHT.credit(id, SELLER);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);

        vm.prank(SELLER);
        try MIDNIGHT.take(bid, "", credit, SELLER, SELLER, address(0), "") {
            fail();
        } catch (bytes memory err) {
            assertTrue(
                _contains(err, PlumbVault.BookCapExceeded.selector),
                "a buy above the NAV must revert with BookCapExceeded, not a panic"
            );
        }
    }
}
