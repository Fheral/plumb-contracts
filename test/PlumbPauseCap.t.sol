// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {Market, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice The emergency brake, the sleeve migration and the deposit cap.
contract PlumbPauseCapTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");
    address STRANGER = makeAddr("STRANGER");

    PlumbVault vault;
    QuoteModule quote;

    uint16 constant RATE_BPS = 900;

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
        _createOtherBlueMarket();

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

        vm.startPrank(LP);
        IERC20Like(address(USDC)).approve(address(vault), type(uint256).max);
        vault.deposit(200_000e6, LP);
        vm.stopPrank();
    }

    function _hitBid(uint256 units) internal {
        Offer memory bid = vault.buildBid(midnightMarket(), type(uint256).max);
        vm.prank(SELLER);
        MIDNIGHT.take(bid, "", units, SELLER, SELLER, address(0), "");
    }

    // -------------------------------------------------------------------------
    // The emergency brake
    // -------------------------------------------------------------------------

    /// @notice The open question this file was written for: does `kill()` still work once the
    ///         epoch's budget has been spent to the last unit?
    /// @dev The budget is deliberately small, so a single `take` exhausts it exactly. Midnight's
    ///      `consumed` counter is monotonic, so this is the state where a strictly-increasing
    ///      `setConsumed` would refuse the write — and it is precisely the moment one wants the
    ///      brake.
    function test_KillWorksOnAFullyConsumedBudget() public {
        vm.prank(OPERATOR);
        vault.openEpoch(20_000e6);

        _originate(SELLER, 20_000e6, 370);
        vm.warp(block.timestamp + 1 days);
        _hitBid(20_000e6);

        assertEq(vault.remainingBudget(), 0, "the budget must be spent to the last unit");

        vm.prank(OPERATOR);
        vault.kill();
        assertTrue(vault.paused(), "the brake must engage on an exhausted budget");
    }

    /// @notice And in the other reachable degenerate state: the freshly deployed vault, which takes
    ///         deposits before any epoch is opened.
    function test_KillWorksBeforeAnyEpochIsOpened() public {
        assertEq(vault.epochBudget(), 0, "no epoch opened yet");

        vm.prank(OPERATOR);
        vault.kill();
        assertTrue(vault.paused(), "the brake must exist before the first epoch");
    }

    /// @notice `pause()` depends on no external state at all — not on Midnight, not on a budget.
    function test_PauseIsIndependentOfAnyExternalState() public {
        vm.prank(OPERATOR);
        vault.pause();
        assertTrue(vault.paused(), "the operator must be able to pause");

        // Deposits stop, and ERC-4626 says so rather than reverting on a promise it cannot keep.
        assertEq(vault.maxDeposit(LP), 0, "a paused vault accepts no deposit");
        assertEq(vault.maxMint(LP), 0, "a paused vault mints no share");
        vm.prank(LP);
        vm.expectRevert();
        vault.deposit(1e6, LP);

        // Withdrawals do not: an emergency brake that locked depositors in would be worse than none.
        uint256 max = vault.maxWithdraw(LP);
        assertGt(max, 0, "the exit must stay open");
        vm.prank(LP);
        vault.withdraw(max, LP, LP);
    }

    function test_PauseIsOperatorOnlyAndUnpauseStaysOwnerOnly() public {
        vm.prank(STRANGER);
        vm.expectRevert(PlumbVault.NotOperator.selector);
        vault.pause();

        // The owner keeps every operator right, as everywhere else in the contract.
        vm.prank(OWNER);
        vault.pause();

        // Lifting the brake is not the operator's to lift: `unpause` is `onlyOwner`, and the
        // asymmetry with `pause` is the point — stopping is cheap, restarting is a decision.
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OPERATOR));
        vault.unpause();
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        vault.unpause();

        vm.prank(OWNER);
        vault.unpause();
        assertFalse(vault.paused(), "the owner lifts it");
    }

    // -------------------------------------------------------------------------
    // The Blue sleeve
    // -------------------------------------------------------------------------

    function test_SetBlueMarketRefusesToStrandTheSleeve() public {
        assertGt(vault.blueAssets(), 0, "the sleeve is funded");

        vm.prank(OWNER);
        vm.expectRevert(PlumbVault.BlueSleeveNotEmpty.selector);
        vault.setBlueMarket(otherBlueMarket());
    }

    function test_SetBlueMarketPassesOnAnEmptySleeve() public {
        vm.prank(OPERATOR);
        vault.withdrawFromBlue(type(uint256).max);

        vm.prank(OWNER);
        vault.setBlueMarket(otherBlueMarket());
        (, address collateralToken,,,) = vault.blueMarket();
        assertEq(collateralToken, otherBlueMarket().collateralToken, "the sleeve moved");
    }

    /// @notice The atomic path: the NAV is the same before and after, at the wei of Blue rounding.
    function test_MigrateBlueMarketKeepsTheNavWhole() public {
        uint256 navBefore = vault.totalAssets();
        uint256 blueBefore = vault.blueAssets();
        assertGt(blueBefore, 0, "the sleeve is funded");

        vm.prank(OWNER);
        vault.migrateBlueMarket(otherBlueMarket());

        assertApproxEqAbs(vault.totalAssets(), navBefore, 2, "the NAV must survive the migration");
        assertApproxEqAbs(vault.blueAssets(), blueBefore, 2, "the capital must be on the new market");
        assertEq(vault.idleAssets(), 0, "nothing left sitting idle");
    }

    function test_MigrateBlueMarketIsOwnerOnly() public {
        vm.prank(OPERATOR);
        vm.expectRevert();
        vault.migrateBlueMarket(otherBlueMarket());
    }

    // -------------------------------------------------------------------------
    // The deposit cap
    // -------------------------------------------------------------------------

    function test_DepositCapBoundsTheVaultsTvl() public {
        uint256 nav = vault.totalAssets();

        vm.prank(OWNER);
        vault.setDepositCap(nav + 10_000e6);

        assertApproxEqAbs(vault.maxDeposit(LP), 10_000e6, 2, "headroom is the cap minus the NAV");

        vm.prank(LP);
        vm.expectRevert();
        vault.deposit(20_000e6, LP);

        vm.prank(LP);
        vault.deposit(5_000e6, LP);
        assertApproxEqAbs(vault.maxDeposit(LP), 5_000e6, 4, "the headroom shrank by as much");
    }

    function test_DepositCapAtZeroClosesTheDoorAndDefaultsOpen() public {
        assertEq(vault.depositCap(), type(uint256).max, "uncapped until the owner says otherwise");
        assertEq(vault.maxDeposit(LP), type(uint256).max, "and unbounded while it is");

        vm.prank(OWNER);
        vault.setDepositCap(0);
        assertEq(vault.maxDeposit(LP), 0, "a zero cap accepts nothing");
        assertEq(vault.maxMint(LP), 0, "and mints nothing");
    }

    /// @dev A cap set below the current NAV must read as no headroom, not underflow.
    function test_DepositCapBelowTheNavReadsAsZero() public {
        vm.prank(OWNER);
        vault.setDepositCap(1e6);
        assertEq(vault.maxDeposit(LP), 0, "no headroom, no revert");
        assertEq(vault.maxMint(LP), 0, "no headroom, no revert");
    }

    function test_SetDepositCapIsOwnerOnly() public {
        vm.prank(OPERATOR);
        vm.expectRevert();
        vault.setDepositCap(1);
    }

    /// @dev `maxMint` must be the share image of `maxDeposit`: minting up to it has to go through.
    function test_MaxMintIsHonoured() public {
        // Hoisted: a nested external call in an argument list eats the pending `vm.prank`.
        uint256 cap = vault.totalAssets() + 10_000e6;
        vm.prank(OWNER);
        vault.setDepositCap(cap);

        uint256 shares = vault.maxMint(LP);
        assertGt(shares, 0, "there is headroom");
        vm.prank(LP);
        vault.mint(shares, LP);
    }

    // -------------------------------------------------------------------------
    // The decimals offset
    // -------------------------------------------------------------------------

    /// @notice A 6-decimal asset gives 12-decimal shares, and one asset is worth 1e6 shares at
    ///         inception. That is the whole point: an inflation attack has to donate 1e6 times more.
    function test_SharesCarrySixExtraDecimals() public view {
        assertEq(vault.decimals(), 12, "6 asset decimals + 6 offset");
        assertApproxEqRel(vault.balanceOf(LP), 200_000e12, 1e12, "shares are scaled by 1e6");
    }
}
