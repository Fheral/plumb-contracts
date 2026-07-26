// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

interface IOracle {
    function price() external view returns (uint256);
}

/// @notice The borrower-default path — the gap identified in Phase 0.
///
/// Midnight does not default per position but per market: a borrower's bad debt is socialized
/// across all lenders via `lossFactor`, which trims everyone's `credit` pro rata. Plumb must take
/// that loss into its NAV immediately, without pushing it onto the next depositor, and without
/// charging a performance fee on the recovery that would follow.
contract PlumbDefaultTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");
    address LIQUIDATOR = makeAddr("LIQUIDATOR");

    PlumbVault vault;
    QuoteModule quote;

    function setUp() public {
        _forkSetUp();
        quote = new QuoteModule(OWNER);
        vault = new PlumbVault(address(USDC), address(MIDNIGHT), BLUE, address(quote), OWNER, FEES);

        vm.startPrank(OWNER);
        quote.setMarketConfig(
            id,
            QuoteModule.MarketConfig({
                enabled: true,
                rateBps: 900,
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
    }

    function test_BorrowerDefaultIsAbsorbedByNav() public {
        // Plumb buys the position of a lender in a hurry.
        _originate(SELLER, 100_000e6, 370);
        uint128 bought = MIDNIGHT.credit(id, SELLER);
        vm.warp(block.timestamp + 15 days);

        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", bought, SELLER, SELLER, address(0), "");

        (, uint128 paid,,) = vault.book(id);
        uint256 navBeforeDefault = vault.totalAssets();
        uint256 ppsBefore = vault.convertToAssets(1e18);

        // The borrower does not repay and their collateral collapses.
        // Two hours after maturity: the liquidation incentive factor has reached its maximum
        // (TIME_TO_MAX_LIF = 60 min), which is the state where a full seizure is consistent.
        vm.warp(MATURITY + 2 hours);
        uint256 spot = IOracle(ORACLE_WETH).price();
        vm.mockCall(ORACLE_WETH, abi.encodeWithSignature("price()"), abi.encode(spot / 200));

        uint128 collat = MIDNIGHT.collateral(id, BORROWER, 0) * 99 / 100;
        vm.prank(LIQUIDATOR);
        MIDNIGHT.liquidate(midnightMarket(), 0, collat, 0, BORROWER, true, LIQUIDATOR, address(0), "");

        assertGt(MIDNIGHT.lossFactor(id), 0, "the market must carry a loss");

        // Trap to remember: `credit()` returns the stored value, not the real one. Slashing is
        // lazy, it only applies at the next `updatePosition`. Any read of the book — here as in
        // the offchain monitoring — must go through `updatePositionView`.
        assertEq(MIDNIGHT.credit(id, address(vault)), bought, "the raw getter does not see the loss yet");
        (uint128 creditAfter,,) = MIDNIGHT.updatePositionView(midnightMarket(), id, address(vault));
        assertLt(creditAfter, bought, "Plumb's credit is trimmed");
        uint256 navAfter = vault.totalAssets();
        assertLt(navAfter, navBeforeDefault, "the loss must hit the NAV immediately");
        assertEq(vault.previewMark(id), creditAfter, "post-maturity, the book is worth the remaining credit");

        console2.log("Credit before default:", bought);
        console2.log("Credit after default :", creditAfter);
        console2.log("NAV before / after   :", navBeforeDefault, navAfter);

        // The written mark must say exactly the same thing as the view.
        vault.mark(midnightMarket());
        (uint128 unitsAfter, uint128 valueAfter,,) = vault.book(id);
        assertEq(unitsAfter, creditAfter, "units resynced to real credit");
        assertEq(MIDNIGHT.credit(id, address(vault)), creditAfter, "marking materializes the loss");
        assertEq(valueAfter, creditAfter, "surviving units valued at par");
        assertLt(valueAfter, paid, "Plumb lost money on this lot");

        // What was repaid is collectible right away. The rest waits: `withdrawable` is a reserve
        // shared by all the market's lenders, Plumb only draws what exists.
        uint256 recovered = vault.settle(midnightMarket());
        assertGt(recovered, 0, "the repaid portion is recoverable");
        (uint128 left,,,) = vault.book(id);
        assertEq(left, creditAfter - recovered, "the balance stays on the book, at par");

        // The loss is borne permanently by the existing shares.
        uint256 ppsAfter = vault.convertToAssets(1e18);
        assertLt(ppsAfter, ppsBefore, "the share price drops");
        assertEq(vault.balanceOf(FEES), 0, "no performance fee on a loss");
        assertLe(vault.maxWithdraw(LP), vault.idleAssets() + vault.blueAssets(), "only liquid value leaves");
    }

    /// @dev The high-water mark must forbid charging fees on the mere recovery of a loss:
    ///      without it, a loss followed by a rebound would be billed as performance.
    function test_NoFeeOnLossRecovery() public {
        _originate(SELLER, 100_000e6, 370);
        vm.warp(block.timestamp + 15 days);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        uint128 bought = MIDNIGHT.credit(id, SELLER);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", bought, SELLER, SELLER, address(0), "");

        // Two hours after maturity: the liquidation incentive factor has reached its maximum
        // (TIME_TO_MAX_LIF = 60 min), which is the state where a full seizure is consistent.
        vm.warp(MATURITY + 2 hours);
        uint256 spot = IOracle(ORACLE_WETH).price();
        vm.mockCall(ORACLE_WETH, abi.encodeWithSignature("price()"), abi.encode(spot / 200));
        uint128 collat = MIDNIGHT.collateral(id, BORROWER, 0) * 99 / 100;
        vm.prank(LIQUIDATOR);
        MIDNIGHT.liquidate(midnightMarket(), 0, collat, 0, BORROWER, true, LIQUIDATOR, address(0), "");

        vault.settle(midnightMarket());
        uint256 hwm = vault.highWaterMark();
        assertEq(vault.balanceOf(FEES), 0, "no fee on the loss");

        // One year of Blue yield: the NAV recovers, but not yet above the high-water mark.
        vm.warp(block.timestamp + 365 days);
        vm.prank(LP);
        vault.withdraw(1e6, LP, LP);
        assertEq(vault.highWaterMark(), hwm, "the high-water mark must not move until it is crossed");
    }
}
