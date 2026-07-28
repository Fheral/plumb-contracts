// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, console2} from "forge-std/Test.sol";
import {IMidnight, Market, CollateralParams, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {IdLib} from "../src/interfaces/midnight/IdLib.sol";
import {BlueMarketParams, IMorphoBlue} from "../src/interfaces/IMorphoBlue.sol";
import {TickLib as TickLibView} from "../src/interfaces/midnight/TickLib.sol";

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @dev Permissive ratifier, used only for test counterparties (the borrower originating the
///      loan). Plumb itself is its own ratifier and enforces its policy on-chain.
contract AlwaysRatifier {
    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return keccak256("morpho.midnight.callbackSuccess");
    }
}

/// @notice Base-fork foundation: production addresses, Midnight market creation, and a
///         collateralized borrower able to originate loans to feed the tests.
abstract contract MidnightForkBase is Test {
    IMidnight constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    address constant BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    IERC20Like constant USDC = IERC20Like(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // Real Midnight market: USDC lent, WETH + wstETH collateral, maturity 2026-09-24.
    uint256 constant MATURITY = 1790208000;
    address constant ORACLE_WETH = 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4;
    address constant COLL2 = 0xe690a58EF52854513462745237F6A213a0d54dF1;
    address constant ORACLE_COLL2 = 0x784519B1b59A1e1498f077066bB9336672bcc3EE;

    // Morpho Blue market where idle capital sits: USDC/WETH 86%, ~7.5M liquidity.
    address constant BLUE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    uint256 constant BLUE_LLTV = 0.86e18;

    address BORROWER = makeAddr("BORROWER");
    address SELLER = makeAddr("SELLER"); // the lender who will want out before maturity
    address LP = makeAddr("LP");

    AlwaysRatifier ratifier;
    bytes32 id;

    /// @dev Default fork block. Pinning it is not cosmetic: on `latest`, the fork cache is
    ///      invalidated on every run, and a fuzz campaign ends up rate-limited by the RPC — the
    ///      failure then looks like a property failure without being one. A fixed block also makes
    ///      counterexamples reproducible. `BASE_FORK_BLOCK=0` to follow the head.
    uint256 constant DEFAULT_FORK_BLOCK = 49070562;

    function _forkSetUp() internal {
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", DEFAULT_FORK_BLOCK);
        if (forkBlock == 0) {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        } else {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"), forkBlock);
        }
        ratifier = new AlwaysRatifier();
        id = MIDNIGHT.touchMarket(midnightMarket());

        deal(address(USDC), SELLER, 1_000_000e6);
        deal(address(USDC), LP, 1_000_000e6);
        deal(WETH, BORROWER, 5000e18);

        vm.prank(SELLER);
        USDC.approve(address(MIDNIGHT), type(uint256).max);
        vm.prank(BORROWER);
        IERC20Like(WETH).approve(address(MIDNIGHT), type(uint256).max);
        vm.prank(BORROWER);
        MIDNIGHT.setIsAuthorized(address(ratifier), true, BORROWER);
        vm.prank(BORROWER);
        MIDNIGHT.supplyCollateral(midnightMarket(), 0, 3000e18, BORROWER);
    }

    function midnightMarket() internal pure returns (Market memory m) {
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

    function blueMarket() internal pure returns (BlueMarketParams memory) {
        return BlueMarketParams({
            loanToken: address(USDC), collateralToken: WETH, oracle: ORACLE_WETH, irm: BLUE_IRM, lltv: BLUE_LLTV
        });
    }

    /// @notice A second, distinct Blue market on the same loan token — the destination of a sleeve
    ///         migration.
    /// @dev Same IRM and LLTV, different collateral, hence a different market id. Created on the
    ///      fork rather than picked from Base, so the test does not depend on a second production
    ///      market keeping its parameters. Supplying never reads the oracle, which is all this
    ///      market is ever asked to do.
    function otherBlueMarket() internal pure returns (BlueMarketParams memory) {
        return BlueMarketParams({
            loanToken: address(USDC), collateralToken: COLL2, oracle: ORACLE_COLL2, irm: BLUE_IRM, lltv: BLUE_LLTV
        });
    }

    function _createOtherBlueMarket() internal {
        IMorphoBlue(BLUE).createMarket(otherBlueMarket());
    }

    /// @dev Originates `units` of loan at an annualized `rateBps`: the borrower sells, `lender` buys.
    function _originate(address lender, uint256 units, uint256 rateBps) internal {
        uint256 tenor = MATURITY - block.timestamp;
        uint256 price = 1e18 - (rateBps * 1e18 * tenor) / (10_000 * 365 days);
        Offer memory o = Offer({
            market: midnightMarket(),
            buy: false,
            maker: BORROWER,
            start: 0,
            expiry: type(uint256).max,
            tick: _tickAtOrBelow(price),
            group: keccak256(abi.encode("origination", block.timestamp, units)),
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

    function _tickAtOrBelow(uint256 priceWad) internal view returns (uint256) {
        uint8 spacing = MIDNIGHT.tickSpacing(id);
        uint256 t = TickLibView.priceToTick(priceWad, spacing);
        if (TickLibView.tickToPrice(t) > priceWad) t -= spacing;
        return t;
    }
}
