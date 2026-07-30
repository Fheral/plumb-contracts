// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";
import {IMidnight, Market, CollateralParams} from "../src/interfaces/midnight/IMidnight.sol";
import {BlueMarketParams} from "../src/interfaces/IMorphoBlue.sol";

/// @notice Deploys Plumb on Base mainnet.
///
/// @dev The counterpart of `DeployLocal.s.sol`, and a separate file rather than a flag on it. That
///      script hands the operator a key everyone knows, makes the deployer both `owner` and
///      `feeRecipient`, opens a book at half the NAV and opens an epoch on the spot — four things
///      that are right on a throwaway chain and indefensible here. A flag would have made those
///      the defaults, with production as the exception you remember to tick.
///
///      So the guardrails run the other way round. Local refuses a non-local RPC; this refuses a
///      local one, refuses any chain that is not Base, and refuses to deploy if the deployer would
///      end up holding any authority — `owner` and `operator` must be other addresses. That last
///      check is the one that matters: copy-pasting the local invocation is by far the most likely
///      way this goes wrong, and it is the failure that cannot be undone afterwards.
///
///      Parameters come from `CALIBRATION.md`, as constants rather than environment variables: the
///      numbers Plumb prices with are reviewed in a PR, not typed on a command line the night of
///      the deployment. Addresses are the only thing read from the environment, because they are
///      the only thing that is not a decision about the policy.
///
///      **`openEpoch` is deliberately not called.** The local script opens one so the dev book is
///      not empty; here, opening an epoch is what starts the quoting, and it is an operational act
///      with its own moment. Use `script/Admin.s.sol --sig 'openEpoch()'` when the desk is ready.
///
///      ```sh
///      DEPLOYER_PRIVATE_KEY=… OWNER=… OPERATOR=… FEE_RECIPIENT=… \
///        forge script script/DeployMainnet.s.sol --rpc-url base --broadcast --verify
///      ```
contract DeployMainnet is Script {
    IMidnight constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    address constant BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // The Midnight market Plumb starts on: USDC lent, WETH + WETH-USDC-collat, maturity 2026-09-24.
    uint256 constant MATURITY = 1790208000;
    address constant ORACLE_WETH = 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4;
    address constant COLL2 = 0xe690a58EF52854513462745237F6A213a0d54dF1;
    address constant ORACLE_COLL2 = 0x784519B1b59A1e1498f077066bB9336672bcc3EE;

    address constant BLUE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    uint256 constant BLUE_LLTV = 0.86e18;

    // --- policy, from CALIBRATION.md -----------------------------------------

    /// @dev Base target rate. The book prints 3.6–3.7%; Plumb bids well wider, and that gap is the
    ///      depositors' yield.
    uint16 constant RATE_BPS = 900;
    /// @dev Collateral premium, carried by the token rather than the market. `QuoteModule` takes
    ///      the worst spread of a market's basket, so these two are what the WETH markets quote:
    ///      `WETH-USDC-collat` at 98% LLTV alongside WETH at 86% resolves to 250 either way.
    uint16 constant VOL_SPREAD_BPS = 250;
    /// @dev LLTV ceilings, per collateral. A market that lets a borrower draw more than this
    ///      against the token is refused outright — a thinner equity buffer than we underwrote is
    ///      not something a spread can fix after the fact.
    uint64 constant MAX_LLTV_WETH = 0.86e18;
    uint64 constant MAX_LLTV_COLL2 = 0.98e18;
    /// @dev Inventory skew, applied pro rata up to the per-market unit cap. 900 + 250 + 600 = 1750,
    ///      comfortably under `MAX_RATE_BPS`: the clamp must never bite before the book is full, or
    ///      a full book and a three-quarters-full one would quote the same price.
    uint16 constant SKEW_BPS = 600;
    uint32 constant MIN_TENOR = 1 days;
    uint32 constant MAX_TENOR = 90 days;

    // --- risk, Phase 4 opening settings --------------------------------------

    /// @dev Per-market unit cap, as a fraction of NAV. Equal to the book cap: one market may be the
    ///      whole book, which is the same relationship the absolute cap encoded before (25,000 of a
    ///      100,000 deposit cap). Expressed as a ratio, it now holds at every vault size instead of
    ///      only at the cap — and it keeps the skew alive on a small vault, where an absolute cap
    ///      sized for the launch ceiling made it saturate at barely a basis point.
    uint16 constant MAX_UNITS_BPS = 2_500;
    /// @dev Book capped at 25% of NAV. Three quarters of the capital stays on Blue, withdrawable on
    ///      demand — the opposite of the local script's 50%, and the point of a capped run.
    uint256 constant MAX_BOOK_BPS = 2_500;
    /// @dev Largest single fill. A lot this size is the most one seller can concentrate on Plumb in
    ///      one go.
    uint128 constant MAX_SINGLE_FILL = 10_000e6;
    /// @dev Absolute ceiling on the vault's NAV for the Phase 4 run — the only cap that is not a
    ///      ratio, and therefore the only one that bounds what a bug can reach. 100k USDC is four
    ///      times the per-market cap at that NAV and ten times `MAX_SINGLE_FILL`: large enough that
    ///      the book cap, the per-market cap and the fill cap are all reachable and get exercised
    ///      for real, small
    ///      enough to be a sum this desk is willing to lose entirely. Raised by the multisig once
    ///      the external audit is in — that is the sequencing `PLAN.md` states, and until now
    ///      nothing enforced it.
    uint256 constant DEPOSIT_CAP = 100_000e6;

    /// @notice Everything that must be true before a single transaction is signed.
    ///
    /// @dev Split out of `run()` and taking its arguments explicitly, so the guardrails can be
    ///      exercised for what they are — plain conditions on four addresses — instead of through
    ///      the environment. Same code path either way: `run()` calls this and nothing else does
    ///      the checking.
    function guard(address deployer, address owner, address operator, address feeRecipient) public view {
        require(block.chainid == 8453, "DeployMainnet: not Base");
        // A forked anvil keeps Base's chainId, so the chain check alone proves nothing. This is the
        // mirror of `DeployLocal._isLocalRpc`, and it exists so that a rehearsal on a fork cannot
        // be mistaken for the real thing — or the real thing for a rehearsal.
        require(!_isLocalRpc(), "DeployMainnet: local RPC, this script is for Base");

        // The deployer holds a hot key. It signs the deployment and must hold nothing afterwards:
        // no ownership, no operator role, no fee stream. These three checks are the guardrail
        // against the likely accident — the local invocation, copied.
        require(owner != deployer, "DeployMainnet: owner must not be the deployer");
        require(operator != deployer, "DeployMainnet: operator must not be the deployer");
        require(feeRecipient != deployer, "DeployMainnet: feeRecipient must not be the deployer");
        require(owner != operator, "DeployMainnet: the multisig must not also be the bot key");
        require(owner != address(0) && operator != address(0) && feeRecipient != address(0), "DeployMainnet: zero");
    }

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envAddress("OWNER");
        address operator = vm.envAddress("OPERATOR");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        guard(deployer, owner, operator, feeRecipient);

        vm.startBroadcast(pk);

        // Owned by the multisig from the first block: there is no window in which the deployer
        // could set a policy of its own.
        QuoteModule quote = new QuoteModule(owner);
        PlumbVault vault = new PlumbVault(
            "Plumb Exit Liquidity USDC",
            "plUSDC",
            USDC,
            address(MIDNIGHT),
            BLUE,
            address(quote),
            owner,
            feeRecipient,
            DEPOSIT_CAP
        );

        // `touchMarket` is idempotent: the market exists on Base, the call returns its identifier.
        bytes32 id = MIDNIGHT.touchMarket(_midnightMarket());

        vm.stopBroadcast();

        _report(vault, quote, id, owner, operator, feeRecipient);
    }

    /// @dev Everything after the two deployments is `onlyOwner`, therefore the multisig's, therefore
    ///      not this script's to broadcast. What it can do is spell out the calls, in order, so the
    ///      Safe proposals are built from a list rather than from memory. `script/Admin.s.sol`
    ///      composes each one, simulates it and prints its calldata.
    function _report(
        PlumbVault vault,
        QuoteModule quote,
        bytes32 id,
        address owner,
        address operator,
        address feeRecipient
    ) internal {
        string memory json = string.concat(
            '{\n  "vault": "',
            vm.toString(address(vault)),
            '",\n  "quoteModule": "',
            vm.toString(address(quote)),
            '",\n  "marketId": "',
            vm.toString(id),
            '",\n  "owner": "',
            vm.toString(owner),
            '",\n  "operator": "',
            vm.toString(operator),
            '",\n  "feeRecipient": "',
            vm.toString(feeRecipient),
            '",\n  "midnight": "',
            vm.toString(address(MIDNIGHT)),
            '",\n  "usdc": "',
            vm.toString(USDC),
            '",\n  "startBlock": ',
            vm.toString(block.number),
            "\n}\n"
        );
        vm.writeFile("deployments/base.json", json);

        console2.log("vault       :", address(vault));
        console2.log("quoteModule :", address(quote));
        console2.log("marketId    :", vm.toString(id));
        console2.log("startBlock  :", block.number);
        console2.log("");
        console2.log("Deployed, and quoting nothing. The multisig owns both contracts; every call");
        console2.log("below is its own, in this order. Build each with script/Admin.s.sol.");
        console2.log("");
        console2.log(" 1. quote.setVault(vault)                  -- until this, maxTick reverts");
        console2.log(" 2. quote.setBasePolicy(...)               -- rate %s, skew %s", RATE_BPS, SKEW_BPS);
        console2.log(" 3. quote.setCollateralPolicy(WETH, ...)   -- and COLL2. THIS is what selects markets:", "");
        console2.log("    approving a collateral makes every maturity on it quotable, forever.");
        console2.log(" 4. vault.setBlueMarket(...)               -- where the idle sleeve earns");
        console2.log(" 5. vault.setRiskParams(%s, %s)", MAX_BOOK_BPS, MAX_SINGLE_FILL);
        console2.log("    (the deposit cap is already %s -- set in the constructor)", DEPOSIT_CAP);
        console2.log(" 6. vault.setOperator(operator)            -- the bot may quote from here on");
        console2.log(" 7. vault.openEpoch(budget)                -- LAST, and only when ready:");
        console2.log("    this is what starts the quoting. Nothing above it moves any capital.");
    }

    /// @dev The exact mirror of `DeployLocal._isLocalRpc`. Kept duplicated rather than shared: the
    ///      two scripts must be readable, and refusable, on their own.
    function _isLocalRpc() internal view returns (bool) {
        try vm.rpcUrl("local") returns (string memory rpc) {
            return _contains(rpc, "127.0.0.1") || _contains(rpc, "localhost");
        } catch {
            // No `local` endpoint configured at all: certainly not running against one.
            return false;
        }
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || h.length < n.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// @notice The market-independent half of the policy. Exposed so the deployment and the
    ///         proposals that follow it read the same numbers from the same place.
    function basePolicy() public pure returns (QuoteModule.BasePolicy memory) {
        return QuoteModule.BasePolicy({
            rateBps: RATE_BPS, skewBps: SKEW_BPS, minTenor: MIN_TENOR, maxTenor: MAX_TENOR, maxUnitsBps: MAX_UNITS_BPS
        });
    }

    /// @notice The collateral Plumb underwrites, and at what premium. Approving these two is what
    ///         makes the WETH markets quotable — every maturity of them, present and future.
    function collateralPolicies()
        public
        pure
        returns (address[] memory tokens, QuoteModule.CollateralPolicy[] memory policies)
    {
        tokens = new address[](2);
        policies = new QuoteModule.CollateralPolicy[](2);
        tokens[0] = WETH;
        policies[0] =
            QuoteModule.CollateralPolicy({allowed: true, volSpreadBps: VOL_SPREAD_BPS, maxLltv: MAX_LLTV_WETH});
        tokens[1] = COLL2;
        policies[1] =
            QuoteModule.CollateralPolicy({allowed: true, volSpreadBps: VOL_SPREAD_BPS, maxLltv: MAX_LLTV_COLL2});
    }

    function blueMarket() public pure returns (BlueMarketParams memory) {
        return
            BlueMarketParams({
                loanToken: USDC, collateralToken: WETH, oracle: ORACLE_WETH, irm: BLUE_IRM, lltv: BLUE_LLTV
            });
    }

    function _midnightMarket() internal pure returns (Market memory m) {
        CollateralParams[] memory cps = new CollateralParams[](2);
        cps[0] = CollateralParams(WETH, 0.86e18, 0.3e18, ORACLE_WETH);
        cps[1] = CollateralParams(COLL2, 0.98e18, 0.3e18, ORACLE_COLL2);
        m = Market({
            chainId: 8453,
            midnight: address(MIDNIGHT),
            loanToken: USDC,
            collateralParams: cps,
            maturity: MATURITY,
            rcfThreshold: 3e9,
            enterGate: address(0),
            liquidatorGate: address(0)
        });
    }
}
