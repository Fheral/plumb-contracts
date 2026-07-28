// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {PlumbVault} from "../src/PlumbVault.sol";
import {QuoteModule} from "../src/QuoteModule.sol";
import {IMidnight, Market, CollateralParams} from "../src/interfaces/midnight/IMidnight.sol";
import {BlueMarketParams} from "../src/interfaces/IMorphoBlue.sol";

/// @notice Deploys the vault on an anvil fork of Base, for local development.
///
/// @dev Local-fork only, and the script refuses to run anywhere else. It hands the operator an
///      anvil key known to everyone and sets loose risk parameters — two things that only make
///      sense on a throwaway chain. The mainnet deployment is `DeployMainnet.s.sol`, a separate
///      script reviewed on its own rather than a flag added here: that is the difference between a
///      guardrail and a checkbox to untick.
///
///      The fork carries the real Midnight, Morpho Blue and USDC of Base. Nothing is simulated:
///      the markets exist, the oracles respond, and the bot's write path is exercised against the
///      protocol's real code.
contract DeployLocal is Script {
    IMidnight constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    address constant BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // Real Midnight market on Base: USDC lent, WETH + wstETH collateral, maturity 2026-09-24.
    uint256 constant MATURITY = 1790208000;
    address constant ORACLE_WETH = 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4;
    address constant COLL2 = 0xe690a58EF52854513462745237F6A213a0d54dF1;
    address constant ORACLE_COLL2 = 0x784519B1b59A1e1498f077066bB9336672bcc3EE;

    address constant BLUE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    uint256 constant BLUE_LLTV = 0.86e18;

    function run() external {
        // A forked anvil keeps Base's chainId. So we make sure the RPC really is local before
        // entrusting anything to a publicly known key.
        require(_isLocalRpc(), "DeployLocal: non-local RPC, refusing to deploy");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address operator = vm.envAddress("OPERATOR_ADDRESS");

        vm.startBroadcast(pk);

        QuoteModule quote = new QuoteModule(deployer);
        PlumbVault vault = new PlumbVault(
            "Plumb Exit Liquidity USDC", "plUSDC", USDC, address(MIDNIGHT), BLUE, address(quote), deployer, deployer
        );

        // `touchMarket` is idempotent: the market already exists on Base, the call merely
        // returns its identifier.
        bytes32 id = MIDNIGHT.touchMarket(_midnightMarket());

        quote.setVault(address(vault));
        quote.setMarketConfig(
            id,
            QuoteModule.MarketConfig({
                enabled: true,
                // The three pricing parameters are the ones `DeployMainnet` ships, and for the
                // same reasons (`CALIBRATION.md`). A local book that priced differently from
                // production would be a rehearsal of something else.
                rateBps: 900,
                volSpreadBps: 250,
                skewBps: 600,
                minTenor: 1 days,
                maxTenor: 90 days,
                maxUnits: 500_000e6
            })
        );

        vault.setBlueMarket(
            BlueMarketParams({
                loanToken: USDC, collateralToken: WETH, oracle: ORACLE_WETH, irm: BLUE_IRM, lltv: BLUE_LLTV
            })
        );
        vault.setRiskParams(5_000, 100_000e6); // book capped at 50% of NAV
        vault.setOperator(operator);

        // Without an open epoch, `remainingBudget` is zero and the quoter broadcasts nothing:
        // the front-end would show a properly configured vault and an eternally empty book, which
        // looks like a bot outage. In production, opening an epoch is a deliberate operational
        // act — here it is the expected starting point.
        vault.openEpoch(100_000e6);

        vm.stopBroadcast();

        _write(vault, quote, id, operator);
    }

    /// @dev Writes the addresses where `dev-local.sh` will look for them to build `.env.local`.
    ///      Without this, every restart would require copying three addresses by hand.
    function _write(PlumbVault vault, QuoteModule quote, bytes32 id, address operator) internal {
        string memory json = string.concat(
            '{\n  "vault": "',
            vm.toString(address(vault)),
            '",\n  "quoteModule": "',
            vm.toString(address(quote)),
            '",\n  "marketId": "',
            vm.toString(id),
            '",\n  "operator": "',
            vm.toString(operator),
            '",\n  "midnight": "',
            vm.toString(address(MIDNIGHT)),
            '",\n  "usdc": "',
            vm.toString(USDC),
            '",\n  "startBlock": ',
            vm.toString(block.number),
            "\n}\n"
        );
        vm.writeFile("deployments/local.json", json);

        console2.log("vault       :", address(vault));
        console2.log("quoteModule :", address(quote));
        console2.log("marketId    :", vm.toString(id));
        console2.log("startBlock  :", block.number);
    }

    function _isLocalRpc() internal view returns (bool) {
        string memory rpc = vm.rpcUrl("local");
        return _contains(rpc, "127.0.0.1") || _contains(rpc, "localhost");
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
