// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {IMidnight, Market, CollateralParams, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {TickLib} from "../src/interfaces/midnight/TickLib.sol";

interface IERC20 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Permissive ratifier used only for the probe: it validates every offer.
///      In production Plumb will use the EcrecoverRatifier (offchain-signed offers) or the SetterRatifier.
contract AlwaysRatifier {
    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return keccak256("morpho.midnight.callbackSuccess");
    }
}

/// @notice Phase 0 probe — empirically validates Plumb's founding assumptions on a Base fork.
///
/// Question asked: can a Midnight lender exit before maturity, and can Plumb be the
/// counterparty that buys back their position at a discount?
contract Phase0_MidnightProbe is Test {
    IMidnight constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    IERC20 constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // Real market: USDC lent, WETH + wstETH collateral, maturity 2026-09-24.
    uint256 constant MATURITY = 1790208000;
    address constant ORACLE_WETH = 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4;
    address constant COLL2 = 0xe690a58EF52854513462745237F6A213a0d54dF1;
    address constant ORACLE_COLL2 = 0x784519B1b59A1e1498f077066bB9336672bcc3EE;

    address BORROWER = makeAddr("BORROWER");
    address ALICE = makeAddr("ALICE_LENDER"); // lender who will want to exit early
    address PLUMB = makeAddr("PLUMB_VAULT"); // the vault, counterparty of the exit

    AlwaysRatifier ratifier;
    bytes32 id;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        ratifier = new AlwaysRatifier();

        id = MIDNIGHT.touchMarket(_market());

        deal(address(USDC), ALICE, 1_000_000e6);
        deal(address(USDC), PLUMB, 1_000_000e6);
        deal(WETH, BORROWER, 2000e18);

        vm.prank(ALICE);
        USDC.approve(address(MIDNIGHT), type(uint256).max);
        vm.prank(PLUMB);
        USDC.approve(address(MIDNIGHT), type(uint256).max);
        vm.prank(BORROWER);
        IERC20(WETH).approve(address(MIDNIGHT), type(uint256).max);

        // Each maker must authorize its ratifier on Midnight.
        vm.prank(BORROWER);
        MIDNIGHT.setIsAuthorized(address(ratifier), true, BORROWER);
        vm.prank(PLUMB);
        MIDNIGHT.setIsAuthorized(address(ratifier), true, PLUMB);
    }

    function _market() internal view returns (Market memory m) {
        CollateralParams[] memory cps = new CollateralParams[](2);
        cps[0] = CollateralParams(WETH, 0.86e18, 0.3e18, ORACLE_WETH);
        cps[1] = CollateralParams(COLL2, 0.98e18, 0.3e18, ORACLE_COLL2);
        m = Market({
            chainId: 8453,
            midnight: address(MIDNIGHT),
            loanToken: address(USDC),
            collateralParams: cps,
            maturity: MATURITY,
            rcfThreshold: 3e9,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }

    function _offer(address maker, bool buy, uint256 tick, uint128 maxUnits, bool reduceOnly)
        internal
        view
        returns (Offer memory o)
    {
        o = Offer({
            market: _market(),
            buy: buy,
            maker: maker,
            start: 0,
            expiry: type(uint256).max,
            tick: tick,
            group: keccak256(abi.encode(maker, tick, buy)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: buy ? address(0) : maker,
            ratifier: address(ratifier),
            reduceOnly: reduceOnly,
            maxUnits: maxUnits,
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    /// @dev Converts a unit price (WAD) into a valid tick for this market.
    function _tickFor(uint256 priceWad) internal view returns (uint256) {
        uint8 spacing = MIDNIGHT.tickSpacing(id);
        return TickLib.priceToTick(priceWad, spacing);
    }

    function test_Phase0_EarlyExitIsNativelyPossible() public {
        uint8 spacing = MIDNIGHT.tickSpacing(id);
        console2.log("=== MARKET ===");
        console2.log("tickSpacing        :", spacing);
        console2.log("totalUnits (face)  :", MIDNIGHT.totalUnits(id));
        console2.log("days until maturity:", (MATURITY - block.timestamp) / 1 days);

        // ---------------------------------------------------------------
        // 1. ORIGINATION: the borrower borrows, ALICE becomes the lender.
        // ---------------------------------------------------------------
        vm.prank(BORROWER);
        MIDNIGHT.supplyCollateral(_market(), 0, 1000e18, BORROWER);

        // The borrower sells 100_000 units (= 100_000 USDC face at maturity) at ~3.7% annualized.
        uint256 tenor = MATURITY - block.timestamp;
        uint256 fairPrice = 1e18 - (0.037e18 * tenor) / 365 days;
        Offer memory origination = _offer(BORROWER, false, _tickFor(fairPrice), 100_000e6, false);

        vm.prank(ALICE);
        (uint256 aliceBuyerAssets,) = MIDNIGHT.take(origination, "", 100_000e6, ALICE, address(0), address(0), "");

        uint128 aliceCredit = MIDNIGHT.credit(id, ALICE);
        console2.log("\n=== 1. ORIGINATION ===");
        console2.log("ALICE pays (USDC)  :", aliceBuyerAssets);
        console2.log("ALICE credit (face):", aliceCredit);
        assertGt(aliceCredit, 0, "ALICE must hold credit");
        assertEq(MIDNIGHT.debt(id, BORROWER), aliceCredit, "the borrower carries the symmetric debt");

        // ---------------------------------------------------------------
        // 2. EARLY EXIT: 15 days later, ALICE wants out.
        //    PLUMB is the resting bid, at a wider discount than the market.
        // ---------------------------------------------------------------
        vm.warp(block.timestamp + 15 days);
        uint256 remaining = MATURITY - block.timestamp;

        // Plumb quotes 9% annualized instead of 3.7%: that is where the yield lies.
        uint256 plumbPrice = 1e18 - (0.09e18 * remaining) / 365 days;
        Offer memory plumbBid = _offer(PLUMB, true, _tickFor(plumbPrice), 100_000e6, false);

        uint256 aliceBefore = USDC.balanceOf(ALICE);
        uint256 plumbBefore = USDC.balanceOf(PLUMB);

        vm.prank(ALICE);
        MIDNIGHT.take(plumbBid, "", aliceCredit, ALICE, ALICE, address(0), "");

        uint256 aliceProceeds = USDC.balanceOf(ALICE) - aliceBefore;
        uint256 plumbPaid = plumbBefore - USDC.balanceOf(PLUMB);

        console2.log("\n=== 2. EARLY EXIT ===");
        console2.log("ALICE receives (USDC):", aliceProceeds);
        console2.log("PLUMB pays   (USDC):", plumbPaid);
        console2.log("ALICE remaining credit:", MIDNIGHT.credit(id, ALICE));
        console2.log("ALICE debt (must be 0):", MIDNIGHT.debt(id, ALICE));
        console2.log("PLUMB credit (face):", MIDNIGHT.credit(id, PLUMB));

        // THE DECISIVE POINT: ALICE exited without taking on any debt.
        assertEq(MIDNIGHT.credit(id, ALICE), 0, "ALICE fully exited");
        assertEq(MIDNIGHT.debt(id, ALICE), 0, "exit WITHOUT taking on debt");
        assertEq(MIDNIGHT.credit(id, PLUMB), aliceCredit, "PLUMB took over the claim");

        // ---------------------------------------------------------------
        // 3. MATURITY: PLUMB collects par.
        // ---------------------------------------------------------------
        vm.warp(MATURITY + 1);
        deal(address(USDC), BORROWER, 200_000e6);
        vm.prank(BORROWER);
        USDC.approve(address(MIDNIGHT), type(uint256).max);
        uint128 borrowerDebt = MIDNIGHT.debt(id, BORROWER);
        vm.prank(BORROWER);
        MIDNIGHT.repay(_market(), borrowerDebt, BORROWER, address(0), "");

        MIDNIGHT.updatePosition(_market(), PLUMB);
        uint128 plumbCredit = MIDNIGHT.credit(id, PLUMB);
        uint256 plumbCashBefore = USDC.balanceOf(PLUMB);
        vm.prank(PLUMB);
        MIDNIGHT.withdraw(_market(), plumbCredit, PLUMB, PLUMB);
        uint256 plumbRedeemed = USDC.balanceOf(PLUMB) - plumbCashBefore;

        uint256 profit = plumbRedeemed - plumbPaid;
        uint256 apyBps = (profit * 10_000 * 365 days) / (plumbPaid * remaining);

        console2.log("\n=== 3. MATURITY ===");
        console2.log("PLUMB collects (USDC):", plumbRedeemed);
        console2.log("Profit         (USDC):", profit);
        console2.log("Realized APY     (bps):", apyBps);

        assertGt(plumbRedeemed, plumbPaid, "Plumb must collect more than it paid");
        assertGt(apyBps, 800, "realized APY > 8%");
    }
}
