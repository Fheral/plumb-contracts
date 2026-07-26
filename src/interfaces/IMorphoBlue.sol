// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMorpho as IMorphoBlue, MarketParams as BlueMarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

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

    /// @notice Liquidity actually withdrawable from the market at this instant.
    /// @dev What the vault holds is not enough: if borrowers have drawn everything, the withdrawal
    ///      reverts. This is the bound the bot must read before quoting.
    function marketLiquidity(IMorphoBlue blue, BlueMarketParams memory p) internal view returns (uint256) {
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) = blue.expectedMarketBalances(p);
        return totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
    }
}
