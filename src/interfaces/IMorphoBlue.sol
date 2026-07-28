// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMorpho as IMorphoBlue, MarketParams as BlueMarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {IIrm} from "morpho-blue/interfaces/IIrm.sol";

uint256 constant BLUE_WAD = 1e18;
uint256 constant SECONDS_PER_YEAR = 365 days;

/// @notice Small views over Morpho Blue, exposed in call syntax to stay readable on the vault side.
library BlueLib {
    using MarketParamsLib for BlueMarketParams;
    using MorphoBalancesLib for IMorphoBlue;

    /// @notice `user`'s position on this market, accrued interest included.
    function expectedSupplyAssets(IMorphoBlue blue, BlueMarketParams memory p, address user)
        internal
        view
        returns (uint256)
    {
        return blue.expectedSupplyAssets(p, user);
    }

    /// @notice The supply shares `user` holds on this market.
    /// @dev Emptying a position has to be done in shares, not in assets: Blue converts assets to
    ///      shares by rounding up, so a withdrawal of `expectedSupplyAssets` can ask for one share
    ///      more than the position holds and revert. Withdrawing the shares themselves is the only
    ///      expression of "all of it" that cannot be off by one.
    function supplyShares(IMorphoBlue blue, BlueMarketParams memory p, address user) internal view returns (uint256) {
        return blue.position(p.id(), user).supplyShares;
    }

    /// @notice Liquidity actually withdrawable from the market at this instant.
    /// @dev What the vault holds is not enough: if borrowers have drawn everything, the withdrawal
    ///      reverts. This is the bound the bot must read before quoting.
    function marketLiquidity(IMorphoBlue blue, BlueMarketParams memory p) internal view returns (uint256) {
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = blue.expectedMarketBalances(p);
        return totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
    }

    /// @notice Annualized supply rate of the market, in basis points.
    ///
    /// @dev This is what the idle sleeve earns while it waits — hence the opportunity cost of every
    ///      unit Plumb buys. `QuoteModule` uses it as a hard floor on the bid rate.
    ///
    ///      Blue does not expose a supply rate: it exposes a borrow rate per second, from which the
    ///      supply side follows by `borrowRate * utilization * (1 - fee)`. Simple annualization, no
    ///      compounding — the same convention the bid itself uses, which is what makes the two
    ///      numbers comparable at all.
    ///
    ///      An IRM that reverts on `borrowRateView` would make the bid unquotable rather than
    ///      merely unfloored, so the failure is swallowed and reported as a zero floor. That is the
    ///      safe direction only because a zero floor is the behaviour Plumb had before the floor
    ///      existed; the market's IRM is a governance choice, not an attacker-controlled input.
    function supplyRateBps(IMorphoBlue blue, BlueMarketParams memory p) internal view returns (uint256) {
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = blue.expectedMarketBalances(p);
        if (totalSupplyAssets == 0) return 0;
        // A market with no IRM borrows at zero. Calling into address(0) would return empty data,
        // and a decode failure is not something `try` catches.
        if (p.irm == address(0)) return 0;

        Id id = p.id();
        try IIrm(p.irm).borrowRateView(p, blue.market(id)) returns (uint256 borrowRatePerSecond) {
            uint256 fee = blue.market(id).fee;
            uint256 supplyRatePerSecond =
                (borrowRatePerSecond * totalBorrowAssets * (BLUE_WAD - fee)) / (totalSupplyAssets * BLUE_WAD);
            return (supplyRatePerSecond * SECONDS_PER_YEAR * 10_000) / BLUE_WAD;
        } catch {
            return 0;
        }
    }
}
