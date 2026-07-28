// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MidnightForkBase} from "./MidnightForkBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";
import {DeployMainnet} from "../script/DeployMainnet.s.sol";

/// @notice What the mainnet deployment refuses to do, and what it would price.
///
/// @dev The guardrails are the point of the file, so they are what is tested. Each `require`
///      answers a specific way this goes wrong — and they are all checked before the first
///      broadcast, and `guard()` holds them so they can be exercised as what they are: plain
///      conditions on four addresses, with no environment in the way.
///
///      The broadcast path itself is deliberately not run here: it would write
///      `deployments/base.json`, and a file produced by a test run is exactly the kind of artefact
///      that later gets mistaken for a record of a real deployment. What can be checked without it
///      is the part that has consequences — that the shipped policy is one `QuoteModule` accepts,
///      and that it prices the real Midnight market to a rate the bounds allow.
contract DeployMainnetScriptTest is MidnightForkBase {
    DeployMainnet script;

    address DEPLOYER = makeAddr("DEPLOYER"); // the hot key that would sign the deployment
    address OWNER = makeAddr("MULTISIG");
    address OPERATOR = makeAddr("BOT");
    address FEES = makeAddr("FEES");

    function setUp() public {
        _forkSetUp();
        script = new DeployMainnet();
    }

    // -------------------------------------------------------------------------
    // What it refuses
    // -------------------------------------------------------------------------

    /// @notice Wrong chain, no deployment. The first thing checked, before anything is read.
    function test_RefusesAnyChainThatIsNotBase() public {
        vm.chainId(1);
        vm.expectRevert("DeployMainnet: not Base");
        script.guard(DEPLOYER, OWNER, OPERATOR, FEES);
    }

    /// @notice The deployer signs the deployment and holds nothing afterwards.
    ///
    /// @dev The three checks below all guard the same accident — the local invocation, copied,
    ///      where the deployer is passed as `owner` and as `feeRecipient` and an anvil key is
    ///      passed as `operator`. It is the most likely way this goes wrong and the only one that
    ///      cannot be undone: a hot key with ownership of a live vault.
    function test_RefusesADeployerThatWouldKeepOwnership() public {
        vm.expectRevert("DeployMainnet: owner must not be the deployer");
        script.guard(DEPLOYER, DEPLOYER, OPERATOR, FEES);
    }

    function test_RefusesADeployerThatWouldKeepTheOperatorRole() public {
        vm.expectRevert("DeployMainnet: operator must not be the deployer");
        script.guard(DEPLOYER, OWNER, DEPLOYER, FEES);
    }

    function test_RefusesADeployerThatWouldKeepTheFeeStream() public {
        vm.expectRevert("DeployMainnet: feeRecipient must not be the deployer");
        script.guard(DEPLOYER, OWNER, OPERATOR, DEPLOYER);
    }

    /// @notice And the multisig is not the bot. The whole point of the role split is that the key
    ///         that quotes cannot change what quoting means.
    function test_RefusesTheMultisigActingAsItsOwnBot() public {
        vm.expectRevert("DeployMainnet: the multisig must not also be the bot key");
        script.guard(DEPLOYER, OWNER, OWNER, FEES);
    }

    // -------------------------------------------------------------------------
    // What it would price
    // -------------------------------------------------------------------------

    /// @notice The shipped policy is one the module accepts, and it prices the real market.
    ///
    /// @dev A set of constants that `setMarketConfig` would reject, or that `maxTick` could not
    ///      turn into a tick, would only be discovered on the day of the deployment. Applying them
    ///      to the real Midnight market on a fork is the cheap way to know beforehand.
    function test_TheShippedPolicyPricesTheRealMarket() public {
        QuoteModule quote = new QuoteModule(address(this));
        PlumbVault vault = new PlumbVault(
            "Plumb Exit Liquidity USDC",
            "plUSDC",
            address(USDC),
            address(MIDNIGHT),
            BLUE,
            address(quote),
            address(this),
            FEES
        );
        quote.setVault(address(vault));
        vault.setBlueMarket(script.blueMarket());
        quote.setMarketConfig(id, script.marketConfig());

        uint256 rate = quote.effectiveRateBps(id);
        uint256 tick = quote.maxTick(id, MATURITY, MIDNIGHT.tickSpacing(id));
        console2.log("empty-book rate (bps)", rate);
        console2.log("blue supply rate (bps)", vault.blueSupplyRateBps());
        console2.log("tick", tick);

        QuoteModule.MarketConfig memory c = script.marketConfig();
        assertEq(rate, uint256(c.rateBps) + c.volSpreadBps, "an empty book quotes base + spread, nothing else");
        assertGt(rate, vault.blueSupplyRateBps() + quote.blueFloorMarginBps(), "the bid must clear the Blue floor");
        assertGt(tick, 0, "the policy must produce a usable tick on the real market");
    }

    /// @notice A correctly separated set of roles passes.
    function test_DistinctRolesPass() public view {
        script.guard(DEPLOYER, OWNER, OPERATOR, FEES);
    }

    /// @notice A full book still quotes below the clamp, so the skew keeps saying something.
    /// @dev If `rateBps + volSpreadBps + skewBps` reached `MAX_RATE_BPS`, the last quarter of the
    ///      book would be priced like the third, and the skew would stop being a signal.
    function test_AFullBookStillQuotesUnderTheClamp() public view {
        QuoteModule.MarketConfig memory c = script.marketConfig();
        uint256 full = uint256(c.rateBps) + c.volSpreadBps + c.skewBps;
        console2.log("full-book rate (bps)", full);
        assertLt(full, 3000, "a saturated skew is a skew that says nothing");
    }
}
