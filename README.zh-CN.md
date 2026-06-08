# Flap Tax Vault V2 示例

[English](README.md) | **中文**

> 现在在 Flap.sh 上使用 Vault 发币已完全无需许可。你不需要联系我们注册 Vault Factory 或申请白名单。只需基于 V2 接口实现你的 Vault Factory 与 Vault 合约，部署后，前往 Flap.sh 用你自己的 Vault Factory 创建代币即可。

![发币流程](misc/Launch_token_workflow.png)

本仓库提供基于全新 V2 接口的 Flap Tax Vault 示例实现。后续我们会持续补充更多示例，目前已实现一个简单的 "FreeCoin" Vault：用户调用 `claim()` 即可领取免费的 BNB，并设有冷却时间和单次最大奖励上限。

---

> **提交审计前 →** 请使用内置的 `flap-vault-spec-checker` Copilot agent skill 验证你的 Vault 是否符合规范。详见 [使用 Copilot Skill 进行审计前自检](#使用-copilot-skill-进行审计前自检)。

---

## 目录

- [目录结构](#目录结构)
- [Flap Tax Vault V2 接口](#flap-tax-vault-v2-接口)
- [FreeCoin Vault 示例](#freecoin-vault-示例)
- [推荐部署模式：可升级代理 Vault](#推荐部署模式可升级代理-vault)
- [如何使用 Vault Factory](#如何使用-vault-factory)
  - [步骤 1 — 实现你的 Vault 与 Factory](#步骤-1--实现你的-vault-与-factory)
  - [步骤 2 — 描述 UI Schema](#步骤-2--描述-ui-schema)
  - [步骤 3 — 部署你的 Factory](#步骤-3--部署你的-factory)
  - [步骤 4 — 使用你的 Factory 发币](#步骤-4--使用你的-factory-发币)
- [使用 Copilot Skill 进行审计前自检](#使用-copilot-skill-进行审计前自检)
- [审计前的集成测试](#审计前的集成测试)
  - [审计前必备的测试覆盖](#审计前必备的测试覆盖)
  - [运行测试](#运行测试)
  - [测试中的 prank 约定](#测试中的-prank-约定)

---

## 目录结构

仓库中唯一强制且不可改动的目录是 `src/flap/`，它包含 Flap Vault 接口的标准文件。你自己的 Vault 源码与 `src/flap/` 同级，直接放在 `src/` 下。

```
src/
├── flap/              ← 必需且不可修改 —— 不要重命名或修改其中文件
│   ├── IPortal.sol
│   ├── IVaultFactory.sol
│   ├── IVaultPortal.sol
│   ├── IVaultSchemasV1.sol
│   ├── VaultBase.sol
│   ├── VaultBaseV2.sol
│   └── VaultFactoryBaseV2.sol
└── YourVault.sol      ← 你的 Vault 实现放在这里
```

> ⚠️ 后续的合规检查器会假设 `src/flap/` 目录存在并保持上述结构。请勿重命名或迁移此目录。


## Flap Tax Vault V2 接口

Flap Tax Vault V2 完全兼容 V1。主要区别在于 V2 使用全新的 `VaultFactoryBaseV2` 与 `VaultBaseV2` 基类接口，新增了用于描述 UI Schema 与元信息的函数。借助这些 Schema 函数，Vault 可以更完整地描述自身参数与交互方式，从而让 Flap.sh 自动为其生成用户界面。

- [VaultFactoryBaseV2](src/flap/VaultFactoryBaseV2.sol)：Vault Factory 的基类接口。除创建 Vault 外，还包含描述其所创建 Vault 的元信息与 UI Schema 的相关函数。
- [VaultBaseV2](src/flap/VaultBaseV2.sol)：Vault 的基类接口。除常规交互函数外，还包含描述 Vault 自身元信息与 UI Schema 的函数。

以上接口均带有非常详尽的 NatSpec 注释，描述了每个函数的用途、用法以及对 Vault 行为的预期。建议你完整阅读这些接口，以便理解如何基于 V2 实现自己的 Vault。


## FreeCoin Vault 示例

以 [FreeCoinBeacon](src/FreeCoinBeacon.sol) 为例，其 Factory 的 `vaultDataSchema()` 描述了 Vault 的参数：

```solidity
/// @inheritdoc VaultFactoryBaseV2
function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
    schema.description = unicode"Creates a FreeCoinVault that gives free BNB to callers of claim(). "
        unicode"Each address claims once; payout is capped at maxReward or balance. "
        unicode"A cooldown separates consecutive claims. / " unicode"创建 FreeCoinVault，任何人调用 claim() 即可领取免费 BNB。"
        unicode"每个地址仅限一次，奖励上限为 maxReward 或余额（取较小值），两次领取之间有冷却期。";
    schema.fields = new FieldDescriptor[](2);
    schema.fields[0] = FieldDescriptor("maxReward", "uint256", "Maximum BNB reward per claim", 18);
    schema.fields[1] = FieldDescriptor("cooldown", "uint256", "Cooldown period between claims in seconds", 0);
    schema.isArray = false;
}
```

基于上述 Schema，Flap.sh 上会展示如下创建表单：

![FreeCoin Vault 配置](misc/FreeCoin_vault_config.png)


而 FreeCoin Vault 自身的 `vaultUISchema()` 描述了 Vault 的参数与可调用方法：

```solidity

    /// @inheritdoc VaultBaseV2
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "FreeCoinVault";
        schema.description = unicode"A vault that gives away free BNB to anyone who calls claim(). "
            unicode"Each address can only claim once, and there is a cooldown between claims. / "
            unicode"任何人调用 claim() 即可领取免费 BNB，每个地址仅限一次，两次领取之间有冷却时间。";

        schema.methods = new VaultMethodSchema[](4);

        // ── View: getNextReward() ────────────────────────────────────────
        schema.methods[0].name = "getNextReward";
        schema.methods[0].description = unicode"Returns the reward the next claimer would receive. / 返回下一位领取者将获得的奖励。";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("reward", "uint256", "Next reward amount in BNB", 18);
        schema.methods[0].approvals = new ApproveAction[](0);

        // ── View: getNextClaimTime() ─────────────────────────────────────
        schema.methods[1].name = "getNextClaimTime";
        schema.methods[1].description = unicode"Returns the timestamp when the next claim can be made. / 返回下次可领取的时间戳。";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] = FieldDescriptor("timestamp", "time", "Next claim timestamp (unix)", 0);
        schema.methods[1].approvals = new ApproveAction[](0);

        // ── View: getLastClaimerAndReward() ──────────────────────────────
        schema.methods[2].name = "getLastClaimerAndReward";
        schema.methods[2].description =
            unicode"Returns the address of the last claimer and the reward they received. / 返回上一位领取者的地址及其获得的奖励。";
        schema.methods[2].inputs = new FieldDescriptor[](0);
        schema.methods[2].outputs = new FieldDescriptor[](2);
        schema.methods[2].outputs[0] = FieldDescriptor("claimer", "address", "Last claimer address", 0);
        schema.methods[2].outputs[1] = FieldDescriptor("reward", "uint256", "Reward received by last claimer", 18);
        schema.methods[2].approvals = new ApproveAction[](0);

        // ── Write: claim() ───────────────────────────────────────────────
        schema.methods[3].name = "claim";
        schema.methods[3].description = unicode"Claim free BNB. Each address can only claim once. "
            unicode"There is a global cooldown between claims. / " unicode"领取免费 BNB，每个地址仅限一次，两次领取之间有全局冷却时间。";
        schema.methods[3].inputs = new FieldDescriptor[](0);
        schema.methods[3].outputs = new FieldDescriptor[](0);
        schema.methods[3].approvals = new ApproveAction[](0);
        schema.methods[3].isWriteMethod = true;
    }

```

基于上述 Schema，Flap.sh 上会展示如下 Vault 交互界面：

![FreeCoin tax 信息](misc/freecoin_tax_info.png)

本仓库的示例 Vault 为 [`src/FreeCoinBeacon.sol`](src/FreeCoinBeacon.sol)，采用了推荐的代理升级部署模式，基于 OpenZeppelin 的 `BeaconProxy` + `UpgradeableBeacon` 组合。**所有新 Vault 都应使用代理部署模式。** 这样在多个 Vault 实例之间能保持更清晰的升级路径，同时保持部署与初始化的简洁。

仓库中也提供了开箱即用的部署脚本：

- [`script/mainnet/bnb/DeployFreeCoinBeacon.s.sol`](script/mainnet/bnb/DeployFreeCoinBeacon.s.sol)
- [`script/testnet/bnb/DeployFreeCoinBeacon.s.sol`](script/testnet/bnb/DeployFreeCoinBeacon.s.sol)


---

## 推荐部署模式：可升级代理 Vault

对于绝大多数生产环境的 Vault，我们**推荐将 Vault 实现合约部署在代理之后**，而不是直接部署多个不可升级的 Vault 实例。

我们推荐的模式是：

- 使用带 `initialize(...)` 的实现合约
- OpenZeppelin [`UpgradeableBeacon`](https://docs.openzeppelin.com/contracts/4.x/api/proxy#UpgradeableBeacon)
- OpenZeppelin [`BeaconProxy`](https://docs.openzeppelin.com/contracts/4.x/api/proxy#BeaconProxy)
- Factory 在创建时部署新的代理实例并对其完成初始化

推荐这种模式的原因：

1. **运维灵活性** —— 后续若发现 bug 或协议变更，可以一次性升级未来与已有 beacon 后的代理 Vault 使用的实现。
2. **更清晰的 Factory 设计** —— Factory 可使用确定性的初始化数据创建 Vault，无需把完整的构造逻辑塞进每条部署路径。
3. **多 Vault 升级一致性** —— 一个 beacon 即可统一协调同类型多个 Vault 实例的升级。
4. **更好的长期维护** —— 审计师与集成方更容易基于"单一实现 + beacon 权限"的模型推理你的合约。

完整示例参见 [`src/FreeCoinBeacon.sol`](src/FreeCoinBeacon.sol)。

### 可升级 Vault 的推荐权限模型

如果你选择可升级代理架构，**升级权限必须仅授予 Flap Guardian 地址，无一例外。** 不要再为 owner、proxy admin、beacon owner、upgrader 角色、多签或部署 EOA 留有等同的权限，除非这些权限本身也是 Guardian 批准的控制路径。

> **Guardian 地址由 Flap 安全团队掌控。** 如果你需要执行升级（例如修复 bug 或适配协议变更），必须直接联系我们。我们的安全团队需要大约 **24 小时**来评估请求、确认所提议的变更安全有效，并在审批通过后执行升级。这一流程的目的是保护用户和整个生态系统免受未经授权或恶意升级的威胁。请合理规划，不要将 Vault 设计成依赖单方面升级或需要在极短时间内完成升级的架构。

### 可升级 Vault 中的紧急控制

对于不可升级的 Vault，`emergencyWithdrawNative(...)`、`emergencyWithdrawToken(...)` 以及可选的自动转发控制等紧急逃生通道仍然有用。

但对于**可升级代理 Vault**，你可以选择完全省略这些控制项，转而依赖升级路径来处理 —— [`src/FreeCoinBeacon.sol`](src/FreeCoinBeacon.sol) 就采用了这一模式。在这种设计下，关键要求是升级/管理权限必须**仅由 Guardian 持有**。


---

## 如何使用 Vault Factory

### 步骤 1 — 实现你的 Vault 与 Factory

通过继承 `VaultBaseV2` 实现你的 Vault 合约，通过继承 `VaultFactoryBaseV2` 实现你的 Factory。两个基类均位于 `src/flap/`，并附带完整的 NatSpec 注释，详细说明了你需要实现的每个函数。

> **推荐做法：** 把你的 Vault 实现写成可升级的实现合约，并由 Factory 通过 **OpenZeppelin `BeaconProxy`** 部署面向用户的 Vault 实例。非升级模式仍然受支持，但对于新的生产 Vault，我们推荐使用 [`src/FreeCoinBeacon.sol`](src/FreeCoinBeacon.sol) 中所示的 beacon 代理架构。

```
src/
├── flap/
│   ├── VaultBaseV2.sol          ← 你 Vault 的基类
│   └── VaultFactoryBaseV2.sol   ← 你 Factory 的基类
└── YourVault.sol                ← 你的实现
```

Factory 的 `createVault(address taxToken, bytes calldata vaultData)` 会在 `newTokenV6WithVault()` 期间被 VaultPortal 调用。它必须部署一个 Vault，对其进行初始化，并返回其地址。`vaultData` 是发币者在创建时选择的 ABI 编码参数 —— 而你的 `vaultDataSchema()` 决定了 Flap.sh 如何渲染创建表单。

在推荐的 beacon 代理模式下，你的 Factory 应当：

1. 在前期（通常在 Factory 构造函数中）部署实现合约 + beacon；
2. 在 `newVault(...)` 中创建一个新的 `BeaconProxy`，并将 `abi.encodeCall(YourVault.initialize, (...))` 作为初始化 calldata 传入。

### 步骤 2 — 描述 UI Schema

在你的 Factory 上实现 `vaultDataSchema()`，在你的 Vault 上实现 `vaultUISchema()`。它们返回的结构化元信息会被 Flap.sh 用于自动生成创建表单与 Vault 交互面板，无需你手动编写任何前端代码。完整参考可见 [FreeCoinBeacon 示例](src/FreeCoinBeacon.sol)。

### 步骤 3 — 部署你的 Factory

将你的 Factory 部署到 BSC（或其他受支持的链）。无需白名单或权限申请 —— VaultPortal 是无许可的。

```bash
forge script --account deployer --rpc-url https://bsc-dataseed.bnbchain.org \
    --broadcast script/mainnet/deploy-my-factory.sol
```

如果你采用推荐的 `BeaconProxy` 模式，可以参考已包含的示例：

```bash
# 主网 beacon 版 FreeCoin 示例
forge script script/mainnet/bnb/DeployFreeCoinBeacon.s.sol:DeployFreeCoinBeacon \
    --rpc-url https://bsc-dataseed.bnbchain.org \
    --broadcast

# 测试网 beacon 版 FreeCoin 示例
forge script script/testnet/bnb/DeployFreeCoinBeacon.s.sol:DeployFreeCoinBeacon \
    --rpc-url https://bsc-testnet-dataseed.bnbchain.org \
    --broadcast
```

### 步骤 4 — 使用你的 Factory 发币

在 [Flap.sh](https://flap.sh) 上选择 **Launch Token → Custom Vault**，粘贴你的 Factory 地址，填入 Vault 参数即可。或者你也可以直接调用 `VaultPortal.newTokenV6WithVault()`：

```solidity
IVaultPortalTypes.NewTokenV6WithVaultParams memory params = _buildV3TaxTokenParams(
    "My Token", "MTK", salt, address(myFactory), abi.encode(/* 你的 vaultData */)
);
address token = vaultPortal.newTokenV6WithVault{value: params.quoteAmt}(params);
```

---

## 使用 Copilot Skill 进行审计前自检

> ⚠️ **请在编写集成测试或提交审计前先完成此步。**

本仓库内置了一个 Copilot agent skill —— [`flap-vault-spec-checker`](.agents/skills/flap-vault-spec-checker/) —— 用于按 Flap VaultPortal 协议规范自动审计你的 Vault 与 Factory 合约。它会检查继承关系、`receive()` gas 上限、公平性规则、UI 友好度、集成测试覆盖等内容。**请优先运行此检查。**

### 如何运行此 Skill

在 VS Code 中打开本仓库并启用 GitHub Copilot，Skill 会被自动识别。直接让 Copilot 审计你的 Vault：

```
audit my vault at src/MyVault.sol
```

或：

```
check flap spec compliance for src/MyVault.sol
```

Copilot 会按完整的合规清单逐条检查，并以 ✅ PASS、❌ FAIL 或 ⚠️ WARNING 报告每条规则。

| 结果 | 含义 |
|--------|---------|
| ✅ 全部通过 | Vault 符合规范 —— 可以进入集成测试阶段 |
| ⚠️ 警告 | 非关键问题，建议在审计前确认 |
| ❌ 失败 | 规范违规项，必须在审计前修复 |

完整规则列表与排错指引请参见 [Skill README](.agents/skills/flap-vault-spec-checker/SKILL.md)。

### 通过自检之后

当所有规则均通过（无 ❌ 失败）后，即可进入下面的集成测试阶段。即便不联系我们，你也可以直接发币，但在第三方审计完成前，你的 Vault 默认会显示一条警告信息。完成测试后，**请联系我们安排最终的第三方审计，并移除 Flap.sh 上 Vault 的警告信息。**
强烈建议在发币前完成此步骤，因为发币之后你可能无法再修改 Vault 实现或行为，部分问题届时将无法再被修复。

---

## 审计前的集成测试

> ⚠️ **在提交安全审计前，你必须通过所有集成测试。**
>
> 审计师会将你的测试套件作为审计工作的一部分进行评估。一个无集成测试 —— 或测试失败 —— 的 Vault 表明其基础正确性都未被验证，将显著增加审计的范围与成本。**清除审计警告标记最快的方式，就是写好覆盖 Vault 主要逻辑的集成测试，并使其全部通过。**
>
> **最终的审计由第三方完成。即便不先联系我们，你也可以直接发币，但在第三方审计完成前，警告信息会一直默认显示。在你完成上述自检步骤、并通过全部集成测试后，请联系我们安排最终审计，以移除 Flap.sh 上 Vault 的警告信息。建议在发币前完成此步骤，因为发币之后你可能无法再修改 Vault 配置，部分问题届时也无法再被修复。**

本仓库提供了一份基于主网 fork 的测试 fixture（[`test/FlapBSCFixture.sol`](test/FlapBSCFixture.sol)），以及一份完整的 FreeCoinBeacon Vault 集成测试套件（[`test/FreeCoinBeacon.mainnet.t.sol`](test/FreeCoinBeacon.mainnet.t.sol)），可作为模板使用。

### 审计前必备的测试覆盖

至少应覆盖以下场景：

| # | 场景 | 应断言什么 |
|---|----------|----------------|
| 1 | Factory 在 `newTokenV6WithVault()` 时部署 Vault | `vaultPortal.getVault(token).vault != address(0)` |
| 2 | Vault 接线正确 | `taxProcessor.marketAddress() == vault` |
| 3 | 在联合曲线上买入 → 派发 | 派发不 revert；Vault 行为与设计一致（具体断言依 Vault 逻辑而定，例如余额增加、代币分发、状态更新等）|
| 4 | 代币毕业到 DEX → 卖出 → 派发 | 上 DEX 后派发依然成功；Vault 在收到卖出税收益后的行为与设计一致 |
| 5 | Vault 主操作成功（如 `claim()`） | Vault 预期效果：派发、状态变化、事件，或该操作设计上应做的事 |
| 6 | Vault 主操作的访问受控 | 非法调用按预期 revert（例如重复领取、冷却未到、未授权调用者等） |

测试 1–4 是**协议集成测试** —— 验证你的 Vault 能正确接入 Flap 协议、派发管线能在不 revert 的情况下抵达你的 Vault。Vault 收到资金后的具体行为完全由你的实现决定，按 Vault 的设计断言其行为即可。测试 5–6 是 **Vault 业务逻辑测试** —— 验证 Vault 自身的业务规则被正确执行。审计前两者缺一不可。

### 运行测试

```bash
# 在 BSC 主网 fork 上运行所有集成测试
forge test --match-path test/FreeCoinBeacon.mainnet.t.sol -vvv \
    --fork-url https://bsc-dataseed.bnbchain.org

# 运行单个测试
forge test --match-test test_buyOnBCAndDispatch -vvvv \
    --fork-url https://bsc-dataseed.bnbchain.org
```

进入审计前，所有测试必须通过（`0 failed`）。

### 测试中的 prank 约定

请始终使用 `vm.startPrank(user)` / `vm.stopPrank()`，不要使用裸的 `vm.prank(user)`。多个 fixture 辅助方法（如 `_sell()`）内部会发起多次外部调用（先 `approve` 后 `swapExactInput`）。`vm.prank()` 仅覆盖**下一次**调用，会让后续调用以错误的发送者身份继续执行，导致难以排查的偶发 revert。

```solidity
// ✅ 正确
vm.startPrank(user1);
_sell(token, amount);   // approve + swapExactInput —— 都被覆盖
vm.stopPrank();

// ❌ 错误 —— swapExactInput 实际以 address(this) 而非 user1 运行
vm.prank(user1);
_sell(token, amount);
```
