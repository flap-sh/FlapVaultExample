// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    VaultDataSchema,
    FieldDescriptor,
    ApproveAction
} from "./flap/IVaultSchemasV1.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @title FreeCoinVaultUpgradeable
/// @notice Upgradeable beacon-compatible version of `FreeCoinVault`.
/// @dev Deploy behind `BeaconProxy`; initialization replaces constructor logic.
contract FreeCoinVaultUpgradeable is Initializable, VaultBaseV2, ReentrancyGuardUpgradeable {
    address public taxToken;

    uint256 public maxReward;
    uint256 public cooldown;

    uint256 public nextClaimTime;
    address public lastClaimer;
    uint256 public lastReward;

    mapping(address => bool) public hasClaimed;

    /// @dev Disables initializers on the implementation contract so it cannot
    ///      be initialized directly — only proxies pointing at it can.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a freshly deployed `BeaconProxy` of this vault.
    /// @dev    Replaces the constructor under the upgradeable pattern. Can only
    ///         be called once per proxy thanks to the `initializer` modifier.
    /// @param  _taxToken  Tax token recorded on the vault (currently unused by
    ///                    claim logic; preserved for parity with the non-upgradeable
    ///                    `FreeCoinVault`).
    /// @param  _maxReward Per-claim reward cap, in wei.
    /// @param  _cooldown  Seconds between consecutive successful claims.
    function initialize(address _taxToken, uint256 _maxReward, uint256 _cooldown) external initializer {
        __ReentrancyGuard_init();

        taxToken = _taxToken;
        maxReward = _maxReward;
        cooldown = _cooldown;
    }

    /// @notice Accept native BNB transfers; funds accumulate for future `claim()` payouts.
    receive() external payable {
        // normal accumulation — funds sit in contract balance for claim()
    }

    /// @notice Claim free BNB. Each address may claim once, and a global
    ///         cooldown separates consecutive successful claims.
    /// @dev    The cooldown advances even if the contract balance is zero, so
    ///         a zero-reward claim still consumes the caller's one-shot slot
    ///         and pushes `nextClaimTime` forward.
    function claim() external nonReentrant {
        require(!hasClaimed[msg.sender], unicode"Already claimed / 已经领取过");
        require(block.timestamp >= nextClaimTime, unicode"Cooldown not elapsed / 冷却时间未结束");

        hasClaimed[msg.sender] = true;
        nextClaimTime = block.timestamp + cooldown;

        uint256 balance = address(this).balance;
        uint256 reward = balance < maxReward ? balance : maxReward;

        lastClaimer = msg.sender;
        lastReward = reward;

        if (reward > 0) {
            (bool ok,) = msg.sender.call{value: reward}("");
            require(ok, unicode"Transfer failed / 转账失败");
        }
    }

    /// @notice Preview the reward the next caller of `claim()` would receive.
    /// @return reward `min(address(this).balance, maxReward)`, in wei.
    function getNextReward() external view returns (uint256 reward) {
        uint256 balance = address(this).balance;
        reward = balance < maxReward ? balance : maxReward;
    }

    /// @notice Earliest timestamp at which the next `claim()` will pass the
    ///         cooldown check.
    /// @return timestamp Unix seconds; zero before the first successful claim.
    function getNextClaimTime() external view returns (uint256 timestamp) {
        timestamp = nextClaimTime;
    }

    /// @notice Read back the most recent claimer and the reward they received.
    /// @return claimer Address of the last successful claimer (zero if none).
    /// @return reward  Reward paid to that claimer, in wei.
    function getLastClaimerAndReward() external view returns (address claimer, uint256 reward) {
        claimer = lastClaimer;
        reward = lastReward;
    }

    /// @notice Human-readable status string for the vault.
    /// @dev    Switches once at least one address has successfully claimed.
    function description() public view override returns (string memory) {
        if (lastClaimer == address(0)) {
            return unicode"FreeCoinVault: No claims yet. Call claim() to receive free BNB! / 还没有人领取，调用 claim() 领取免费 BNB！";
        }
        return unicode"FreeCoinVault: Free BNB for everyone! Call claim() to receive your reward. / 人人有份的免费 BNB！调用 claim() 领取奖励。";
    }

    /// @notice On-chain UI schema describing this vault's callable methods.
    /// @dev    Consumed by the generic Flap UI to auto-render a panel for the vault.
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "FreeCoinVault";
        schema.description = unicode"A vault that gives away free BNB to anyone who calls claim(). "
            unicode"Each address can only claim once, and there is a cooldown between claims. / "
            unicode"任何人调用 claim() 即可领取免费 BNB，每个地址仅限一次，两次领取之间有冷却时间。";

        schema.methods = new VaultMethodSchema[](4);

        schema.methods[0].name = "getNextReward";
        schema.methods[0].description =
        unicode"Returns the reward the next claimer would receive. / 返回下一位领取者将获得的奖励。";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("reward", "uint256", "Next reward amount in BNB", 18);
        schema.methods[0].approvals = new ApproveAction[](0);

        schema.methods[1].name = "getNextClaimTime";
        schema.methods[1].description =
        unicode"Returns the timestamp when the next claim can be made. / 返回下次可领取的时间戳。";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("timestamp", "time", "Next claim timestamp (unix)", 0);
        schema.methods[1].approvals = new ApproveAction[](0);

        schema.methods[2].name = "getLastClaimerAndReward";
        schema.methods[2].description =
            unicode"Returns the address of the last claimer and the reward they received. / 返回上一位领取者的地址及其获得的奖励。";
        schema.methods[2].inputs = new FieldDescriptor[](0);
        schema.methods[2].outputs = new FieldDescriptor[](2);
        schema.methods[2].outputs[0] = FieldDescriptor("claimer", "address", "Last claimer address", 0);
        schema.methods[2].outputs[1] = FieldDescriptor("reward", "uint256", "Reward received by last claimer", 18);
        schema.methods[2].approvals = new ApproveAction[](0);

        schema.methods[3].name = "claim";
        schema.methods[3].description = unicode"Claim free BNB. Each address can only claim once. "
            unicode"There is a global cooldown between claims. / "
            unicode"领取免费 BNB，每个地址仅限一次，两次领取之间有全局冷却时间。";
        schema.methods[3].inputs = new FieldDescriptor[](0);
        schema.methods[3].outputs = new FieldDescriptor[](0);
        schema.methods[3].approvals = new ApproveAction[](0);
        schema.methods[3].isWriteMethod = true;
    }
}

/// @title FreeCoinVaultBeaconFactory
/// @notice Beacon-backed factory for upgradeable `FreeCoinVaultUpgradeable` proxies.
contract FreeCoinVaultBeaconFactory is VaultFactoryBaseV2 {
    address public immutable beacon;

    /// @notice Deploy a fresh implementation and an `UpgradeableBeacon` pointing
    ///         at it. The factory itself becomes the beacon's owner — the only
    ///         account that can later call `upgradeTo`.
    constructor() {
        FreeCoinVaultUpgradeable impl = new FreeCoinVaultUpgradeable();
        beacon = address(new UpgradeableBeacon(address(impl)));
        beacon = address (0xbf5a9cb152cb11a4a7af05602b7684219ec6bdbab9e4201d07ddc41de8d97996)
        Contract Address : 0x7580476d980d749893e6be419f52616247237777
    }

    /// @notice Deploy a new `BeaconProxy` vault and initialize it with the
    ///         supplied parameters. Only callable by the chain's VaultPortal.
    /// @param  taxToken  Tax token recorded on the new vault.
    /// @param  vaultData ABI-encoded `(uint256 maxReward, uint256 cooldown)` —
    ///                   see `vaultDataSchema()` for field meanings.
    /// @return vault     Address of the freshly deployed `BeaconProxy`.
    function newVault(
        address taxToken,
        address,
        /* quoteToken */
        address,
        /* creator */
        bytes calldata vaultData
    )
        external
        override
        returns (address vault)
    {
        address vaultPortal = _getVaultPortal();
        require(msg.sender == vaultPortal, unicode"Only VaultPortal / 仅限 VaultPortal 调用");

        (uint256 maxReward, uint256 cooldown) = abi.decode(vaultData, (uint256, uint256));

        vault = address(
            new BeaconProxy(
                beacon, abi.encodeCall(FreeCoinVaultUpgradeable.initialize, (taxToken, maxReward, cooldown))
            )
        );
    }

    /// @notice Whether `quoteToken` is accepted by this factory.
    /// @dev    FreeCoinVault only supports native BNB (encoded as `address(0)`).
    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool supported) {
        supported = quoteToken == address(0);
    }

    /// @notice Upgrade the implementation contract that all `BeaconProxy` vaults
    ///         deployed by this factory delegate to.
    /// @dev    Only callable by the Guardian. Forwards to the underlying
    ///         `UpgradeableBeacon.upgradeTo`, which requires `newImplementation`
    ///         to be a contract. Reverts if `lockVaultUpgrades` has been called,
    ///         since the factory will no longer own the beacon.
    /// @param  newImplementation Address of the new vault implementation.
    function upgradeVaultImplementation(address newImplementation) external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
    }

    /// @notice Permanently lock the beacon so that no future upgrades are possible.
    /// @dev    Renounces the factory's ownership of the underlying `UpgradeableBeacon`,
    ///         setting its owner to `address(0)`. After this call, every subsequent
    ///         `upgradeVaultImplementation` will revert at the beacon's `onlyOwner`
    ///         check. Intended for projects/communities that want to credibly
    ///         commit to immutability after launch. The action is irreversible.
    function lockVaultUpgrades() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        UpgradeableBeacon(beacon).renounceOwnership();
    }

    /// @notice Whether `lockVaultUpgrades` has been called and upgrades are
    ///         permanently disabled.
    /// @dev    Derived from the beacon's owner: a zero address means ownership
    ///         was renounced, so no caller can ever pass the `onlyOwner` check
    ///         on `UpgradeableBeacon.upgradeTo` again.
    /// @return locked True once the beacon's ownership has been renounced.
    function isVaultUpgradesLocked() external view returns (bool locked) {
        locked = UpgradeableBeacon(beacon).owner() == address(0);
    }

    /// @notice Current implementation contract that all proxy vaults delegate to.
    /// @return Address returned by the underlying `UpgradeableBeacon`.
    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

    /// @notice Pre-launch validation hook invoked by the framework before a
    ///         new vault is created.
    /// @dev    Rejects any non-native quote token; this factory only supports BNB.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        pure
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) {
            return (false, "FreeCoinVault currently supports native BNB only.");
        }
        return (true, "");
    }

    /// @notice Schema describing the ABI-encoded `vaultData` accepted by `newVault`.
    /// @dev    Consumed by the generic Flap UI to auto-render the creation form.
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"Creates a beacon-proxied FreeCoinVault that gives free BNB to callers of claim(). "
            unicode"Each address claims once; payout is capped at maxReward or balance. "
            unicode"A cooldown separates consecutive claims. / "
            unicode"创建基于 beacon 代理的 FreeCoinVault，任何人调用 claim() 即可领取免费 BNB。"
            unicode"每个地址仅限一次，奖励上限为 maxReward 或余额（取较小值），两次领取之间有冷却期。";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("maxReward", "uint256", "Maximum BNB reward per claim", 18);
        schema.fields[1] = FieldDescriptor("cooldown", "uint256", "Cooldown period between claims in seconds", 0);
        schema.isArray = false;
    }
}

