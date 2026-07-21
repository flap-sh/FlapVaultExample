// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {IPortal, IPortalTypes, IPortalTradeV2, IPortalCommonTypes} from "../src/flap/IPortal.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IFlapTriggerService, ITriggerReceiver} from "../src/flap/IFlapTriggerService.sol";
import {ITaxProcessor} from "../src/flap/ITaxProcessor.sol";
import {IFlapTaxTokenV3} from "../src/flap/IFlapTaxTokenV3.sol";
import {VanityHelper} from "./lib/VanityHelper.sol";

// ============================================================
//  FlapRobinhoodFixture
// ============================================================

/// @title FlapRobinhoodFixture
/// @notice Foundry test fixture for mainnet-fork testing against Robinhood Chain (chainId=4663).
///
/// @dev ── HOW TO USE ────────────────────────────────────────────────────────────────
///
/// 1. Fork Robinhood Chain mainnet in your `setUp()`:
///
///    ```solidity
///    function setUp() public {
///        _forkRobinhoodMainnet();     // pins the fork to a recent block
///        _labelDeployedAddresses();   // registers human-readable labels in traces
///    }
///    ```
///
/// 2. All Flap protocol addresses are available as constants (see below).
///    Use them directly:
///
///    ```solidity
///    IPortal p = IPortal(PORTAL);
///    IVaultPortal vp = IVaultPortal(payable(VAULT_PORTAL));
///    ```
///
/// 3. Launch a V3 tax token via VaultPortal using the helper:
///
///    ```solidity
///    bytes32 salt = _findVanitySalt(VanityType.VANITY_7777, TOKEN_IMPL_TAXED_V3, PORTAL);
///    IVaultPortalTypes.NewTokenV6WithVaultParams memory params =
///        _buildV3TaxTokenParams(salt, address(myVaultFactory), myVaultData);
///    address token = IVaultPortal(payable(VAULT_PORTAL)).newTokenV6WithVault{value: params.quoteAmt}(params);
///    ```
///
/// 4. Simulate backend execution of a FlapTriggerService request:
///
///    ```solidity
///    _executeTrigger(requestId);
///    ```
///
/// 5. Dispatch tax to the vault (replicates what happens after each trade):
///
///    ```solidity
///    ITaxProcessor(IFlapTaxTokenV3(token).taxProcessor()).dispatch();
///    ```
///
/// 6. ── PRANK CONVENTION (IMPORTANT) ────────────────────────────────────────
///
///    Always use `vm.startPrank(user)` / `vm.stopPrank()` to wrap any block of
///    user actions. NEVER use bare `vm.prank(user)`.
///
///    REASON: Several fixture helpers (e.g. `_sell()`, `_buyOnBC()`) issue more
///    than one external call internally (e.g. `approve` then `swapExactInput`).
///    `vm.prank()` only covers the *next* external call, so the second and
///    subsequent calls inside a helper will revert or execute as the wrong
///    sender, causing silent mis-attribution or unexpected reverts.
///
///    ✅  Correct:
///
///        ```solidity
///        vm.startPrank(user1);
///        _sell(token, amount);   // approve + swapExactInput — both covered
///        vm.stopPrank();
///        ```
///
///    ❌  Wrong:
///
///        ```solidity
///        vm.prank(user1);
///        _sell(token, amount);   // only approve is pranked; swapExactInput is not!
///        ```
///
/// ── DEPLOYED ADDRESSES (Robinhood Chain Mainnet) ──────────────────────────────────
///
///   PORTAL               = 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09
///   VAULT_PORTAL         = 0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B
///   FLAP_TRIGGER_SERVICE = 0xD3421B1b616a72bB88993A0cf75709BB8D532cc1
///   FLAP_GUARDIAN        = 0x0000b48720d3B4ED6BC5031768B07F2b59270000
///   TOKEN_IMPL_TAXED_V3  = 0x7777C8743C88B3aff3cf262135beF2c8b2e83333
///   STANDARD_TOKEN_IMPL  = 0x88882688a067FE97E11C2185b996286e53132222
///   TAX_TOKEN_HELPER     = 0xb10bD2672aE63735d677164A54B573a016f0203C
///
///   NOTE: Robinhood Chain does not currently have a FlapAIProvider (AI Oracle) or
///   FlapCandyBox deployment. Vaults that depend on either of those should not
///   target Robinhood Chain — only FlapTriggerService is available here alongside
///   Portal/VaultPortal. This fixture intentionally omits AI Oracle / Candy Box
///   helpers that exist in `FlapBSCFixture` for that reason.
///
///   This fixture only simulates Robinhood Chain **mainnet** (chainId 4663), not the
///   Robinhood testnet — Robinhood testnet addresses may differ and are out of scope here.
abstract contract FlapRobinhoodFixture is Test, VanityHelper {
    // ──────────────────────────────────────────────────────────────────────────
    //  Gas Budget Constant
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Maximum gas allowed for any single protocol operation in tests.
    /// @dev See `FlapBSCFixture.MAX_OP_GAS` for the full rationale; the same budget
    ///      is reused here since it is a conservative, chain-agnostic ceiling.
    ///
    ///      IMPORTANT FOR VAULT DEVELOPERS:
    ///      Your vault's `initialize()` (called during `newTokenV6WithVault`) and any
    ///      callback invoked by the Flap protocol MUST complete within this budget.
    ///      The `_dispatchTax()` helper uses a tighter 1_000_000 gas cap because dispatch
    ///      is expected to be a simple ETH transfer fan-out.
    uint256 internal constant MAX_OP_GAS = 10_000_000;

    // ──────────────────────────────────────────────────────────────────────────
    //  Protocol Addresses — Robinhood Chain Mainnet
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Flap Portal contract (bonding-curve token launcher and DEX router).
    address internal constant PORTAL = 0x26605f322f7fF986f381bB9A6e3f5DAb0bEaEb09;

    /// @notice VaultPortal contract (creates V2/V3 tax tokens with associated vaults).
    /// @dev This is distinct from Portal. VaultPortal wraps Portal to attach a vault to each token.
    address payable internal constant VAULT_PORTAL = payable(0xe9F7AB7DE8FB8756acbB6a1cd13316a43308197B);

    /// @notice FlapTriggerService — on-chain scheduler for MEV-protected delayed callbacks.
    /// @dev Robinhood Chain has a trigger service on both mainnet and testnet; this fixture
    ///      only wires up the mainnet deployment.
    address internal constant FLAP_TRIGGER_SERVICE = 0xD3421B1b616a72bB88993A0cf75709BB8D532cc1;

    /// @notice FlapGuardian — privileged address for Robinhood Chain vault/factory permissions.
    address internal constant FLAP_GUARDIAN = 0x0000b48720d3B4ED6BC5031768B07F2b59270000;

    /// @notice Known holder of TRIGGER_ROLE on FlapTriggerService (Robinhood Chain mainnet).
    /// @dev This is the backend operator account that calls trigger() in production.
    ///      Used by _executeTrigger() and _executeTriggers() helpers to simulate scheduled callbacks.
    ///      Verified on-chain to hold TRIGGER_ROLE — same operator address as BSC mainnet.
    address internal constant FLAP_TRIGGER_OPERATOR = 0x80c83995FA87B20671B436aaA3a5211C02c1152e;

    // Token implementation addresses (used in vanity salt search)

    /// @notice V3 tax token implementation — use this for new launches via newTokenV6WithVault().
    /// @dev This is the implementation address passed to _findVanitySalt() to predict token addresses.
    ///      Vanity suffix: 7777.
    address internal constant TOKEN_IMPL_TAXED_V3 = 0x7777C8743C88B3aff3cf262135beF2c8b2e83333;

    /// @notice Standard (non-tax) token implementation.
    /// @dev Vanity suffix: 8888.
    address internal constant STANDARD_TOKEN_IMPL = 0x88882688a067FE97E11C2185b996286e53132222;

    /// @notice Tax Token Helper contract deployed on Robinhood Chain.
    address internal constant TAX_TOKEN_HELPER = 0xb10bD2672aE63735d677164A54B573a016f0203C;

    // ──────────────────────────────────────────────────────────────────────────
    //  Interface handles — convenience wrappers for the deployed contracts
    // ──────────────────────────────────────────────────────────────────────────

    IPortal internal portal;
    IVaultPortal internal vaultPortal;
    IFlapTriggerService internal flapTriggerService;

    // ──────────────────────────────────────────────────────────────────────────
    //  Fork Setup
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Create and select a Robinhood Chain mainnet fork, initialise interface handles,
    ///         and label addresses.
    /// @dev Call this in your test's `setUp()`. Requires the `ROBINHOOD_RPC_URL` environment
    ///      variable or the `--fork-url` flag on the forge command line.
    ///
    ///      Example setUp():
    ///        ```solidity
    ///        function setUp() public {
    ///            _forkRobinhoodMainnet();
    ///        }
    ///        ```
    function _forkRobinhoodMainnet() internal {
        string memory rpcUrl = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpcUrl);

        portal = IPortal(PORTAL);
        vaultPortal = IVaultPortal(VAULT_PORTAL);
        flapTriggerService = IFlapTriggerService(FLAP_TRIGGER_SERVICE);

        _labelDeployedAddresses();
    }

    /// @notice Register human-readable labels for all deployed addresses.
    /// @dev Improves trace output readability in forge test -vvv.
    function _labelDeployedAddresses() internal {
        vm.label(PORTAL, "Portal");
        vm.label(VAULT_PORTAL, "VaultPortal");
        vm.label(FLAP_TRIGGER_SERVICE, "FlapTriggerService");
        vm.label(FLAP_GUARDIAN, "FlapGuardian");
        vm.label(TOKEN_IMPL_TAXED_V3, "TokenImpl:TaxedV3");
        vm.label(STANDARD_TOKEN_IMPL, "TokenImpl:Standard");
        vm.label(TAX_TOKEN_HELPER, "TaxTokenHelper");
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Token Launch Helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Build a scaffold `NewTokenV6WithVaultParams` for a V3 tax token with sensible defaults.
    /// @dev The returned struct uses symmetric 5% buy/sell tax, full market allocation (mktBps=10000),
    ///      no dividend, no commission, native ETH as the quote token, and FOUR_FIFTHS graduation
    ///      threshold. You can override any field before passing to `newTokenV6WithVault()`.
    ///
    ///      Usage pattern:
    ///        ```solidity
    ///        bytes32 salt = _findVanitySalt(VanityType.VANITY_7777, TOKEN_IMPL_TAXED_V3, PORTAL);
    ///        IVaultPortalTypes.NewTokenV6WithVaultParams memory p =
    ///            _buildV3TaxTokenParams("MyToken", "MTK", salt, address(factory), vaultData);
    ///        p.buyTaxRate = 300;   // override: 3% buy tax
    ///        p.mktBps     = 5000; // override: 50% to vault, 50% to LP
    ///        address token = vaultPortal.newTokenV6WithVault{value: p.quoteAmt}(p);
    ///        ```
    ///
    /// @param name        Token name (e.g., "My Token").
    /// @param symbol      Token symbol (e.g., "MTK").
    /// @param salt        Vanity salt — must produce a token address ending in 0x7777 (VANITY_7777).
    ///                    Use `_findVanitySalt(VanityType.VANITY_7777, TOKEN_IMPL_TAXED_V3, PORTAL)`.
    /// @param vaultFactory Address of the registered VaultFactory to use.
    /// @param vaultData   ABI-encoded constructor arguments expected by the VaultFactory.
    /// @return params     A fully populated struct ready to pass to `vaultPortal.newTokenV6WithVault()`.
    function _buildV3TaxTokenParams(
        string memory name,
        string memory symbol,
        bytes32 salt,
        address vaultFactory,
        bytes memory vaultData
    ) internal pure returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory params) {
        params = IVaultPortalTypes.NewTokenV6WithVaultParams({
                name: name,
                symbol: symbol,
                meta: "",
                dexThresh: IPortalCommonTypes.DexThreshType.FOUR_FIFTHS,
                salt: salt,
                migratorType: IPortalTypes.MigratorType.V2_MIGRATOR,
                quoteToken: address(0), // native ETH
                quoteAmt: 0,
                permitData: "",
                extensionID: bytes32(0),
                extensionData: "",
                dexId: IPortalTypes.DEXId.DEX0,
                lpFeeProfile: IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD,
                // tax fields (symmetric 5%)
                buyTaxRate: 500, // 5%
                sellTaxRate: 500, // 5%
                taxDuration: uint64(100 * 365 days),
                antiFarmerDuration: uint64(1 days),
                // allocation: all market revenue flows to the vault
                mktBps: 10000, // 100% of remainder → vault
                deflationBps: 0,
                dividendBps: 0,
                lpBps: 0,
                minimumShareBalance: 0,
                dividendToken: address(0),
                commissionReceiver: address(0),
                tokenVersion: IPortalTypes.TokenVersion.TOKEN_TAXED_V3,
                vaultFactory: vaultFactory,
                vaultData: vaultData
            });
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  FlapTriggerService Simulation Helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Simulate the FlapTriggerService backend executing a pending trigger.
    /// @dev Pranks as an address that holds TRIGGER_ROLE on the deployed FlapTriggerService.
    ///      The requester's `trigger(requestId)` callback is invoked with the same gas cap
    ///      as the real backend (`getMaxCallbackGas()`).
    ///
    ///      If the request has an `executeAfter` timestamp in the future, use `vm.warp()`
    ///      to advance time before calling this helper:
    ///        ```solidity
    ///        vm.warp(block.timestamp + 1 days);
    ///        _executeTrigger(requestId);
    ///        ```
    ///
    /// @param requestId The pending request ID returned by `requestTrigger()`.
    function _executeTrigger(uint256 requestId) internal {
        vm.prank(FLAP_TRIGGER_OPERATOR);
        flapTriggerService.trigger(requestId);
    }

    /// @notice Simulate the FlapTriggerService backend executing multiple triggers in a batch.
    /// @param requestIds Array of pending request IDs to execute.
    function _executeTriggers(uint256[] memory requestIds) internal {
        vm.prank(FLAP_TRIGGER_OPERATOR);
        flapTriggerService.triggerMultiple(requestIds);
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Tax Dispatch Helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Dispatch accumulated tax revenue from a token's TaxProcessor to its receivers.
    /// @dev Calls `ITaxProcessor(taxProcessor).dispatch()` which flushes:
    ///        - protocol fee → feeReceiver
    ///        - commission   → commissionReceiver (if set)
    ///        - market share → vault (the marketAddress)
    ///        - dividends    → dividendAddress
    ///      The vault's native ETH balance will increase after this call.
    /// @param token Address of the FlapTaxTokenV3 whose tax should be dispatched.
    function _dispatchTax(address token) internal {
        address taxProcessor = IFlapTaxTokenV3(token).taxProcessor();
        ITaxProcessor(taxProcessor).dispatch{gas: 1_000_000}();
    }

    /// @notice Return the accumulated market quote balance for a token's TaxProcessor.
    /// @dev This is the native ETH amount that will flow to the vault on the next `dispatch()`.
    /// @param token Address of the FlapTaxTokenV3.
    function _pendingMarketBalance(address token) internal view returns (uint256) {
        address taxProcessor = IFlapTaxTokenV3(token).taxProcessor();
        return ITaxProcessor(taxProcessor).marketQuoteBalance();
    }

    // ──────────────────────────────────────────────────────────────────────────
    //  Trade Helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Buy a token on the bonding curve using native ETH.
    /// @param token   The token address to buy.
    /// @param ethAmount Amount of native ETH to spend (in wei).
    /// @return received Amount of tokens received.
    function _buyOnBC(address token, uint256 ethAmount) internal returns (uint256 received) {
        IPortalTradeV2.ExactInputParams memory p = IPortalTradeV2.ExactInputParams({
            inputToken: address(0), // native ETH
            outputToken: token,
            inputAmount: ethAmount,
            minOutputAmount: 0,
            permitData: ""
        });
        received = portal.swapExactInput{value: ethAmount, gas: MAX_OP_GAS}(p);
    }

    /// @notice Sell tokens on the bonding curve (or DEX if graduated) for native ETH.
    /// @dev Approves the portal before selling.
    /// @param token       The token address to sell.
    /// @param tokenAmount Amount of tokens to sell.
    /// @return received   Amount of native ETH received.
    function _sell(address token, uint256 tokenAmount) internal returns (uint256 received) {
        IERC20(token).approve(address(portal), tokenAmount);
        IPortalTradeV2.ExactInputParams memory p = IPortalTradeV2.ExactInputParams({
            inputToken: token,
            outputToken: address(0), // native ETH
            inputAmount: tokenAmount,
            minOutputAmount: 0,
            permitData: ""
        });
        received = portal.swapExactInput{gas: MAX_OP_GAS}(p);
    }
}
