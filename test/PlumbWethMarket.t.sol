// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MidnightForkBase, IERC20Like, AlwaysRatifier} from "./MidnightForkBase.t.sol";
import {IMidnight, Market, CollateralParams, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {TickLib as TickLibView} from "../src/interfaces/midnight/TickLib.sol";
import {BlueMarketParams} from "../src/interfaces/IMorphoBlue.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

/// @dev Fixed-price oracle for the test market's collateral. Midnight reads Morpho-style
///      `price()` scaled by 1e36: loanAmount = collateralAmount * price / 1e36.
contract FixedOracle {
    uint256 public immutable price;

    constructor(uint256 price_) {
        price = price_;
    }
}

/// @notice The full lifecycle on a market whose loan asset is NOT USDC.
///
///         One vault per loan asset is the deployment model; this test proves the contract holds
///         its side of that bargain — no hidden 6-decimals assumption anywhere in quoting,
///         ratification, accounting or settlement. Amounts are 18-decimals WETH throughout, and
///         the collateral (USDC) sits on the other side of the decimal gap, so any misplaced
///         scaling factor surfaces as a broken health check or a wildly wrong price.
contract PlumbWethMarketTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");

    PlumbVault vault;
    QuoteModule quote;
    FixedOracle oracle;
    bytes32 wid;

    uint16 constant RATE_BPS = 900;
    uint256 constant WETH_MATURITY = 1790208000; // same date as the USDC fixture, 2026-09-24
    uint128 constant BUDGET = 100e18;

    function setUp() public {
        _forkSetUp();

        // 1 USDC = 0.00025 WETH (ETH at 4000). Scale: 2.5e14 wei per 1e6 collateral units.
        oracle = new FixedOracle(2.5e14 * 1e36 / 1e6);
        wid = MIDNIGHT.touchMarket(wethMarket());

        quote = new QuoteModule(OWNER);
        vault = new PlumbVault(
            "Plumb Exit Liquidity WETH",
            "plWETH",
            WETH,
            address(MIDNIGHT),
            BLUE,
            address(quote),
            OWNER,
            FEES,
            type(uint256).max
        );

        vm.startPrank(OWNER);
        quote.setVault(address(vault));
        quote.setMarketConfig(
            wid,
            QuoteModule.MarketConfig({
                enabled: true,
                rateBps: RATE_BPS,
                volSpreadBps: 0,
                skewBps: 0,
                minTenor: 1 days,
                maxTenor: 90 days,
                maxUnits: 200e18
            })
        );
        // The USDC fixture market is also enabled so that `test_RejectsForeignLoanToken` gets
        // past the quote config and fails on the loan-token check, which is the one under test.
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
        vault.setBlueMarket(blueWethMarket());
        vault.setOperator(OPERATOR);
        vault.setRiskParams(6000, 80e18);
        vm.stopPrank();

        vm.prank(OPERATOR);
        vault.openEpoch(BUDGET);

        deal(WETH, LP, 1000e18);
        deal(WETH, SELLER, 1000e18);
        deal(address(USDC), BORROWER, 100_000_000e6);

        vm.startPrank(LP);
        IERC20Like(WETH).approve(address(vault), type(uint256).max);
        vault.deposit(50e18, LP);
        vm.stopPrank();

        vm.startPrank(SELLER);
        IERC20Like(WETH).approve(address(MIDNIGHT), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(BORROWER);
        IERC20Like(address(USDC)).approve(address(MIDNIGHT), type(uint256).max);
        MIDNIGHT.supplyCollateral(wethMarket(), 0, 90_000_000e6, BORROWER);
        vm.stopPrank();
    }

    /// @dev Idle-capital parking for the WETH vault: the canonical WETH/wstETH Blue market on
    ///      Base (~3.6k WETH supplied at the pinned block).
    function blueWethMarket() internal pure returns (BlueMarketParams memory) {
        return BlueMarketParams({
            loanToken: WETH,
            collateralToken: 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452,
            oracle: 0x4A11590e5326138B514E08A9B52202D42077Ca65,
            irm: BLUE_IRM,
            lltv: 0.945e18
        });
    }

    function wethMarket() internal view returns (Market memory m) {
        CollateralParams[] memory cps = new CollateralParams[](1);
        cps[0] = CollateralParams(address(USDC), 0.86e18, 0.3e18, address(oracle));
        m = Market({
            chainId: 8453,
            midnight: address(MIDNIGHT),
            loanToken: WETH,
            collateralParams: cps,
            maturity: WETH_MATURITY,
            rcfThreshold: 3e9,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _originateWeth(address lender, uint256 units, uint256 rateBps) internal {
        uint256 tenor = WETH_MATURITY - block.timestamp;
        uint256 price = 1e18 - (rateBps * 1e18 * tenor) / (10_000 * 365 days);
        uint8 spacing = MIDNIGHT.tickSpacing(wid);
        uint256 t = TickLibView.priceToTick(price, spacing);
        if (TickLibView.tickToPrice(t) > price) t -= spacing;
        Offer memory o = Offer({
            market: wethMarket(),
            buy: false,
            maker: BORROWER,
            start: 0,
            expiry: type(uint256).max,
            tick: t,
            group: keccak256(abi.encode("weth-origination", block.timestamp, units)),
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

    function test_FullLifecycleWeth() public {
        // The virtual offset is a fixed six, whatever the asset carries: the share is always the
        // asset's decimals plus six, so an 18-decimal asset gives 24-decimal shares. Uniform by
        // choice — one rule to reason about, rather than an offset that depends on the token.
        assertEq(vault.decimals(), 24, "share decimals are the asset's plus the offset");
        assertApproxEqAbs(vault.totalAssets(), 50e18, 2, "NAV in wei, cash parked on Blue");
        assertApproxEqAbs(vault.blueAssets(), 50e18, 2, "supplied to Blue on deposit");

        // A lender enters at 3.7%, then wants out 15 days later.
        _originateWeth(SELLER, 20e18, 370);
        uint128 sellerCredit = MIDNIGHT.credit(wid, SELLER);
        assertEq(sellerCredit, 20e18, "credit in 18-decimals units");
        vm.warp(block.timestamp + 15 days);

        uint256 navBefore = vault.totalAssets();
        Offer memory bid = vault.buildBid(wethMarket(), type(uint256).max);
        uint256 before = IERC20Like(WETH).balanceOf(SELLER);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", sellerCredit, SELLER, SELLER, address(0), "");
        uint256 proceeds = IERC20Like(WETH).balanceOf(SELLER) - before;

        // The discount is a few percent annualized, not a decimals-shifted number.
        assertGt(proceeds, 19e18, "seller exits near par");
        assertLt(proceeds, 20e18, "but at a discount");
        assertEq(MIDNIGHT.credit(wid, address(vault)), sellerCredit, "Plumb carries the claim");
        assertApproxEqRel(vault.totalAssets(), navBefore, 1e15, "NAV unchanged on purchase");

        // At maturity the borrower repays, Plumb collects par.
        vm.warp(WETH_MATURITY + 1);
        deal(WETH, BORROWER, 100e18);
        vm.startPrank(BORROWER);
        IERC20Like(WETH).approve(address(MIDNIGHT), type(uint256).max);
        MIDNIGHT.repay(wethMarket(), MIDNIGHT.debt(wid, BORROWER), BORROWER, address(0), "");
        vm.stopPrank();

        vault.settle(wethMarket());
        assertEq(vault.activeMarkets().length, 0, "book empty");

        assertGt(vault.totalAssets(), 50e18, "the vault must have earned");

        uint256 maxR = vault.maxRedeem(LP);
        vm.prank(LP);
        uint256 got = vault.redeem(maxR, LP, LP);
        assertGt(got, 50e18, "the LP exits at a gain");
    }

    /// @dev A USDC-market offer must not ratify on the WETH vault: `asset()` gates every market.
    function test_RejectsForeignLoanToken() public {
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.expectRevert(PlumbVault.OfferWrongMarket.selector);
        vault.isRatified(bid, "", address(this));
    }
}
