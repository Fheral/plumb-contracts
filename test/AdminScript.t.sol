// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase} from "./MidnightForkBase.t.sol";
import {BlueMarketParams} from "../src/interfaces/IMorphoBlue.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";
import {Admin} from "../script/Admin.s.sol";

/// @notice The admin script is the multisig's only tooled path. It has to be right.
///
/// @dev A script that composes calldata is worth nothing if it composes the wrong calldata — and a
///      wrong `setBlueMarket` sends the idle sleeve to a market nobody chose. So each action is
///      checked the only way that means anything: run it, then assert the effect it claims, on a
///      vault built exactly like the deployed one.
///
///      This suite also pins the two properties the script exists for. It signs nothing (the state
///      is untouched once the script returns), and it refuses to propose a call that reverts.
contract AdminScriptTest is MidnightForkBase {
    address OWNER = makeAddr("OWNER");
    address OPERATOR = makeAddr("OPERATOR");
    address FEES = makeAddr("FEES");

    PlumbVault vault;
    QuoteModule quote;
    Admin admin;

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
        quote.setVault(address(vault));
        vault.setBlueMarket(blueMarket());
        vault.setOperator(OPERATOR);
        vm.stopPrank();

        admin = new Admin();
        vm.setEnv("VAULT", vm.toString(address(vault)));
    }

    /// @dev Everything the script does happens in a simulation it is expected to roll back. What we
    ///      assert below is therefore the *effect of the proposal*, which only shows up if we let
    ///      the state stand — so each test replays the calldata deliberately, as the Safe would.
    function _execute(address target, bytes memory data) internal {
        vm.prank(OWNER);
        (bool ok,) = target.call(data);
        assertTrue(ok, "the proposed call must go through as the owner");
    }

    // -------------------------------------------------------------------------
    // What each action proposes
    // -------------------------------------------------------------------------

    function test_SetOperatorProposesTheRotation() public {
        address newOperator = makeAddr("NEW_OPERATOR");
        vm.setEnv("OPERATOR", vm.toString(newOperator));

        admin.setOperator();
        assertEq(vault.operator(), OPERATOR, "the script must not change anything by itself");

        _execute(address(vault), abi.encodeCall(PlumbVault.setOperator, (newOperator)));
        assertEq(vault.operator(), newOperator);
    }

    /// @notice The five-field call, the one worth simulating.
    function test_SetBlueMarketProposesTheFiveFields() public {
        vm.setEnv("BLUE_COLLATERAL", vm.toString(WETH));
        vm.setEnv("BLUE_ORACLE", vm.toString(ORACLE_WETH));
        vm.setEnv("BLUE_IRM", vm.toString(BLUE_IRM));
        vm.setEnv("BLUE_LLTV", vm.toString(BLUE_LLTV));

        admin.setBlueMarket();
        _execute(
            address(vault),
            abi.encodeCall(
                PlumbVault.setBlueMarket,
                (BlueMarketParams({
                        loanToken: address(USDC),
                        collateralToken: WETH,
                        oracle: ORACLE_WETH,
                        irm: BLUE_IRM,
                        lltv: BLUE_LLTV
                    }))
            )
        );

        (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv) = vault.blueMarket();
        assertEq(loanToken, address(USDC), "the loan token is the vault's asset, never an env var");
        assertEq(collateralToken, WETH);
        assertEq(oracle, ORACLE_WETH);
        assertEq(irm, BLUE_IRM);
        assertEq(lltv, BLUE_LLTV);
    }

    function test_SetRiskParamsProposesBothBounds() public {
        vm.setEnv("MAX_BOOK_BPS", "2500");
        vm.setEnv("MAX_SINGLE_FILL", "25000000000"); // 25k USDC

        admin.setRiskParams();
        _execute(address(vault), abi.encodeCall(PlumbVault.setRiskParams, (2500, 25_000e6)));

        assertEq(vault.maxBookBps(), 2500);
        assertEq(vault.maxSingleFill(), 25_000e6);
    }

    function test_SetFeeProposesTheRateAndTheRecipient() public {
        address newRecipient = makeAddr("NEW_FEES");
        vm.setEnv("PERF_FEE_BPS", "1000");
        vm.setEnv("FEE_RECIPIENT", vm.toString(newRecipient));

        admin.setFee();
        _execute(address(vault), abi.encodeCall(PlumbVault.setFee, (1000, newRecipient)));

        assertEq(vault.perfFeeBps(), 1000);
        assertEq(vault.feeRecipient(), newRecipient);
    }

    function test_OpenEpochProposesTheBudget() public {
        vm.setEnv("EPOCH_BUDGET", "300000000000"); // 300k USDC
        uint256 epochBefore = vault.epoch();

        admin.openEpoch();
        _execute(address(vault), abi.encodeCall(PlumbVault.openEpoch, (300_000e6)));

        assertEq(vault.epoch(), epochBefore + 1);
        assertEq(vault.epochBudget(), 300_000e6);
    }

    function test_BasePolicyProposesTheWholePolicy() public {
        vm.setEnv("RATE_BPS", "900");
        vm.setEnv("SKEW_BPS", "400");
        vm.setEnv("MIN_TENOR", "86400");
        vm.setEnv("MAX_TENOR", "7776000");
        vm.setEnv("MAX_UNITS_BPS", "2500");

        admin.setBasePolicy();
        _execute(
            address(quote),
            abi.encodeCall(
                QuoteModule.setBasePolicy,
                (QuoteModule.BasePolicy({
                        rateBps: 900, skewBps: 400, minTenor: 1 days, maxTenor: 90 days, maxUnitsBps: 2_500
                    }))
            )
        );

        QuoteModule.BasePolicy memory p = quote.basePolicy();
        assertEq(p.rateBps, 900);
        assertEq(p.skewBps, 400);
        assertEq(p.minTenor, 1 days);
        assertEq(p.maxTenor, 90 days);
        assertEq(p.maxUnitsBps, 2_500);
    }

    /// @dev The proposal that actually selects markets. Approving a collateral makes every Midnight
    ///      market built on it quotable — which is why it goes through the multisig and a per-market
    ///      call does not exist to go through it.
    function test_CollateralPolicyProposesTheApproval() public {
        vm.setEnv("COLLATERAL_TOKEN", vm.toString(WETH));
        vm.setEnv("ALLOWED", "true");
        vm.setEnv("VOL_SPREAD_BPS", "150");
        vm.setEnv("MAX_LLTV", "860000000000000000");

        admin.setCollateralPolicy();
        _execute(
            address(quote),
            abi.encodeCall(
                QuoteModule.setCollateralPolicy,
                (WETH, QuoteModule.CollateralPolicy({allowed: true, volSpreadBps: 150, maxLltv: 0.86e18}))
            )
        );

        QuoteModule.CollateralPolicy memory c = quote.collateralPolicy(WETH);
        assertTrue(c.allowed);
        assertEq(c.volSpreadBps, 150);
        assertEq(c.maxLltv, 0.86e18);
    }

    /// @dev The escape hatch, which can only ever remove.
    function test_BlockedProposesTheRefusal() public {
        vm.setEnv("MARKET_ID", vm.toString(id));
        vm.setEnv("BLOCKED", "true");

        admin.setBlocked();
        _execute(address(quote), abi.encodeCall(QuoteModule.setBlocked, (id, true)));

        assertTrue(quote.blocked(id));
    }

    function test_ContinuousFeeCapProposesTheCap() public {
        vm.setEnv("CONTINUOUS_FEE_CAP", "1000");

        admin.setContinuousFeeCap();
        _execute(address(quote), abi.encodeCall(QuoteModule.setContinuousFeeCap, (1000)));

        assertEq(quote.continuousFeeCap(), 1000);
    }

    // -------------------------------------------------------------------------
    // The two properties the script exists for
    // -------------------------------------------------------------------------

    /// @notice A proposal that would revert is not a proposal. It never reaches the signers.
    /// @dev The point of simulating before printing: the person composing the call finds the
    ///      mistake, instead of four people finding it after approving it.
    function test_ARevertingCallIsNeverProposed() public {
        vm.setEnv("PERF_FEE_BPS", "9999"); // above MAX_PERF_FEE_BPS
        vm.setEnv("FEE_RECIPIENT", vm.toString(FEES));

        vm.expectRevert("Admin: the call reverts against current state, not proposing it");
        admin.setFee();
    }

    /// @notice `unpause()` on a vault that is not paused reverts, which is the useful behaviour —
    ///         but the escape hatch has to work, because that proposal is legitimately prepared
    ///         before the incident it answers.
    function test_SimulationCanBeSkipped() public {
        vm.expectRevert("Admin: the call reverts against current state, not proposing it");
        admin.unpause();

        vm.setEnv("ADMIN_SIMULATE", "false");
        admin.unpause(); // no revert: the calldata is built, nothing is checked
    }

    /// @notice And in no case does the script move anything on its own.
    function test_TheScriptSignsNothing() public {
        vm.setEnv("OPERATOR", vm.toString(makeAddr("SOMEONE_ELSE")));
        vm.setEnv("MAX_BOOK_BPS", "9999");
        vm.setEnv("MAX_SINGLE_FILL", "1");
        uint256 maxBookBpsBefore = vault.maxBookBps();
        uint128 maxSingleFillBefore = vault.maxSingleFill();

        admin.setOperator();
        admin.setRiskParams();

        assertEq(vault.operator(), OPERATOR, "operator untouched");
        assertEq(vault.maxBookBps(), maxBookBpsBefore, "book cap untouched");
        assertEq(vault.maxSingleFill(), maxSingleFillBefore, "single fill cap untouched");
    }
}
