// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {IMidnight, Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {IMorphoBlue, BlueLib} from "../src/interfaces/IMorphoBlue.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

/// @notice The "Blue out of liquidity" degradation path.
///
/// Plumb's idle capital sits on Morpho Blue. Nothing guarantees it can be withdrawn at the
/// desired moment: if Blue's borrowers have drawn everything, `withdraw` reverts. Two moments are
/// exposed — buying a lot (`onBuy` withdraws to pay) and a depositor withdrawal.
///
/// What these tests establish: in both cases Plumb fails cleanly, with no corrupted state and
/// no distorted NAV, and resumes operating as soon as liquidity returns.
contract PlumbLiquidityTest is MidnightForkBase {
    using BlueLib for IMorphoBlue;

    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");
    address BLUE_WHALE = makeAddr("BLUE_WHALE");

    PlumbVault vault;
    QuoteModule quote;
    IMorphoBlue blue = IMorphoBlue(BLUE);

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
    }

    /// @dev Drains the Blue market: a whale deposits collateral and borrows everything available.
    function _drainBlue() internal returns (uint256 borrowed) {
        deal(WETH, BLUE_WHALE, 20_000e18);
        vm.startPrank(BLUE_WHALE);
        IERC20Like(WETH).approve(BLUE, type(uint256).max);
        IERC20Like(address(USDC)).approve(BLUE, type(uint256).max);
        blue.supplyCollateral(blueMarket(), 20_000e18, BLUE_WHALE, "");

        // Leave 1 USDC: the market is dry without being in an artificial edge state.
        borrowed = blue.marketLiquidity(blueMarket()) - 1e6;
        blue.borrow(blueMarket(), borrowed, 0, BLUE_WHALE, BLUE_WHALE);
        vm.stopPrank();

        assertLe(blue.marketLiquidity(blueMarket()), 1e6 + 1, "Blue must be dry");
    }

    function _rehydrateBlue(uint256 amount) internal {
        deal(address(USDC), BLUE_WHALE, amount);
        vm.prank(BLUE_WHALE);
        blue.repay(blueMarket(), amount, 0, BLUE_WHALE, "");
    }

    // ---------------------------------------------------------------------

    /// @notice Blue dry: the buy fails, but the failure is total and clean.
    /// @dev This is the delicate point: `onBuy` records the lot in the book *before* withdrawing
    ///      from Blue. If the withdrawal reverts, the whole `take` must revert with it — otherwise
    ///      Plumb would carry a position it never paid for, and its NAV would be wrong.
    function test_BuyRevertsCleanlyWhenBlueIsDry() public {
        _originate(SELLER, 100_000e6, 370);
        uint128 bought = MIDNIGHT.credit(id, SELLER);
        vm.warp(block.timestamp + 15 days);

        _drainBlue();

        uint256 navBefore = vault.totalAssets();
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);

        vm.prank(SELLER);
        vm.expectRevert();
        MIDNIGHT.take(bid, "", bought, SELLER, SELLER, address(0), "");

        // No trace: no ghost lot in the book, no credit acquired without consideration.
        (uint128 units, uint128 value,,) = vault.book(id);
        assertEq(units, 0, "no lot may remain in the book");
        assertEq(value, 0, "no ghost value");
        assertEq(vault.activeMarkets().length, 0, "no active market");
        assertEq(MIDNIGHT.credit(id, address(vault)), 0, "Plumb acquired no credit");
        assertEq(vault.totalAssets(), navBefore, "NAV is unchanged");
        assertEq(MIDNIGHT.credit(id, SELLER), bought, "the seller keeps their position");
    }

    /// @notice As soon as liquidity returns, buying works again — no intervention required.
    /// @dev The offer never needed to be re-posted: its validity derives from on-chain state, it
    ///      never stopped existing. That is the concrete benefit of the vault-as-ratifier.
    function test_BuyResumesOnceLiquidityReturns() public {
        _originate(SELLER, 100_000e6, 370);
        uint128 bought = MIDNIGHT.credit(id, SELLER);
        vm.warp(block.timestamp + 15 days);

        _drainBlue();
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        vm.expectRevert();
        MIDNIGHT.take(bid, "", bought, SELLER, SELLER, address(0), "");

        _rehydrateBlue(200_000e6);

        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", bought, SELLER, SELLER, address(0), "");
        (uint128 units,,,) = vault.book(id);
        assertEq(units, bought, "the lot is acquired without re-posting the offer");
    }

    /// @notice Blue dry while Plumb holds a lot: withdrawals are bounded, not blocked.
    /// @dev `maxWithdraw` must tell the truth. A depositor asking for more than the real liquid
    ///      balance must be refused by the ERC-4626 bound, not by an opaque revert from Blue.
    function test_WithdrawIsBoundedByBlueLiquidityNotByPlumbBalance() public {
        _originate(SELLER, 100_000e6, 370);
        uint128 bought = MIDNIGHT.credit(id, SELLER);
        vm.warp(block.timestamp + 15 days);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", bought, SELLER, SELLER, address(0), "");

        uint256 posBefore = vault.blueAssets();
        _drainBlue();

        // Plumb's Blue position has not moved; what collapsed is its withdrawability.
        assertApproxEqRel(vault.blueAssets(), posBefore, 1e15, "the Blue position still counts toward NAV");
        uint256 limit = vault.maxWithdraw(LP);
        assertLt(limit, posBefore, "the withdrawal limit must collapse with liquidity");
        console2.log("Blue position / possible withdrawal:", posBefore, limit);

        // Beyond the limit: an explicit ERC-4626 refusal, not an obscure revert from Blue.
        vm.prank(LP);
        vm.expectRevert();
        vault.withdraw(limit + 1e6, LP, LP);

        // At the limit: it goes through.
        vm.prank(LP);
        vault.withdraw(limit, LP, LP);
        assertApproxEqAbs(vault.maxWithdraw(LP), 0, 1e6, "liquid balance is exhausted");

        // The rest of the NAV is not lost, only immobilized.
        assertGt(vault.totalAssets(), 0, "NAV remains");
        assertGt(vault.balanceOf(LP), 0, "the depositor keeps shares on the immobilized part");
    }

    /// @notice Settlement at maturity does not depend on Blue: Plumb collects even with a dry market.
    /// @dev Important for the worst-case scenario: Blue frozen *and* maturity reached. The money
    ///      comes in from Midnight, and redepositing on Blue (a `supply`) can never lack liquidity.
    function test_SettleWorksWhileBlueIsDry() public {
        _originate(SELLER, 100_000e6, 370);
        uint128 bought = MIDNIGHT.credit(id, SELLER);
        vm.warp(block.timestamp + 15 days);
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", bought, SELLER, SELLER, address(0), "");

        _drainBlue();
        vm.warp(MATURITY + 1);

        uint256 recovered = vault.settle(midnightMarket());
        assertGt(recovered, 0, "settlement must go through despite Blue being dry");
        console2.log("Settled despite Blue being dry:", recovered);
    }

    /// @notice The kill switch works while Blue is dry.
    /// @dev `kill()` touches neither Blue nor liquidity: it only writes a counter on Midnight.
    ///      That is deliberate — the emergency brake must not depend on any external liquidity.
    function test_KillSwitchWorksWhenBlueIsDry() public {
        _originate(SELLER, 100_000e6, 370);
        uint128 bought = MIDNIGHT.credit(id, SELLER);
        vm.warp(block.timestamp + 15 days);

        _drainBlue();
        vm.prank(OPERATOR);
        vault.kill();

        assertEq(vault.remainingBudget(), 0, "the budget is exhausted");

        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        vm.expectRevert();
        MIDNIGHT.take(bid, "", bought, SELLER, SELLER, address(0), "");
    }
}
