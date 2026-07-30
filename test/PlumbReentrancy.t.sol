// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase, IERC20Like} from "./MidnightForkBase.t.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Market} from "../src/interfaces/midnight/IMidnight.sol";
import {IdLib} from "../src/interfaces/midnight/IdLib.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";

interface IERC20Transfer {
    function transfer(address, uint256) external returns (bool);
}

/// @notice A Midnight that fights back.
///
/// The vault's locks exist because `onBuy` is a callback: a third-party contract calls the vault
/// in the middle of a transaction the vault did not start. The real Midnight does not re-enter, so
/// on a fork the locks are never exercised — they are asserted by reading the source, which is not
/// an assertion. This stands in for a Midnight that has been upgraded, compromised, or simply
/// written differently, and re-enters the vault every time the vault hands it control.
///
/// Only the surface `PlumbVault` actually calls is implemented. The hostile hooks are the two
/// non-view calls the vault makes into Midnight while holding book state mid-write:
/// `updatePosition` (from `_mark`, hence from `onBuy`, `mark` and `settle`) and `withdraw` (from
/// `settle`). Views are staticcalls and cannot re-enter a state-changing function at all.
contract HostileMidnight {
    enum Attack {
        None,
        Deposit,
        Mint,
        Withdraw,
        Redeem,
        Mark,
        Settle,
        OnBuy,
        ReadOnly
    }

    PlumbVault public vault;
    /// @dev ABI-encoded: `Market` carries a dynamic array, which legacy codegen cannot copy to
    ///      storage. The blob keeps the mock free of the `via-ir` pipeline.
    bytes internal _marketData;
    bytes32 public marketId;

    /// @dev What the vault's position "is worth" from Midnight's side.
    uint128 public creditOf;
    uint128 public withdrawableUnits;

    Attack public onUpdatePosition;
    Attack public onWithdraw;

    /// @notice Set once a hostile hook has actually fired, so a passing test cannot be a test that
    ///         silently never reached the callback.
    bool public fired;

    IERC20Transfer immutable USDC;

    constructor(IERC20Transfer usdc_) {
        USDC = usdc_;
    }

    function bind(PlumbVault v, Market memory m) external {
        vault = v;
        _marketData = abi.encode(m);
        marketId = IdLib.toId(m);
    }

    function market() public view returns (Market memory) {
        return abi.decode(_marketData, (Market));
    }

    function setCredit(uint128 credit_) external {
        creditOf = credit_;
    }

    function setWithdrawable(uint128 units) external {
        withdrawableUnits = units;
    }

    function armUpdatePosition(Attack a) external {
        onUpdatePosition = a;
        fired = false;
    }

    function armWithdraw(Attack a) external {
        onWithdraw = a;
        fired = false;
    }

    // --- the surface PlumbVault uses ---

    function setIsAuthorized(address, bool, address) external {}

    function setConsumed(bytes32, uint128, address) external {}

    function tickSpacing(bytes32) external pure returns (uint8) {
        return 1;
    }

    function toMarket(bytes32) external view returns (Market memory) {
        return market();
    }

    function updatePositionView(Market memory, bytes32, address) external view returns (uint128, uint128, uint128) {
        return (creditOf, 0, 0);
    }

    function updatePosition(Market memory, address) external returns (uint128, uint128, uint128) {
        _strike(onUpdatePosition);
        return (creditOf, 0, 0);
    }

    function withdrawable(bytes32) external view returns (uint128) {
        return withdrawableUnits;
    }

    function withdraw(Market memory, uint256 units, address, address receiver) external {
        USDC.transfer(receiver, units);
        _strike(onWithdraw);
    }

    /// @dev Plays Midnight calling the buy callback. `buyerAssets` is deliberately *not* collected
    ///      afterwards: what is under test is the lock, not the settlement of cash.
    function callOnBuy(uint256 units, uint256 buyerAssets) external {
        vault.onBuy(marketId, market(), buyerAssets, units, 0, address(vault), "");
    }

    // --- the hostile part ---

    /// @dev Bubbles the inner revert up verbatim. A swallowed revert would let the outer call
    ///      succeed and the test would then be asserting nothing; bubbling makes the guard's own
    ///      error the error the test sees.
    function _strike(Attack a) internal {
        if (a == Attack.None) return;
        fired = true;

        bytes memory data;
        if (a == Attack.Deposit) {
            data = abi.encodeCall(PlumbVault.deposit, (1e6, address(this)));
        } else if (a == Attack.Mint) {
            data = abi.encodeCall(PlumbVault.mint, (1e6, address(this)));
        } else if (a == Attack.Withdraw) {
            data = abi.encodeCall(PlumbVault.withdraw, (1e6, address(this), address(this)));
        } else if (a == Attack.Redeem) {
            data = abi.encodeCall(PlumbVault.redeem, (1e6, address(this), address(this)));
        } else if (a == Attack.Mark) {
            data = abi.encodeCall(PlumbVault.mark, (market()));
        } else if (a == Attack.Settle) {
            data = abi.encodeCall(PlumbVault.settle, (market()));
        } else if (a == Attack.OnBuy) {
            data = abi.encodeCall(PlumbVault.onBuy, (marketId, market(), 1e6, 1e6, 0, address(vault), ""));
        } else {
            // Read-only re-entrancy: the guard must not make the vault unreadable mid-callback.
            data = abi.encodeCall(PlumbVault.totalAssets, ());
        }

        (bool ok, bytes memory ret) = address(vault).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

contract PlumbReentrancyTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");

    PlumbVault vault;
    QuoteModule quote;
    HostileMidnight midnight;
    bytes32 hostileId;

    uint128 constant FILL_UNITS = 50_000e6;
    uint256 constant FILL_ASSETS = 49_000e6;

    /// @dev The usual market, re-parented onto the hostile Midnight.
    function hostileMarket() internal view returns (Market memory m) {
        m = midnightMarket();
        m.midnight = address(midnight);
    }

    function setUp() public {
        _forkSetUp();

        midnight = new HostileMidnight(IERC20Transfer(address(USDC)));

        // Same market as everywhere else, re-parented onto the hostile Midnight: the vault reads
        // `market.loanToken` and nothing else about who runs the book.
        hostileId = IdLib.toId(hostileMarket());

        quote = new QuoteModule(OWNER);
        vault = new PlumbVault(
            "Plumb Exit Liquidity USDC",
            "plUSDC",
            address(USDC),
            address(midnight),
            BLUE,
            address(quote),
            OWNER,
            FEES,
            type(uint256).max
        );
        midnight.bind(vault, hostileMarket());

        vm.startPrank(OWNER);
        quote.setVault(address(vault));
        _configurePolicy(quote, uint16(900));
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

        // The hostile Midnight needs cash of its own to honour `withdraw`, and shares to be able to
        // attempt a redemption from inside the callback.
        deal(address(USDC), address(midnight), 500_000e6);
        vm.startPrank(address(midnight));
        USDC.approve(address(vault), type(uint256).max);
        // Real shares, so a re-entrant `withdraw` or `redeem` would be a genuine exit and not
        // merely bounce off `maxWithdraw`. Without them the tests would pass on the wrong error.
        vault.deposit(20_000e6, address(midnight));
        vm.stopPrank();

        // A first, peaceful fill. The book must be non-empty for `_mark` to call `updatePosition`
        // at all — an empty book returns before touching Midnight, and the hook would never fire.
        midnight.callOnBuy(FILL_UNITS, FILL_ASSETS);
        midnight.setCredit(FILL_UNITS);
        assertEq(vault.activeMarkets().length, 1, "the book must be armed for these tests to mean anything");
    }

    function _expectLocked() internal {
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    // -------------------------------------------------------------------------
    // Re-entering from inside `onBuy` — the callback the vault exposes to Midnight
    // -------------------------------------------------------------------------

    function test_OnBuy_CannotReenterDeposit() public {
        midnight.armUpdatePosition(HostileMidnight.Attack.Deposit);
        _expectLocked();
        midnight.callOnBuy(FILL_UNITS, FILL_ASSETS);
    }

    function test_OnBuy_CannotReenterMint() public {
        midnight.armUpdatePosition(HostileMidnight.Attack.Mint);
        _expectLocked();
        midnight.callOnBuy(FILL_UNITS, FILL_ASSETS);
    }

    /// @dev The one that would actually pay: withdrawing on a NAV that counts the incoming lot
    ///      while the cash for it has not left yet.
    function test_OnBuy_CannotReenterWithdraw() public {
        midnight.armUpdatePosition(HostileMidnight.Attack.Withdraw);
        _expectLocked();
        midnight.callOnBuy(FILL_UNITS, FILL_ASSETS);
    }

    function test_OnBuy_CannotReenterRedeem() public {
        midnight.armUpdatePosition(HostileMidnight.Attack.Redeem);
        _expectLocked();
        midnight.callOnBuy(FILL_UNITS, FILL_ASSETS);
    }

    function test_OnBuy_CannotReenterMark() public {
        midnight.armUpdatePosition(HostileMidnight.Attack.Mark);
        _expectLocked();
        midnight.callOnBuy(FILL_UNITS, FILL_ASSETS);
    }

    function test_OnBuy_CannotReenterSettle() public {
        midnight.setWithdrawable(FILL_UNITS);
        midnight.armUpdatePosition(HostileMidnight.Attack.Settle);
        _expectLocked();
        midnight.callOnBuy(FILL_UNITS, FILL_ASSETS);
    }

    /// @dev Nested fills: two lots folded into the book against one book-cap check.
    function test_OnBuy_CannotReenterOnBuy() public {
        midnight.armUpdatePosition(HostileMidnight.Attack.OnBuy);
        _expectLocked();
        midnight.callOnBuy(FILL_UNITS, FILL_ASSETS);
    }

    // -------------------------------------------------------------------------
    // Re-entering from inside `settle` — both hand-offs to Midnight
    // -------------------------------------------------------------------------

    function test_Settle_CannotReenterFromMark() public {
        midnight.setWithdrawable(FILL_UNITS);
        midnight.armUpdatePosition(HostileMidnight.Attack.Redeem);
        _expectLocked();
        vault.settle(hostileMarket());
    }

    /// @dev The nastier hand-off: the book has already been decided, the cash is already in, and
    ///      the withdrawal call is where Midnight gets control back — with `b.units` not yet
    ///      decremented. A re-entrant `settle` here would withdraw the same units twice.
    function test_Settle_CannotReenterFromWithdraw() public {
        midnight.setWithdrawable(FILL_UNITS);
        midnight.armWithdraw(HostileMidnight.Attack.Settle);
        _expectLocked();
        vault.settle(hostileMarket());
    }

    function test_Settle_CannotReenterRedeemFromWithdraw() public {
        midnight.setWithdrawable(FILL_UNITS);
        midnight.armWithdraw(HostileMidnight.Attack.Redeem);
        _expectLocked();
        vault.settle(hostileMarket());
    }

    // -------------------------------------------------------------------------
    // Re-entering from inside `mark` — permissionless, so anyone can open this door
    // -------------------------------------------------------------------------

    function test_Mark_CannotReenterDeposit() public {
        midnight.armUpdatePosition(HostileMidnight.Attack.Deposit);
        _expectLocked();
        vault.mark(hostileMarket());
    }

    function test_Mark_CannotReenterSettle() public {
        midnight.setWithdrawable(FILL_UNITS);
        midnight.armUpdatePosition(HostileMidnight.Attack.Settle);
        _expectLocked();
        vault.mark(hostileMarket());
    }

    // -------------------------------------------------------------------------
    // The guard must stop writes, not reads
    // -------------------------------------------------------------------------

    /// @dev Positive control. Two things at once: the hook really does fire (so the tests above
    ///      are refusals, not silence), and the lock does not brick the view path a third-party
    ///      integrator would read mid-transaction.
    function test_ViewsStayReadableDuringCallback() public {
        midnight.armUpdatePosition(HostileMidnight.Attack.ReadOnly);
        midnight.callOnBuy(FILL_UNITS, FILL_ASSETS);

        assertTrue(midnight.fired(), "the hostile hook never ran: the tests above prove nothing");
        (uint128 units,,,) = vault.book(hostileId);
        assertEq(units, 2 * FILL_UNITS, "the peaceful fill must still go through");
    }

    /// @dev Same control for the `settle` hand-off: the withdraw hook does fire, and a read from
    ///      inside it goes through.
    function test_WithdrawHookFiresAndReadsGoThrough() public {
        midnight.setWithdrawable(FILL_UNITS);
        midnight.armWithdraw(HostileMidnight.Attack.ReadOnly);
        vault.settle(hostileMarket());

        assertTrue(midnight.fired(), "the withdraw hook never ran: the tests above prove nothing");
        assertEq(vault.activeMarkets().length, 0, "settled clean");
    }

    /// @dev Sanity: the same attacks stop being reverts once they are no longer re-entrant. What
    ///      the tests above catch is the nesting, not a vault that refuses everything.
    function test_SameCallsSucceedOutsideTheCallback() public {
        midnight.armUpdatePosition(HostileMidnight.Attack.None);
        vault.mark(hostileMarket());

        vm.prank(LP);
        vault.deposit(1_000e6, LP);

        midnight.setWithdrawable(FILL_UNITS);
        vault.settle(hostileMarket());
        assertEq(vault.activeMarkets().length, 0, "settled clean");
    }
}
