// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";
import {BlueMarketParams} from "../src/interfaces/IMorphoBlue.sol";

/// @notice Builds — and only builds — the privileged calls of a deployed Plumb.
///
/// @dev Once on Base, `owner` is a multisig. Nothing here can sign, and nothing here broadcasts:
///      each entry point prints the `to` / `value` / `data` triplet to paste into the Safe, after
///      simulating the call against the current chain state. That order matters. Composing
///      calldata by hand in a browser is where the mistakes live — a field out of order, a decimal
///      off, an address from the wrong network — and these calls are not replayable.
///
///      What this buys, concretely:
///
///      - the invocation is a file, reviewed in a PR, instead of a form filled in once;
///      - the call is executed on a fork **before** the signers are asked for anything, so a
///        revert is discovered by the person proposing it and not by the four people approving it;
///      - `kill()` has a command ready to copy, which is the only one where seconds count.
///
///      Every action reads its arguments from the environment, so a proposal is fully described by
///      the command line that produced it. Simulation can be turned off with
///      `ADMIN_SIMULATE=false` — needed for `kill()`, see `_simulate`.
///
///      Usage:
///
///      ```sh
///      VAULT=0x… OPERATOR=0x… forge script script/Admin.s.sol --sig 'setOperator()' --rpc-url base
///      ```
contract Admin is Script {
    // -------------------------------------------------------------------------
    // Vault — onlyOwner
    // -------------------------------------------------------------------------

    /// @notice Lifts the pause. The counterpart of `kill()`, and the only way back from it.
    function unpause() external {
        _propose(_vault(), abi.encodeCall(PlumbVault.unpause, ()), "vault.unpause()");
    }

    /// @notice Rotates the bot's key. `OPERATOR=0x0` is revocation, not a mistake: it leaves the
    ///         owner alone entitled to open an epoch or pull the kill switch.
    function setOperator() external {
        address operator = vm.envAddress("OPERATOR");
        console2.log("operator :", operator);
        _propose(_vault(), abi.encodeCall(PlumbVault.setOperator, (operator)), "vault.setOperator(address)");
    }

    /// @notice Points the idle sleeve at a Morpho Blue market.
    /// @dev Five fields, the most exposed to a typo of anything here, and a wrong one sends the
    ///      capital that is not on the book to a market nobody chose. `loanToken` is not read from
    ///      the environment on purpose: it is the vault's own asset, and the vault rejects
    ///      anything else — one fewer field to get wrong.
    function setBlueMarket() external {
        PlumbVault vault = _vault();
        BlueMarketParams memory p = BlueMarketParams({
            loanToken: vault.asset(),
            collateralToken: vm.envAddress("BLUE_COLLATERAL"),
            oracle: vm.envAddress("BLUE_ORACLE"),
            irm: vm.envAddress("BLUE_IRM"),
            lltv: vm.envUint("BLUE_LLTV")
        });
        console2.log("loanToken  :", p.loanToken, "(the vault's asset, not read from env)");
        console2.log("collateral :", p.collateralToken);
        console2.log("oracle     :", p.oracle);
        console2.log("irm        :", p.irm);
        console2.log("lltv       :", p.lltv);
        _propose(vault, abi.encodeCall(PlumbVault.setBlueMarket, (p)), "vault.setBlueMarket(BlueMarketParams)");
    }

    /// @notice Retunes the book cap (in bps of NAV) and the largest single fill accepted.
    function setRiskParams() external {
        uint256 maxBookBps = vm.envUint("MAX_BOOK_BPS");
        uint128 maxSingleFill = uint128(vm.envUint("MAX_SINGLE_FILL"));
        console2.log("maxBookBps    :", maxBookBps);
        console2.log("maxSingleFill :", maxSingleFill);
        _propose(
            _vault(),
            abi.encodeCall(PlumbVault.setRiskParams, (maxBookBps, maxSingleFill)),
            "vault.setRiskParams(uint256,uint128)"
        );
    }

    /// @notice Sets the performance fee and its recipient.
    /// @dev Accrues the fee at the old rate on the way through, which is why simulating this one
    ///      is worth the detour: the call has an effect beyond the two values it carries.
    function setFee() external {
        uint256 perfFeeBps = vm.envUint("PERF_FEE_BPS");
        address recipient = vm.envAddress("FEE_RECIPIENT");
        console2.log("perfFeeBps :", perfFeeBps);
        console2.log("recipient  :", recipient);
        _propose(_vault(), abi.encodeCall(PlumbVault.setFee, (perfFeeBps, recipient)), "vault.setFee(uint256,address)");
    }

    // -------------------------------------------------------------------------
    // Vault — onlyOperator, but the owner may call them too
    // -------------------------------------------------------------------------

    /// @notice **Kill switch.** Exhausts the epoch's budget — every live offer dies at once,
    ///         whatever their number — and pauses the vault.
    ///
    /// @dev The one command to keep at hand. Deposits stop, withdrawals do not: the vault refuses
    ///      to take you in, never to let you out.
    ///
    ///      ```sh
    ///      VAULT=0x… ADMIN_SIMULATE=false forge script script/Admin.s.sol --sig 'kill()' --rpc-url base
    ///      ```
    ///
    ///      Simulation is off in that command, and not out of haste: `kill()` calls Midnight, and
    ///      `forge script`'s own EVM downgrades the spec below `osaka` on a known OP chainId — the
    ///      call would fail there for a reason that has nothing to do with the proposal. There is
    ///      nothing to check anyway: `kill()` takes no argument.
    function kill() external {
        _propose(_vault(), abi.encodeCall(PlumbVault.kill, ()), "vault.kill()");
    }

    /// @notice Opens a new budget epoch. Every offer from the previous one dies.
    function openEpoch() external {
        uint128 budget = uint128(vm.envUint("EPOCH_BUDGET"));
        console2.log("budget :", budget);
        _propose(_vault(), abi.encodeCall(PlumbVault.openEpoch, (budget)), "vault.openEpoch(uint128)");
    }

    // -------------------------------------------------------------------------
    // QuoteModule — onlyOwner
    // -------------------------------------------------------------------------

    /// @notice Enables or retunes a market's pricing.
    /// @dev Seven fields and a market id. `enabled: false` is how a market is taken off the book:
    ///      the policy stops pricing it, so no offer on it can be ratified.
    function setMarketConfig() external {
        bytes32 id = vm.envBytes32("MARKET_ID");
        QuoteModule.MarketConfig memory c = QuoteModule.MarketConfig({
            enabled: vm.envBool("ENABLED"),
            rateBps: uint16(vm.envUint("RATE_BPS")),
            volSpreadBps: uint16(vm.envUint("VOL_SPREAD_BPS")),
            skewBps: uint16(vm.envUint("SKEW_BPS")),
            minTenor: uint32(vm.envUint("MIN_TENOR")),
            maxTenor: uint32(vm.envUint("MAX_TENOR")),
            maxUnits: uint128(vm.envUint("MAX_UNITS"))
        });
        console2.log("marketId     :", vm.toString(id));
        console2.log("enabled      :", c.enabled);
        console2.log("rateBps      :", c.rateBps);
        console2.log("volSpreadBps :", c.volSpreadBps);
        console2.log("skewBps      :", c.skewBps);
        console2.log("minTenor     :", c.minTenor);
        console2.log("maxTenor     :", c.maxTenor);
        console2.log("maxUnits     :", c.maxUnits);
        _propose(
            _quote(),
            abi.encodeCall(QuoteModule.setMarketConfig, (id, c)),
            "quote.setMarketConfig(bytes32,MarketConfig)"
        );
    }

    /// @notice Retunes the margin demanded above Blue's supply rate.
    function setBlueFloorMargin() external {
        uint256 marginBps = vm.envUint("BLUE_FLOOR_MARGIN_BPS");
        console2.log("marginBps :", marginBps);
        _propose(
            _quote(), abi.encodeCall(QuoteModule.setBlueFloorMargin, (marginBps)), "quote.setBlueFloorMargin(uint256)"
        );
    }

    /// @notice Prices in a Midnight continuous fee.
    /// @dev Raising this hands part of the depositors' yield to Midnight governance. It is the one
    ///      knob here that costs money on its own, rather than changing what Plumb is willing to
    ///      do — hence worth writing down, in a PR, with the arithmetic that justified the number.
    function setContinuousFeeCap() external {
        uint256 cap = vm.envUint("CONTINUOUS_FEE_CAP");
        console2.log("cap :", cap);
        _propose(_quote(), abi.encodeCall(QuoteModule.setContinuousFeeCap, (cap)), "quote.setContinuousFeeCap(uint256)");
    }

    // -------------------------------------------------------------------------
    // Reading the state a proposal is about to change
    // -------------------------------------------------------------------------

    /// @notice Prints what the two contracts hold today. Read this before proposing anything.
    /// @dev A parameter change is only reviewable against the value it replaces.
    function state() external view {
        PlumbVault vault = _vault();
        QuoteModule quote = _quote();

        console2.log("vault              :", address(vault));
        console2.log("quoteModule        :", address(quote));
        console2.log("owner (vault)      :", vault.owner());
        console2.log("owner (quote)      :", quote.owner());
        console2.log("operator           :", vault.operator());
        console2.log("paused             :", vault.paused());
        console2.log("epoch              :", vault.epoch());
        console2.log("epochBudget        :", vault.epochBudget());
        console2.log("remainingBudget    :", vault.remainingBudget());
        console2.log("maxBookBps         :", vault.maxBookBps());
        console2.log("maxSingleFill      :", vault.maxSingleFill());
        console2.log("perfFeeBps         :", vault.perfFeeBps());
        console2.log("feeRecipient       :", vault.feeRecipient());
        console2.log("totalAssets        :", vault.totalAssets());
        console2.log("blueFloorMarginBps :", quote.blueFloorMarginBps());
        console2.log("continuousFeeCap   :", quote.continuousFeeCap());
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _vault() internal view returns (PlumbVault) {
        return PlumbVault(vm.envAddress("VAULT"));
    }

    /// @dev Read off the vault rather than the environment: the pair is fixed at deployment (the
    ///      vault takes the module in its constructor), so asking for it again could only be a way
    ///      to get it wrong.
    function _quote() internal view returns (QuoteModule) {
        return _vault().QUOTE();
    }

    /// @dev Simulates, then prints. Never the other way round: a triplet that has not been
    ///      executed is a proposal nobody has checked.
    function _propose(address target, bytes memory data, string memory label) internal {
        _simulate(target, data);

        console2.log("");
        console2.log("--- %s ---", label);
        console2.log("to    :", target);
        console2.log("value : 0");
        console2.log("data  :", vm.toString(data));
        console2.log("");
        console2.log("Paste into the Safe Transaction Builder as a raw transaction.");
        console2.log("This script signs nothing and broadcasts nothing.");
    }

    function _propose(PlumbVault vault, bytes memory data, string memory label) internal {
        _propose(address(vault), data, label);
    }

    function _propose(QuoteModule quote, bytes memory data, string memory label) internal {
        _propose(address(quote), data, label);
    }

    /// @dev Runs the call as the owner against current chain state. A proposal that reverts here
    ///      would revert in the Safe, after the signers had spent their time on it.
    ///
    ///      `ADMIN_SIMULATE=false` skips it. Two cases need that: a call that reaches Midnight
    ///      (`forge script` runs its own EVM below `osaka` on an OP chainId, and Midnight reverts
    ///      with `NotActivated` — an artefact of the harness, not of the proposal), and a proposal
    ///      built against a state that does not exist yet, such as an `unpause()` prepared before
    ///      the pause.
    function _simulate(address target, bytes memory data) internal {
        if (!vm.envOr("ADMIN_SIMULATE", true)) {
            console2.log("simulation : SKIPPED (ADMIN_SIMULATE=false)");
            return;
        }

        address owner = _vault().owner();
        // Snapshot around the call so the dry-run stays a dry-run. `forge script` would discard
        // these writes anyway, but nothing else that runs this code would — and a "simulation"
        // whose side effects depend on the harness is not one.
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        (bool ok, bytes memory ret) = target.call(data);
        vm.revertToState(snap);
        if (!ok) {
            console2.log("simulation : REVERTED as owner", owner);
            console2.logBytes(ret);
            revert("Admin: the call reverts against current state, not proposing it");
        }
        console2.log("simulation : ok, as owner", owner);
    }
}
