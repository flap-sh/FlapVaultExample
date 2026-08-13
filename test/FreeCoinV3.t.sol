// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {FreeCoinVaultV3Upgradeable, FreeCoinVaultV3BeaconFactory} from "../src/FreeCoinV3Beacon.sol";
import {VaultUISchema, VaultDataSchema} from "../src/flap/IVaultSchemasV1.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";

contract MockQuote is ERC20 {
    constructor() ERC20("USD1", "USD1") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @title FreeCoinV3Test
/// @notice Unit tests for the V3 reference vault: balance-delta revenue
///         recognition (native + ERC20), zero-value ping handling, idempotency,
///         and the outflow-decrements-baseline rule.
contract FreeCoinV3Test is Test {
    // BNB Testnet VaultPortal constant from VaultFactoryBaseV2 (chain id 97).
    address internal constant VAULT_PORTAL_TESTNET = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;

    FreeCoinVaultV3BeaconFactory internal factory;
    MockQuote internal quote;
    address internal taxToken = address(0x7777);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal constant MAX_REWARD = 10 ether;
    uint256 internal constant COOLDOWN = 1 hours;

    function setUp() public {
        vm.chainId(97); // so _getVaultPortal()/_getGuardian() resolve
        factory = new FreeCoinVaultV3BeaconFactory();
        quote = new MockQuote();
    }

    function _newVault(address quoteToken) internal returns (FreeCoinVaultV3Upgradeable vault) {
        vm.prank(VAULT_PORTAL_TESTNET);
        vault = FreeCoinVaultV3Upgradeable(
            payable(factory.newVault(taxToken, quoteToken, address(this), abi.encode(MAX_REWARD, COOLDOWN)))
        );
    }

    /// @dev Simulate the TaxProcessor's wake call: zero value, empty calldata.
    ///      The protocol forwards the dispatcher's remaining gas; capping the
    ///      simulated ping at a conservative 500k proves receive() stays well
    ///      within a realistic keeper dispatch budget.
    function _ping(address vault) internal returns (bool ok) {
        (ok,) = vault.call{value: 0, gas: 500_000}("");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Spec surface
    // ─────────────────────────────────────────────────────────────────────────

    function test_SpecSurface() public {
        FreeCoinVaultV3Upgradeable vault = _newVault(address(quote));
        assertEq(vault.vaultQuoteToken(), address(quote), "declared quote == launch quote");
        assertEq(vault.vaultSpecVersion(), "v3", "vault spec version");
        assertEq(factory.factorySpecVersion(), "v2.3", "factory spec version");
        assertTrue(factory.isQuoteTokenSupported(address(quote)), "ERC20 quote supported");
        assertTrue(factory.isQuoteTokenSupported(address(0)), "native quote supported");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Native flow (unchanged semantics: value transfer wakes the vault)
    // ─────────────────────────────────────────────────────────────────────────

    function test_NativeRevenue_RecognizedOnTransfer_AndClaimable() public {
        FreeCoinVaultV3Upgradeable vault = _newVault(address(0));

        vm.deal(address(this), 25 ether);
        (bool ok,) = address(vault).call{value: 25 ether}("");
        assertTrue(ok, "native transfer accepted");
        assertEq(vault.accountedQuote(), 25 ether, "native revenue recognized on transfer");

        vm.prank(alice);
        vault.claim();

        assertEq(alice.balance, MAX_REWARD, "alice paid maxReward in native");
        assertEq(vault.accountedQuote(), 15 ether, "outflow decremented the baseline");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ERC20 flow (transfer alone is silent; the ping recognizes it)
    // ─────────────────────────────────────────────────────────────────────────

    function test_Erc20Revenue_TransferAloneIsSilent_PingRecognizes() public {
        FreeCoinVaultV3Upgradeable vault = _newVault(address(quote));

        // 1. A bare ERC20 transfer gives the vault no execution: nothing recognized.
        quote.mint(address(vault), 25 ether);
        assertEq(vault.accountedQuote(), 0, "bare transfer must not be auto-recognized");

        // 2. The processor-style zero-value ping (within the gas cap) recognizes it.
        assertTrue(_ping(address(vault)), "ping must succeed within the gas cap");
        assertEq(vault.accountedQuote(), 25 ether, "ping recognized the ERC20 revenue");

        // 3. Claim pays ERC20 and shrinks the baseline.
        vm.prank(alice);
        vault.claim();
        assertEq(quote.balanceOf(alice), MAX_REWARD, "alice paid maxReward in quote");
        assertEq(vault.accountedQuote(), 15 ether, "outflow decremented the baseline");
    }

    function test_ZeroDeltaPing_IsSilentNoOp() public {
        FreeCoinVaultV3Upgradeable vault = _newVault(address(quote));

        quote.mint(address(vault), 5 ether);
        assertTrue(_ping(address(vault)), "first ping ok");
        assertEq(vault.accountedQuote(), 5 ether, "recognized once");

        // Spurious wakes (same dispatch, multiple slots, or third-party calls)
        // must not change anything.
        assertTrue(_ping(address(vault)), "second ping ok");
        assertTrue(_ping(address(vault)), "third ping ok");
        assertEq(vault.accountedQuote(), 5 ether, "zero-delta pings recognize nothing");
    }

    function test_Sync_PicksUpDonationsWithoutPing() public {
        FreeCoinVaultV3Upgradeable vault = _newVault(address(quote));

        quote.mint(address(vault), 3 ether); // donation / direct transfer — no wake
        vault.sync();
        assertEq(vault.accountedQuote(), 3 ether, "sync() recognizes unwoken revenue");
    }

    function test_Claim_RecognizesPendingRevenueFirst() public {
        FreeCoinVaultV3Upgradeable vault = _newVault(address(quote));

        // Revenue arrived but nobody pinged: claim() must sync before paying.
        quote.mint(address(vault), 4 ether);
        vm.prank(alice);
        vault.claim();
        assertEq(quote.balanceOf(alice), 4 ether, "claim pays freshly recognized revenue (< maxReward)");
        assertEq(vault.accountedQuote(), 0, "baseline fully consumed");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Claim gating (unchanged from the V2 example)
    // ─────────────────────────────────────────────────────────────────────────

    function test_Claim_OncePerAddress_AndCooldown() public {
        FreeCoinVaultV3Upgradeable vault = _newVault(address(quote));
        quote.mint(address(vault), 100 ether);

        vm.prank(alice);
        vault.claim();

        vm.prank(alice);
        vm.expectRevert();
        vault.claim(); // already claimed

        vm.prank(bob);
        vm.expectRevert();
        vault.claim(); // cooldown not elapsed

        vm.warp(block.timestamp + COOLDOWN);
        vm.prank(bob);
        vault.claim();
        assertEq(quote.balanceOf(bob), MAX_REWARD, "bob claims after cooldown");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Factory guard
    // ─────────────────────────────────────────────────────────────────────────

    function test_NewVault_OnlyVaultPortal() public {
        vm.expectRevert();
        factory.newVault(taxToken, address(quote), address(this), abi.encode(MAX_REWARD, COOLDOWN));
    }
}

/// @dev Recipient without receive()/fallback — used to hit the native
///      "Transfer failed" branch in claim().
contract NoReceiveClaimer {
    function doClaim(FreeCoinVaultV3Upgradeable vault) external {
        vault.claim();
    }
}

/// @title FreeCoinV3SurfaceTest
/// @notice Coverage for the V2-inherited surface of the V3 reference vault:
///         description, UI/data schemas, guardian-gated beacon controls, and
///         the pre-launch validation hook.
contract FreeCoinV3SurfaceTest is Test {
    address internal constant VAULT_PORTAL_TESTNET = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    // BNB Testnet guardian from VaultFactoryBaseV2._getGuardian (chain id 97).
    address internal constant GUARDIAN_TESTNET = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;

    FreeCoinVaultV3BeaconFactory internal factory;
    MockQuote internal quote;
    FreeCoinVaultV3Upgradeable internal vault;
    address internal alice = address(0xA11CE);

    function setUp() public {
        vm.chainId(97);
        factory = new FreeCoinVaultV3BeaconFactory();
        quote = new MockQuote();
        vm.prank(VAULT_PORTAL_TESTNET);
        vault = FreeCoinVaultV3Upgradeable(
            payable(factory.newVault(address(0x7777), address(quote), address(this), abi.encode(10 ether, 1 hours)))
        );
    }

    // ── description ─────────────────────────────────────────────────────────

    function test_Description_BothStates() public {
        assertGt(bytes(vault.description()).length, 0, "no-claims description non-empty");

        quote.mint(address(vault), 1 ether);
        vm.prank(alice);
        vault.claim();
        assertGt(bytes(vault.description()).length, 0, "post-claim description non-empty");
        assertEq(vault.lastClaimer(), alice, "state flipped");
    }

    // ── schemas ─────────────────────────────────────────────────────────────

    function test_VaultUISchema_Complete() public view {
        VaultUISchema memory schema = vault.vaultUISchema();
        assertEq(schema.vaultType, "FreeCoinVaultV3", "vaultType");
        assertGt(bytes(schema.description).length, 0, "schema description");
        assertEq(schema.methods.length, 6, "method count");
        assertEq(schema.methods[0].name, "vaultQuoteToken", "spec discovery method listed first");
        assertTrue(schema.methods[4].isWriteMethod, "sync is a write method");
        assertTrue(schema.methods[5].isWriteMethod, "claim is a write method");
    }

    function test_VaultDataSchema_Complete() public view {
        VaultDataSchema memory schema = factory.vaultDataSchema();
        assertGt(bytes(schema.description).length, 0, "factory schema description");
        assertEq(schema.fields.length, 2, "two vaultData fields");
        assertEq(schema.fields[0].name, "maxReward", "field 0");
        assertEq(schema.fields[1].name, "cooldown", "field 1");
        assertFalse(schema.isArray, "single tuple");
    }

    // ── views ────────────────────────────────────────────────────────────────

    function test_Views() public {
        assertEq(vault.getNextClaimTime(), 0, "no claims yet");
        (address claimer, uint256 reward) = vault.getLastClaimerAndReward();
        assertEq(claimer, address(0), "no claimer yet");
        assertEq(reward, 0, "no reward yet");
        assertEq(vault.taxToken(), address(0x7777), "taxToken recorded");
        assertEq(factory.factorySpecVersion(), "v2.3", "spec version");
        assertEq(factory.tokenCreationPolicies().length, 0, "no machine-readable policies");
    }

    // ── onBeforeLaunch (spec v2.2+ hook, default pass-through) ──────────────

    function test_OnBeforeLaunch_Accepts() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory data;
        data.quoteToken = address(quote);
        (bool okAccept, string memory reason) = factory.onBeforeLaunch(abi.encode(data));
        assertTrue(okAccept, "quote-agnostic factory accepts");
        assertEq(bytes(reason).length, 0, "no reason");
    }

    // ── guardian-gated beacon controls ───────────────────────────────────────

    function test_BeaconControls_GuardianOnly() public {
        assertEq(factory.beaconImplementation() != address(0), true, "impl wired");
        assertFalse(factory.isVaultUpgradesLocked(), "unlocked initially");

        vm.expectRevert();
        factory.upgradeVaultImplementation(address(this)); // not guardian

        address newImpl = address(new FreeCoinVaultV3Upgradeable());
        vm.prank(GUARDIAN_TESTNET);
        factory.upgradeVaultImplementation(newImpl);
        assertEq(factory.beaconImplementation(), newImpl, "guardian upgraded impl");

        vm.expectRevert();
        factory.lockVaultUpgrades(); // not guardian

        vm.prank(GUARDIAN_TESTNET);
        factory.lockVaultUpgrades();
        assertTrue(factory.isVaultUpgradesLocked(), "locked after renounce");
    }

    // ── claim failure branches ───────────────────────────────────────────────

    function test_Claim_NativeTransferFailed() public {
        vm.prank(VAULT_PORTAL_TESTNET);
        FreeCoinVaultV3Upgradeable nativeVault = FreeCoinVaultV3Upgradeable(
            payable(factory.newVault(address(0x7777), address(0), address(this), abi.encode(10 ether, 1 hours)))
        );
        vm.deal(address(nativeVault), 5 ether);

        NoReceiveClaimer bad = new NoReceiveClaimer();
        vm.expectRevert();
        bad.doClaim(nativeVault); // native payout to a contract without receive()
    }

    function test_Initialize_OnlyOnce() public {
        vm.expectRevert();
        vault.initialize(address(1), address(2), 1, 1);
    }
}
