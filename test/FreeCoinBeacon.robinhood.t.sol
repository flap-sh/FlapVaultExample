// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {FlapRobinhoodFixture} from "./FlapRobinhoodFixture.sol";
import {ITriggerReceiver} from "../src/flap/IFlapTriggerService.sol";
import {FreeCoinVaultUpgradeable, FreeCoinVaultBeaconFactory} from "../src/FreeCoinBeacon.sol";

/// @title FreeCoinBeaconRobinhoodTest
/// @notice Fork test exercising FreeCoinVaultBeaconFactory / FreeCoinVaultUpgradeable against a
///         real Robinhood Chain mainnet fork (chainId 4663), using `FlapRobinhoodFixture`.
/// @dev This mirrors the intent of `FreeCoinBeacon.mainnet.t.sol` (BNB Chain), but targets
///      Robinhood Chain and additionally proves out `FlapRobinhoodFixture`'s FlapTriggerService
///      simulation helpers. Robinhood Chain has no AI Oracle / Candy Box deployment, so this
///      fixture and this test intentionally do not cover those paths — only Portal, VaultPortal,
///      and FlapTriggerService (mainnet only) are exercised here.
contract FreeCoinBeaconRobinhoodTest is FlapRobinhoodFixture, ITriggerReceiver {
    address internal constant TAX_TOKEN = address(0xBEEF);
    address internal constant USER = address(0xCAFE);

    uint256 internal constant MAX_REWARD = 0.25 ether;
    uint256 internal constant COOLDOWN = 30 minutes;

    FreeCoinVaultBeaconFactory internal factory;
    FreeCoinVaultUpgradeable internal vault;

    uint256 internal lastTriggeredRequestId;
    bool internal triggerReceived;

    function setUp() public {
        _forkRobinhoodMainnet();

        factory = new FreeCoinVaultBeaconFactory();

        vm.prank(VAULT_PORTAL);
        address vaultAddr = factory.newVault(TAX_TOKEN, address(0), address(this), abi.encode(MAX_REWARD, COOLDOWN));
        vault = FreeCoinVaultUpgradeable(payable(vaultAddr));
    }

    /// @notice Sanity-check that the fixture's constants point at real, live-deployed contracts
    ///         on the Robinhood Chain mainnet fork.
    function test_deployedAddressesHaveCode() public view {
        assertTrue(PORTAL.code.length > 0, "Portal should have code");
        assertTrue(VAULT_PORTAL.code.length > 0, "VaultPortal should have code");
        assertTrue(FLAP_TRIGGER_SERVICE.code.length > 0, "FlapTriggerService should have code");
        assertTrue(FLAP_GUARDIAN.code.length > 0, "FlapGuardian should have code");
        assertTrue(TOKEN_IMPL_TAXED_V3.code.length > 0, "TaxTokenV3 impl should have code");
        assertTrue(STANDARD_TOKEN_IMPL.code.length > 0, "Standard token impl should have code");
        assertTrue(TAX_TOKEN_HELPER.code.length > 0, "TaxTokenHelper should have code");
    }

    /// @notice The vault factory's `_getVaultPortal()` / `_getGuardian()` helpers (inherited from
    ///         `VaultFactoryBaseV2`) must resolve to the same addresses this fixture uses, since
    ///         `chainid` on the fork is the real Robinhood Chain mainnet chain id (4663).
    function test_factoryResolvesRobinhoodPortalAndGuardian() public view {
        assertEq(block.chainid, 4663, "fork should report Robinhood Chain mainnet chainid");
    }

    function test_beaconFactoryDeploysInitializedProxyVault() public view {
        assertTrue(factory.beaconImplementation() != address(0), "beacon implementation should be set");
        assertEq(vault.taxToken(), TAX_TOKEN, "taxToken mismatch");
        assertEq(vault.maxReward(), MAX_REWARD, "maxReward mismatch");
        assertEq(vault.cooldown(), COOLDOWN, "cooldown mismatch");
    }

    function test_beaconProxyClaimWorks() public {
        vm.deal(address(vault), 1 ether);
        vm.deal(USER, 1 ether);

        uint256 userBalanceBefore = USER.balance;

        vm.prank(USER);
        vault.claim();

        uint256 reward = USER.balance - userBalanceBefore;
        assertEq(reward, MAX_REWARD, "claim reward should be capped by maxReward");
        assertTrue(vault.hasClaimed(USER), "user should be marked as claimed");
    }

    /// @notice Exercises `FlapRobinhoodFixture._executeTrigger(...)` end-to-end against the real
    ///         FlapTriggerService deployment on Robinhood Chain mainnet: request a trigger,
    ///         advance time past `executeAfter`, then simulate the backend executing it.
    function test_triggerServiceRequestAndExecute() public {
        uint256 fee = flapTriggerService.getFee();
        vm.deal(address(this), fee);

        uint256 requestId = flapTriggerService.requestTrigger{value: fee}(uint64(block.timestamp + 1 hours));

        assertFalse(flapTriggerService.isRequestReady(requestId), "request should not be ready yet");

        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(flapTriggerService.isRequestReady(requestId), "request should be ready after warp");

        _executeTrigger(requestId);

        assertTrue(triggerReceived, "trigger callback should have been invoked");
        assertEq(lastTriggeredRequestId, requestId, "callback should report the same requestId");
    }

    /// @notice ITriggerReceiver callback — required so this test contract can be the requester.
    function trigger(uint256 requestId) external override {
        require(msg.sender == address(flapTriggerService), "Only trigger service");
        triggerReceived = true;
        lastTriggeredRequestId = requestId;
    }

    /// @dev Allow this contract to receive native ETH (claim rewards route through it in some paths).
    receive() external payable {}
}
