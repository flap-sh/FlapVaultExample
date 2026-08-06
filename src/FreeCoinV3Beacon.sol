// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {VaultBaseV3} from "./flap/VaultBaseV3.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    VaultDataSchema,
    FieldDescriptor,
    ApproveAction
} from "./flap/IVaultSchemasV1.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @title FreeCoinVaultV3Upgradeable
/// @notice Quote-agnostic reference implementation of the V3 vault spec
///         (`VaultBaseV3`): gives away the vault's tax revenue — native BNB/ETH
///         OR any ERC20 quote token (stablecoins, tokenized equities / RWA) —
///         to anyone who calls `claim()`, one claim per address, with a global
///         cooldown between claims.
///
/// @dev    This contract exists primarily as the canonical example of the V3
///         accounting model. The parts worth copying into your own vault:
///
///           • `accountedQuote` — the recognized-revenue baseline;
///           • `receive()` → `_syncRevenue()` — lightweight, idempotent
///             balance-delta recognition, shared by native transfers and the
///             TaxProcessor's zero-value ERC20 wake call ("ping");
///           • the `accountedQuote -= reward` decrement inside `claim()` —
///             EVERY outflow must shrink the baseline in the same transaction,
///             or revenue recognition deadlocks (spec rule 3);
///           • `sync()` — a public poke so recognition never depends solely on
///             being pinged (donations / direct transfers are picked up too).
contract FreeCoinVaultV3Upgradeable is Initializable, VaultBaseV3, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice The tax token this vault serves (recorded for discovery; not
    ///         used by the claim logic).
    address public taxToken;

    /// @notice Per-claim reward cap, in quote-token base units.
    uint256 public maxReward;

    /// @notice Seconds between consecutive successful claims.
    uint256 public cooldown;

    uint256 public nextClaimTime;
    address public lastClaimer;
    uint256 public lastReward;

    mapping(address => bool) public hasClaimed;

    // --- V3 Extension Storage (appended after the V2 layout so this
    //     implementation is also a valid beacon-upgrade target for existing
    //     FreeCoinVaultUpgradeable instances: their _quoteToken reads as
    //     address(0) = native and accountedQuote as 0 — both correct, the
    //     next sync simply recognizes the full native balance) ---

    /// @notice The revenue currency: address(0) = native, otherwise an ERC20.
    address internal _quoteToken;

    /// @notice Recognized-and-not-yet-spent revenue baseline (spec: the
    ///         balance-delta accounting anchor). Only recognized revenue is
    ///         claimable.
    uint256 public accountedQuote;

    /// @notice Emitted whenever new revenue is recognized against the baseline.
    /// @dev    Part of the V3 spec surface: `receive()` must stay lightweight
    ///         (accounting + an event), so this is the off-chain signal that
    ///         revenue was picked up.
    /// @param newRevenue   The delta recognized by this sync.
    /// @param accountedTotal The baseline after recognition.
    event FlapFreeCoinRevenueRecognized(uint256 newRevenue, uint256 accountedTotal);

    /// @dev Disables initializers on the implementation contract so it cannot
    ///      be initialized directly — only proxies pointing at it can.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a freshly deployed `BeaconProxy` of this vault.
    /// @param  _taxToken   Tax token recorded on the vault.
    /// @param  quoteToken_ Revenue currency (address(0) = native gas token).
    ///                     MUST equal the tax token's launch quote token — the
    ///                     factory passes it through from `newVault`.
    /// @param  _maxReward  Per-claim reward cap, in quote base units.
    /// @param  _cooldown   Seconds between consecutive successful claims.
    function initialize(address _taxToken, address quoteToken_, uint256 _maxReward, uint256 _cooldown)
        external
        initializer
    {
        __ReentrancyGuard_init();

        taxToken = _taxToken;
        _quoteToken = quoteToken_;
        maxReward = _maxReward;
        cooldown = _cooldown;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // V3 spec surface
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc VaultBaseV3
    function vaultQuoteToken() public view override returns (address) {
        return _quoteToken;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Revenue recognition (the part to copy)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Wake entry point. Invoked by native value transfers AND by the
    ///         TaxProcessor's zero-value ERC20 ping. Lightweight by design —
    ///         it must fit the processor's ping gas cap.
    receive() external payable {
        _syncRevenue();
    }

    /// @notice Public poke: recognize any revenue that arrived without a wake
    ///         (donations, direct transfers). Safe to call at any time — a
    ///         zero-delta sync is a silent no-op.
    function sync() external {
        _syncRevenue();
    }

    /// @dev Balance-delta recognition per the V3 spec:
    ///        1. read the current quote balance;
    ///        2. `bal <= accountedQuote` → silent no-op (idempotency);
    ///        3. otherwise advance the baseline and account the delta.
    function _syncRevenue() internal {
        uint256 balance = _quoteBalance();
        if (balance <= accountedQuote) return;
        uint256 newRevenue = balance - accountedQuote;
        accountedQuote = balance;
        emit FlapFreeCoinRevenueRecognized(newRevenue, balance);
    }

    /// @dev Current balance in the vault's revenue currency.
    function _quoteBalance() internal view returns (uint256) {
        address quoteToken = _quoteToken;
        return quoteToken == address(0) ? address(this).balance : IERC20(quoteToken).balanceOf(address(this));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Claim logic
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Claim free coins (native or ERC20, per `vaultQuoteToken()`).
    ///         Each address may claim once; a global cooldown separates
    ///         consecutive successful claims.
    /// @dev    Syncs first so unrecognized revenue becomes claimable, pays
    ///         `min(maxReward, accountedQuote)`, and — critically — decrements
    ///         `accountedQuote` by the amount paid (spec rule 3).
    function claim() external nonReentrant {
        require(!hasClaimed[msg.sender], unicode"Already claimed / 已经领取过");
        require(block.timestamp >= nextClaimTime, unicode"Cooldown not elapsed / 冷却时间未结束");

        _syncRevenue();

        hasClaimed[msg.sender] = true;
        nextClaimTime = block.timestamp + cooldown;

        uint256 available = accountedQuote;
        uint256 reward = available < maxReward ? available : maxReward;

        lastClaimer = msg.sender;
        lastReward = reward;

        if (reward > 0) {
            // Spec rule 3: every outflow shrinks the baseline in the same tx.
            accountedQuote = available - reward;

            address quoteToken = _quoteToken;
            if (quoteToken == address(0)) {
                (bool ok,) = msg.sender.call{value: reward}("");
                require(ok, unicode"Transfer failed / 转账失败");
            } else {
                IERC20(quoteToken).safeTransfer(msg.sender, reward);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Preview the reward the next caller of `claim()` would receive,
    ///         including revenue that has arrived but is not yet recognized.
    function getNextReward() external view returns (uint256 reward) {
        uint256 balance = _quoteBalance();
        reward = balance < maxReward ? balance : maxReward;
    }

    /// @notice Earliest timestamp at which the next `claim()` passes the
    ///         cooldown check.
    function getNextClaimTime() external view returns (uint256 timestamp) {
        timestamp = nextClaimTime;
    }

    /// @notice The most recent claimer and the reward they received.
    function getLastClaimerAndReward() external view returns (address claimer, uint256 reward) {
        claimer = lastClaimer;
        reward = lastReward;
    }

    /// @notice Human-readable status string for the vault.
    function description() public view override returns (string memory) {
        if (lastClaimer == address(0)) {
            return unicode"FreeCoinVaultV3: No claims yet. Call claim() to receive free coins (native or the token's quote currency)! / 还没有人领取，调用 claim() 领取免费代币（原生币或该代币的底池币种）！";
        }
        return unicode"FreeCoinVaultV3: Free coins for everyone! Call claim() to receive your reward. / 人人有份的免费代币！调用 claim() 领取奖励。";
    }

    /// @notice On-chain UI schema describing this vault's callable methods.
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "FreeCoinVaultV3";
        schema.description = unicode"A quote-agnostic vault that gives away its tax revenue (native or ERC20 "
            unicode"quote token) to anyone who calls claim(). Each address can only claim once, and there is a "
            unicode"cooldown between claims. / "
            unicode"任何人调用 claim() 即可领取金库税收（原生币或 ERC20 底池币种），每个地址仅限一次，两次领取之间有冷却时间。";

        schema.methods = new VaultMethodSchema[](6);

        schema.methods[0].name = "vaultQuoteToken";
        schema.methods[0].description =
            unicode"Returns the revenue currency of this vault (zero address = native). / 返回金库的收益币种（零地址代表原生币）。";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("quoteToken", "address", "Revenue currency (0 = native)", 0);
        schema.methods[0].approvals = new ApproveAction[](0);

        schema.methods[1].name = "getNextReward";
        schema.methods[1].description =
            unicode"Returns the reward the next claimer would receive. / 返回下一位领取者将获得的奖励。";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("reward", "uint256", "Next reward amount", 18);
        schema.methods[1].approvals = new ApproveAction[](0);

        schema.methods[2].name = "getNextClaimTime";
        schema.methods[2].description =
            unicode"Returns the timestamp when the next claim can be made. / 返回下次可领取的时间戳。";
        schema.methods[2].inputs = new FieldDescriptor[](0);
        schema.methods[2].outputs = new FieldDescriptor[](1);
        schema.methods[2].outputs[0] = FieldDescriptor("timestamp", "time", "Next claim timestamp (unix)", 0);
        schema.methods[2].approvals = new ApproveAction[](0);

        schema.methods[3].name = "getLastClaimerAndReward";
        schema.methods[3].description =
            unicode"Returns the address of the last claimer and the reward they received. / 返回上一位领取者的地址及其获得的奖励。";
        schema.methods[3].inputs = new FieldDescriptor[](0);
        schema.methods[3].outputs = new FieldDescriptor[](2);
        schema.methods[3].outputs[0] = FieldDescriptor("claimer", "address", "Last claimer address", 0);
        schema.methods[3].outputs[1] = FieldDescriptor("reward", "uint256", "Reward received by last claimer", 18);
        schema.methods[3].approvals = new ApproveAction[](0);

        schema.methods[4].name = "sync";
        schema.methods[4].description =
            unicode"Recognize revenue that arrived without a wake call (e.g. direct transfers). / 手动同步未被自动识别的收益（如直接转账）。";
        schema.methods[4].inputs = new FieldDescriptor[](0);
        schema.methods[4].outputs = new FieldDescriptor[](0);
        schema.methods[4].approvals = new ApproveAction[](0);
        schema.methods[4].isWriteMethod = true;

        schema.methods[5].name = "claim";
        schema.methods[5].description = unicode"Claim free coins. Each address can only claim once. "
            unicode"There is a global cooldown between claims. / "
            unicode"领取免费代币，每个地址仅限一次，两次领取之间有全局冷却时间。";
        schema.methods[5].inputs = new FieldDescriptor[](0);
        schema.methods[5].outputs = new FieldDescriptor[](0);
        schema.methods[5].approvals = new ApproveAction[](0);
        schema.methods[5].isWriteMethod = true;
    }
}

/// @title FreeCoinVaultV3BeaconFactory
/// @notice Beacon-backed factory for upgradeable `FreeCoinVaultV3Upgradeable`
///         proxies. Reference implementation of a factory-spec v2.3 factory:
///         it truthfully supports ANY quote token (the FreeCoin giveaway logic
///         is currency-agnostic) and passes the launch quote token through to
///         the vault initializer.
contract FreeCoinVaultV3BeaconFactory is VaultFactoryBaseV2 {
    address public immutable beacon;

    /// @notice Deploy a fresh implementation and an `UpgradeableBeacon`
    ///         pointing at it. The factory itself becomes the beacon's owner.
    constructor() {
        FreeCoinVaultV3Upgradeable impl = new FreeCoinVaultV3Upgradeable();
        beacon = address(new UpgradeableBeacon(address(impl)));
    }

    /// @notice Deploy a new `BeaconProxy` vault and initialize it with the
    ///         supplied parameters. Only callable by the chain's VaultPortal.
    /// @param  taxToken   The (predicted) tax token address.
    /// @param  quoteToken The launch quote token (address(0) = native) — wired
    ///                    straight into the vault so `vaultQuoteToken()`
    ///                    matches the token it serves.
    /// @param  vaultData  ABI-encoded `(uint256 maxReward, uint256 cooldown)`.
    /// @return vault      Address of the freshly deployed `BeaconProxy`.
    function newVault(
        address taxToken,
        address quoteToken,
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
                beacon,
                abi.encodeCall(FreeCoinVaultV3Upgradeable.initialize, (taxToken, quoteToken, maxReward, cooldown))
            )
        );
    }

    /// @notice Whether `quoteToken` is accepted by this factory.
    /// @dev    The FreeCoin giveaway logic is currency-agnostic, so this
    ///         factory truthfully supports every quote token — native or
    ///         ERC20. Factories whose vaults depend on a specific currency
    ///         (e.g. protocols that only accept native staking deposits) MUST
    ///         restrict this to what their vault code can actually handle.
    function isQuoteTokenSupported(address) external pure override returns (bool supported) {
        supported = true;
    }

    /// @notice Factory spec revision: v2.3 opts into the V3 (ERC20-quote)
    ///         validation flow at the VaultPortal.
    function factorySpecVersion() public pure override returns (string memory) {
        return "v2.3";
    }

    /// @notice Pre-launch validation hook — no additional constraints beyond
    ///         the quote support already declared above.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory)
        internal
        pure
        override
        returns (bool success, string memory reason)
    {
        return (true, "");
    }

    /// @notice Upgrade the implementation contract that all `BeaconProxy`
    ///         vaults deployed by this factory delegate to. Guardian-only.
    function upgradeVaultImplementation(address newImplementation) external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
    }

    /// @notice Permanently lock the beacon so that no future upgrades are
    ///         possible. Guardian-only; irreversible.
    function lockVaultUpgrades() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        UpgradeableBeacon(beacon).renounceOwnership();
    }

    /// @notice Whether `lockVaultUpgrades` has been called.
    function isVaultUpgradesLocked() external view returns (bool locked) {
        locked = UpgradeableBeacon(beacon).owner() == address(0);
    }

    /// @notice Current implementation contract that all proxy vaults delegate to.
    function beaconImplementation() external view returns (address) {
        return UpgradeableBeacon(beacon).implementation();
    }

    /// @notice Schema describing the ABI-encoded `vaultData` accepted by `newVault`.
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = unicode"Creates a beacon-proxied, quote-agnostic FreeCoinVaultV3 that gives its tax "
            unicode"revenue (native or the token's ERC20 quote currency) to callers of claim(). Each address claims "
            unicode"once; payout is capped at maxReward or the recognized balance. A cooldown separates consecutive "
            unicode"claims. / "
            unicode"创建基于 beacon 代理、底池币种无关的 FreeCoinVaultV3，任何人调用 claim() 即可领取金库税收"
            unicode"（原生币或该代币的 ERC20 底池币种）。每个地址仅限一次，奖励上限为 maxReward 或已识别余额（取较小值），"
            unicode"两次领取之间有冷却期。";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("maxReward", "uint256", "Maximum reward per claim (quote base units)", 18);
        schema.fields[1] = FieldDescriptor("cooldown", "uint256", "Cooldown period between claims in seconds", 0);
        schema.isArray = false;
    }
}
