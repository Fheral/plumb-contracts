// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IMidnight, Market, CollateralParams, Offer} from "../src/interfaces/midnight/IMidnight.sol";
import {TickLib as TickLibView} from "../src/interfaces/midnight/TickLib.sol";
import {IdLib} from "../src/interfaces/midnight/IdLib.sol";

interface IERC20Like {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

/// @dev Permissive ratifier. It only serves the test counterparties — the borrower originating the
///      loan. Plumb, on the other hand, is its own ratifier and enforces its on-chain policy: that
///      is exactly what we want to exercise, so nothing here loosens it.
contract AlwaysRatifier {
    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return keccak256("morpho.midnight.callbackSuccess");
    }
}

/// @notice Seed origination, performed **from the chain** and not from `forge`'s EVM.
///
/// @dev Why a contract rather than a few `vm.broadcast` calls in the script: `forge script`
///      first executes the whole script body in its own EVM, and that EVM ignores
///      `evm_version = "osaka"` as soon as the chainId belongs to a known OP chain — 8453 in
///      this case. It falls back to a spec without `CLZ` (EIP-7939), and `take()` fails with
///      `NotActivated` before it is even broadcast. `forge test` does not share this flaw, hence a
///      green suite and a broken seed.
///
///      The chainId is non-negotiable — it is part of the `Market`, therefore of the `marketId`.
///      So we move the call: the script merely deploys this contract and grants the
///      authorizations, then `seed()` is invoked by a real transaction (`cast send`). The code
///      then runs in anvil's EVM, which is properly on osaka.
///
///      Spec probe, if the symptom reappears:
///        `cast call --create 0x60011e5f5260205ff3` → 0xff expected, `NotActivated` otherwise.
contract Seeder {
    IMidnight constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    uint256 constant MATURITY = 1790208000;
    address constant ORACLE_WETH = 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4;
    address constant COLL2 = 0xe690a58EF52854513462745237F6A213a0d54dF1;
    address constant ORACLE_COLL2 = 0x784519B1b59A1e1498f077066bB9336672bcc3EE;

    uint256 constant UNITS = 100_000e6;
    uint256 constant COLLATERAL = 100 ether;

    AlwaysRatifier public immutable ratifier;

    /// @dev The contract is the borrower: it carries the collateral and is the maker of the
    ///      origination offer. The seller stays an EOA — they are the one who will resell to Plumb
    ///      from `fork-scenario.ts`, so they must remain an autonomous counterparty.
    constructor() payable {
        ratifier = new AlwaysRatifier();
    }

    /// @notice Collateralizes the contract and makes it ready to originate. Callable by anyone.
    function prepare() external {
        MIDNIGHT.touchMarket(_market());

        // The collateral comes from wrapped ETH: anvil accounts hold 10,000 each, which avoids
        // having to forge a second balance slot. The ENTIRE balance goes in: each faucet
        // origination adds debt to the Seeder, and borrowing capacity is the only thing bounding
        // the number of positions that can be handed out between two resets.
        IWETH(WETH).deposit{value: address(this).balance}();
        IWETH(WETH).approve(address(MIDNIGHT), type(uint256).max);
        MIDNIGHT.setIsAuthorized(address(ratifier), true, address(this));
        MIDNIGHT.supplyCollateral(_market(), 0, IERC20Like(WETH).balanceOf(address(this)), address(this));
    }

    /// @notice Calldata for the origination `take`, to be sent to Midnight **by the seller themselves**.
    ///
    /// @dev Midnight debits the `msg.sender` of the `take`, not the `taker` parameter: the call
    ///      therefore cannot be relayed by this contract, which holds no USDC. We have it produce
    ///      the calldata — the painful part is encoding the `Offer` and its eleven fields — and
    ///      `dev-local.sh` sends it from the seller's key.
    ///
    ///      The result is self-contained: the offer is frozen as encoded, nothing is recomputed at
    ///      execution time. The few-block gap between this `call` and the `send` has no effect.
    function takeCalldata(address seller) external view returns (bytes memory) {
        return takeCalldata(seller, UNITS);
    }

    /// @notice Chosen-size variant — the testnet faucet originates positions much smaller than the
    ///         seed: the Seeder's borrowing capacity is shared among all visitors until the next
    ///         reset.
    function takeCalldata(address seller, uint256 units) public view returns (bytes memory) {
        // Origination at 4%: well below the 9% that Plumb bids. The spread is what makes selling
        // into the bid attractive for the seller and the trade profitable for the vault.
        Offer memory o = _sellOffer(units, 400);
        return abi.encodeCall(IMidnight.take, (o, "", units, seller, address(0), address(0), ""));
    }

    /// @notice Credit held by `user` on the seeded market — enough to verify the seed.
    function creditOf(address user) external view returns (uint128) {
        return MIDNIGHT.credit(IdLib.toId(_market()), user);
    }

    function _sellOffer(uint256 units, uint256 rateBps) internal view returns (Offer memory) {
        uint256 tenor = MATURITY - block.timestamp;
        uint256 price = 1e18 - (rateBps * 1e18 * tenor) / (10_000 * 365 days);
        return Offer({
            market: _market(),
            buy: false,
            maker: address(this),
            start: 0,
            expiry: type(uint256).max,
            tick: _tickAtOrBelow(price),
            group: keccak256(abi.encode("plumb.local.seed", block.timestamp, units)),
            callback: address(0),
            callbackData: "",
            receiverIfMakerIsSeller: address(this),
            ratifier: address(ratifier),
            reduceOnly: false,
            maxUnits: uint128(units),
            maxAssets: 0,
            continuousFeeCap: type(uint256).max
        });
    }

    function _tickAtOrBelow(uint256 priceWad) internal view returns (uint256) {
        uint8 spacing = MIDNIGHT.tickSpacing(IdLib.toId(_market()));
        uint256 t = TickLibView.priceToTick(priceWad, spacing);
        if (TickLibView.tickToPrice(t) > priceWad) t -= spacing;
        return t;
    }

    function _market() internal pure returns (Market memory m) {
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

/// @notice Prepares the local fork seed: deploys the `Seeder` and grants it the seller's rights.
///
/// @dev Without the seed, the seller has no position to resell and the local book stays empty —
///      the front-end would show a correct but inert vault, and the bot's write path would never
///      be exercised. That path is precisely the one that has never yet run against a deployed
///      vault.
///
///      This script makes **no** call that reaches `take()`: `dev-local.sh` invokes
///      `Seeder.seed()` via `cast send` right after. See the `Seeder` comment for why.
///
///      The seller keeps their position: the resale to Plumb, done from `fork-scenario.ts`, is
///      what will trigger the `take` on the broadcast bid.
contract LocalSeed is Script {
    IMidnight constant MIDNIGHT = IMidnight(0xAdedD8ab6dE832766Fedf0FaC4992E5C4D3EA18A);
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 borrowerPk = vm.envUint("BORROWER_PRIVATE_KEY");
        uint256 sellerPk = vm.envUint("SELLER_PRIVATE_KEY");
        address seller = vm.addr(sellerPk);

        // The seller must already hold USDC — `fork-scenario.ts fund` provides it, by writing the
        // balance slot directly: there is no legitimate way to create USDC on a fork.
        uint256 sellerUsdc = IERC20Like(USDC).balanceOf(seller);
        require(sellerUsdc >= 200_000e6, "LocalSeed: seller not funded, run `fund` first");

        vm.startBroadcast(borrowerPk);
        Seeder seeder = new Seeder{value: 200 ether}();
        vm.stopBroadcast();

        // The seller pays the `take`'s USDC, which they will send themselves.
        vm.startBroadcast(sellerPk);
        IERC20Like(USDC).approve(address(MIDNIGHT), type(uint256).max);
        vm.stopBroadcast();

        // Written rather than logged: `dev-local.sh` needs the address to chain the two `cast`
        // calls, and reading it from a file beats carving it out of a trace output.
        vm.writeFile("deployments/local-seeder.txt", vm.toString(address(seeder)));

        console2.log("seeder :", address(seeder));
        console2.log("seller :", seller);
    }
}
