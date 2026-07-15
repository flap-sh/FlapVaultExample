// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @title IFlapTaxTokenV3
/// @notice Interface for FlapTaxTokenV3 — the next-generation tax token with asymmetric buy/sell
///         rates and a fixed, bidirectional dynamic liquidation threshold.
/// @dev Launched via Portal.newTokenV6() with tokenVersion = TOKEN_TAXED_V3.
///      Tax is applied on DEX trades:
///        - buy  (someone buys from a pool): `buyTaxRate` bps taken and sent to taxProcessor
///        - sell (someone sells into a pool): `sellTaxRate` bps taken and sent to taxProcessor
///      While still on the bonding curve (PoolState.BondingCurve) no token-level tax is applied;
///      the Portal's `processBondingCurveTax()` handles curve-phase tax directly.

/// @dev Example: token $FLAPC at 0x05d2ee3c60951af1e72f7d002220b2960bc77777,
///      taxProcessor 0xae225e6c9a539dd96858ba13890a9b4a61f20e8c (empty test wallet,
///      used here only to illustrate where the tax lands — no real funds involved).
///      buyTaxRate = 100 (1%), sellTaxRate = 100 (1%).
///
///      - state == BondingCurve: no token-level tax; Portal.processBondingCurveTax()
///        handles it directly on the curve, buy/sell rates below don't apply yet.
///      - state == TaxEnforcedAntiFarmer (post-migration): a buy of 1 ETH worth of
///        $FLAPC sends 0.01 ETH-equivalent (1%) to taxProcessor, 0.99 ETH-equivalent
///        is swapped into tokens for the buyer. Any transfer, not just pool trades,
///        is taxed in this window.
///      - state == TaxEnforced: a sell of 10,000 $FLAPC into the main pool withholds
///        100 tokens (1%) to taxProcessor, 9,900 tokens' worth is sold into the pool.
///        Wallet-to-wallet transfers outside the main pool are no longer taxed here.
///      - state == TaxFree (after antiFarmerDuration elapses): buyTaxRate and
///        sellTaxRate stop applying; $FLAPC trades tax-free from then on.
interface IFlapTaxTokenV3 is IERC20 {


interface IFlapTaxTokenV3 is IERC20 {
    /// @notice Enum to represent the state of the pool.
    enum PoolState {
        BondingCurve, // state0: Token is trading on the bonding curve, no DEX tax
        Migrating, // state1: Token is migrating to DEX
        TaxEnforcedAntiFarmer, // state2: DEX listed, tax applied for any pool transfer (anti-farmer window)
        TaxEnforced, // state3: DEX listed, tax applied for main pool transfers only
        TaxFree // state4: Tax duration elapsed, token is tax-free
    }

    /// @notice Emitted when the pool state transitions.
    event PoolStateChanged(uint8 fromState, uint8 toState);

    /// @notice Emitted when tokens are burned for deflation.
    event TokensBurned(uint256 amount);

    /// @notice Emitted when tax liquidation fails.
    event TaxLiquidationError(bytes reason);

    /// @notice Custom transfer event for easier indexing.
    event TransferFlapToken(address from, address to, uint256 value);

    /// @notice Returns the effective (worst-case) tax rate in basis points.
    /// @dev Returns max(buyTaxRate, sellTaxRate) for backward compatibility.
    function taxRate() external view returns (uint16);

    /// @notice Returns the buy tax rate in basis points (applied when buying from a pool).
    function buyTaxRate() external view returns (uint16);

    /// @notice Returns the sell tax rate in basis points (applied when selling into a pool).
    function sellTaxRate() external view returns (uint16);

    /// @notice Returns the address of the TaxProcessor contract for this token.
    function taxProcessor() external view returns (address);

    /// @notice Returns the address of the dividend tracking contract.
    function dividendContract() external view returns (address);

    /// @notice Returns the minimum liquidation threshold.
    function MIN_LIQ_THRESHOLD() external view returns (uint256);

    /// @notice Returns the starting liquidation threshold.
    function START_LIQ_THRESHOLD() external view returns (uint256);

    /// @notice Returns the initial liquidation threshold stored at initialization time.
    function initialLiquidationThreshold() external view returns (uint256);

    /// @notice Returns the current liquidation threshold.
    function liquidationThreshold() external view returns (uint256);

    /// @notice Returns the anti-farmer duration in seconds.
    function antiFarmerDuration() external view returns (uint256);

    /// @notice Returns the IPFS CID of the metadata JSON.
    function metaURI() external view returns (string memory);

    /// @notice Returns the main V2 pool address for this token.
    function mainPool() external view returns (address);

    /// @notice Returns the current pool state.
    function state() external view returns (PoolState);
}
