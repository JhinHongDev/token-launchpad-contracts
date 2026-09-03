# 前端对接文档 — Token Launchpad（BSC 测试网）

> 合约版本：2026-09-03 部署（testnet 分支：vestingDelay 下限放宽至 1 分钟；含"领取即上线"改造：`claimAllTokens` 内嵌迁移 + 全出口统一 renounce）
> 部署验证：链上冒烟测试全绿（发币 → 一键领取 → 税生效 → 池转账），交易哈希见附录 A

---

## 目录

1. [网络与合约地址](#1-网络与合约地址)
2. [两条业务流程](#2-两条业务流程)
3. [参数详解](#3-参数详解)
4. [状态机与事件](#4-状态机与事件)
5. [价格方案](#5-价格方案)
6. [错误对照表](#6-错误对照表)
7. [注意事项与坑位清单](#7-注意事项与坑位清单)
8. [视图函数清单](#8-视图函数清单)
9. [ethers v6 快速上手](#9-ethers-v6-快速上手)
10. [附录 A：部署核验记录](#附录-a部署核验记录)

---

## 1. 网络与合约地址

### 1.1 网络

| 项 | 值 |
|---|---|
| 链 | BSC 测试网（BNB Smart Chain Testnet） |
| chainId | `97` |
| RPC（HTTP） | `https://bsc-testnet-rpc.publicnode.com` |
| RPC（WebSocket） | `wss://bsc-testnet-rpc.publicnode.com` |
| 区块浏览器 | `https://testnet.bscscan.com` |

### 1.2 本平台合约（2026-09-03 部署，testnet 分支）

| 合约 | 地址 | 前端是否直接交互 |
|---|---|---|
| **CoordinatorFactory（唯一入口）** | `0xfb5a2029D8464C3dFB4baEaD9ee44853E2f9cA45` | ✅ 主要交互对象 |
| FlapTaxTokenV3 实现（模板） | `0x0eB92ffcA94EB424C6fbD93698dB9490533A0AcA` | ❌ 仅克隆实现，不直接调用 |
| TokenFactory | `0xab363c6410296A3f39D01d278A34adA9517A5e25` | ❌ 由 Coordinator 调度 |
| PRESALE 模板 | `0x48a4a9f357Ac0AE1d4118Efc6e0Be320D3f103eC` | ❌ 仅克隆实现 |
| PresaleFactory | `0x236a6752323324F23301958b06B9b17cB8151294` | ❌ 由 Coordinator 调度 |

### 1.3 第三方合约（PancakeSwap V2 测试网）

| 合约 | 地址 |
|---|---|
| Router V2 | `0xD99D1c33F9fC3444f8101754aBC46c52416550D1` |
| Factory V2 | `0x6725F303b657a9451d8BA641348b6761A6CC7a17` |
| WBNB | `0xae13d989daC2F0dEbFf460aC112a837C89BAa7cd` |

### 1.4 平台费用（读链获取，勿硬编码）

- 发币费 `coordinator.creationFee()` — 当前 **0.005 BNB**
- 地址预留费 `coordinator.reservationFee()` — 当前 **0.01 BNB**

两处均为"多退少不补"：`msg.value > 费用` 时超额部分**同交易自动退回**（事件 `ExcessRefunded`）。

### 1.5 ABI 获取

单一信息源，合约更新后自动同步，**勿复制粘贴 ABI 到前端仓库**：

```bash
# 方式一：forge inspect（推荐，按合约名，输出 JSON 含 abi + bytecode）
forge inspect CoordinatorFactory json > coordinator.json
forge inspect PRESALE json > presale.json
forge inspect FlapTaxTokenV3 json > token.json

# 方式二：编译产物（forge build 后生成；注意本仓库产物按「文件名」平铺在 out/ 根下，非嵌套路径）
out/CoordinatorFactory.sol/CoordinatorFactory.json   # 取其中 abi 字段
out/Presale.sol/PRESALE.json                         # 同目录另有 ITokenMigration.json
out/FlapTaxTokenV3.sol/FlapTaxTokenV3.json
```

> 提取纯 ABI（前端可直接 import 的数组）：
> ```bash
> cast abi-json out/Presale.sol/PRESALE.json 2>/dev/null || \
> python3 -c "import json;json.dump(json.load(open('out/Presale.sol/PRESALE.json'))['abi'],open('presale.abi.json','w'),indent=2)"
> ```
>
> ⚠️ `out/` 在 .gitignore 中且会被 `forge clean` 清空——前端构建流程不要依赖仓库内拷贝，应在 CI 里执行 `forge build` / `forge inspect` 动态生成，或由后端发布 ABI 包。

前端主要需要的 ABI：`CoordinatorFactory`（发币/配置入口）、`PRESALE`（每个代币的托管仓实例，地址由 `tokenPresales(token)` 查得）、`FlapTaxTokenV3`（ERC20 + `state()` + `maxSupply()`）、Pancake `IPancakePair`/`IPancakeRouter02`（价格与加池）。

---

## 2. 两条业务流程

> 核心心智模型：**状态迁移全部由合约在"出口动作"内代办**，用户全程不接触状态机。
> `createToken` 后 token 所有权自动在托管仓（`launch`/`claimAllTokens`/`reclaimTokens` 的迁移编排前提）；任一出口完成后 token **必然无主（owner = 0x0）**。

### 2.1 流程 A：纯发币（不预售）— 共 2 笔交易

```
① coordinator.createToken(config, salt)      创建者，payable ≥ creationFee
      └→ 链上自动：克隆代币 + 建 Pair + 部署 TaxProcessor + 建托管仓
         全量代币入托管仓，token 所有权 → 托管仓，托管仓所有权 → 创建者

② presale.claimAllTokens()                   创建者（托管仓 owner）
      └→ 一笔内自动：startMigration → finalizeMigration（税生效）
         → renounceOwnership → 全量代币发放给创建者
         事件：AllTokensClaimed + 两条 PoolStateChanged(0→1, 1→2)
```

**领取完成后的代币 = 普通的已上线 FoT 代币**：
- 分发：直接 `transfer` 转账
- 加池/交易：随时去 PancakeSwap 标准 V2 界面操作（approve + addLiquidityETH），数量与时机完全由用户决定
- 买卖税按发币配置即时生效（见 7.3）

### 2.2 流程 B：预售开盘 — 共 6 笔交易

| # | 调用 | 调用者 | payable | 前置状态 |
|---|---|---|---|---|
| ① | `coordinator.createToken(config, salt)` | 创建者 | `≥ creationFee` | 工厂启用 |
| ② | `coordinator.setupPresale(token, pConfig)` | 创建者 | 可选（创建者购买注资） | 未配置过（一次性） |
| ③ | `presale.openPresale()` | 创建者 | — | `presaleStatus == 0` |
| ④ | `presale.subscribe()` × N | 散户 | 认购 BNB | `presaleStatus == 1` 且过 `startTime` |
| ⑤ | `presale.endPresale()` | 创建者 | — | `presaleStatus == 1` |
| ⑥ | `presale.launch()` | 创建者 | — | `presaleStatus == 2` 且 `accumulatedBNB ≥ minLiquidityAmount` |

`launch()` 一笔内自动：`startMigration → 加池(20% 底池份额 + 全部募资 BNB, LP 死锁 0xdead) → 创建者购买(若注资) → finalizeMigration(税生效) → renounceOwnership`。**无需任何手动移交/迁移操作。**

开盘后（`presaleStatus == 3`）：

| 动作 | 调用者 | 说明 |
|---|---|---|
| `claim()` | 散户/创建者 | 按 vesting 周期领取（30% 创建者份额 + 50% 认购份额共用本函数） |
| `withdrawUnsoldTokens()` | 创建者 | 提取未售出的预售份额（同 vesting 节奏） |
| `withdrawRemainingBNB()` | 创建者 | 提取路由器找零等残留 BNB |

### 2.3 分支：预售失败（未达 softCap）

`endPresale` 时 `accumulatedBNB < softCap` → `presaleStatus == 4`（发行失败终态）：

| 动作 | 调用者 | 说明 |
|---|---|---|
| `refund()` | 各认购者 | 精确取回本人全部缴款（按 `contributions` 账本，无截留） |
| `reclaimTokens()` | 创建者 | 回收全部代币；**同笔内嵌迁移 + renounce**（领取即上线） |

### 2.4 可选分支：确定性靓号地址（CREATE2）

```
① tokenFactory.predictTokenAddress(salt)          —— 纯视图，前端链下搜盐
② coordinator.reserveTokenAddress{value: ≥reservationFee}(salt)  —— 预留权属（永久，不退款）
③ coordinator.createToken(config, salt)            —— 兑现（他人已预留的盐会被 NotReserver 拒绝）
```

`salt == 0` 表示随机地址，跳过 ①②。

---

## 3. 参数详解

### 3.1 `TokenConfig`（发币配置，9 字段）

```solidity
struct TokenConfig {
    string  name;                    // 代币名，非空
    string  symbol;                  // 符号，非空
    string  meta;                    // 元数据 URI（IPFS CID 等），可为空串
    uint16  buyTax;                  // 买税 bps，0 ≤ x ≤ 1000（即 0–10%）
    uint16  sellTax;                 // 卖税 bps，0 ≤ x ≤ 1000
    address feeRecipient;            // 唯一税金收款人（税清算 swap 成 BNB 后到账；各类失败兜底接收）
    uint256 taxDuration;             // 税持续时间（秒），开盘/领取时开始计时，到期自动 TaxFree
    uint256 antiFarmerDuration;      // 防夹持续时间（秒），必须 ≤ taxDuration，可为 0
    uint256 liqExpectedOutputAmount; // 清算方向调节参考值（BNB wei）；0 = 关闭该特性，建议前端固定传 0
}
```

注意事项：
- `buyTax`/`sellTax` 超过 1000 bps 直接 revert（`InvalidPrice` 之外的 `TokenFactory` 校验），前端滑杆限制 0–10%
- 代币固定 **18 位小数**、固定总量（读 `token.maxSupply()`，当前测试网为 `1e6 ether` = 100 万枚；**主网上线将恢复 10 亿，前端严禁硬编码**）
- 代币支持 ERC20Permit（`permit` 签名授权可用）

### 3.2 `PresaleConfig`（预售配置，10 字段，仅 `setupPresale` 一次性生效）

```solidity
struct PresaleConfig {
    uint256 presaleTokenPrice;    // 预售价：每 1 枚代币的 BNB 价格（wei，18 位）。
                                  //   例：1e15 = 0.001 BNB/枚。必须 > 0
    uint256 maxBuyPerWallet;      // 每钱包认购上限（代币 wei）。必须 > 0，否则 subscribe 恒 revert
    uint256 hardcap;              // 募资硬顶（BNB wei），0 = 不限
    uint256 minLiquidityAmount;   // 加池最低 BNB（也是 launch 的 InsufficientBNB 门槛）
    uint256 softCap;              // 认购成功线（BNB wei）：endPresale 时未达 → 发行失败开退款。
                                  //   必须且会被校验 ≥ minLiquidityAmount
    uint256 startTime;            // 认购开始时间戳（秒），0 = 立即
    uint256 vestingDelay;         // vesting 周期长度（秒）：testnet 分支 1 分钟 ≤ x ≤ 90 天（主网口径 7 天）
    uint256 vestingRate;          // 每周期释放百分比：5 ≤ x ≤ 20
    uint256 slippage;             // 加池滑点保护 bps，0 ≤ x ≤ 1000（0 = 用默认 5%）
    uint256 creatorBuyTokens;     // 创建者购买目标（代币 wei）；0 = quote 模式（花掉全部注资随行就市）
                                  //   上限 = 底池份额 × 25%
}
```

**硬约束速查**（前端表单校验对齐）：

| 字段 | 合法区间 | 违规错误 |
|---|---|---|
| `presaleTokenPrice` | > 0 | `InvalidPrice` |
| `maxBuyPerWallet` | > 0 | `InvalidMaxBuyPerWallet` |
| `minLiquidityAmount` | > 0 | `ZeroMinLiquidity` |
| `softCap` | ≥ `minLiquidityAmount` | `SoftCapTooLow` |
| `vestingDelay` | 1 分钟 ~ 90 天（testnet 分支标定；主网口径 7 天） | `InvalidVestingDelay` |
| `vestingRate` | 5 ~ 20 | `InvalidVestingRate` |
| `slippage` | ≤ 1000 | `SlippageTooHigh` |
| `creatorBuyTokens` > 0 时 | 注资 msg.value > 0 | `CreatorBuyTokensWithoutFunding` |

**份额是合约写死的，不由用户配置**：30% 创建者 / 20% 底池 / 50% 预售（基于代币总量）。前端不要提供这三个输入框。

### 3.3 `setupPresale` 的 msg.value 语义（创建者购买注资）

- `msg.value == 0`：不注资，`launch` 行为与无购买完全一致
- `msg.value > 0` 且 `creatorBuyTokens == 0`（quote 模式）：launch 时花掉全部注资随行就市买入
- `msg.value > 0` 且 `creatorBuyTokens > 0`（token 模式）：精确买入目标数量，超额同交易退回
- 误注资可撤回：`presale.withdrawCreatorBuy()`（开盘前任意状态可用）

### 3.4 `subscribe` 的到账公式

```
认购代币量（1e18 精度）= msg.value(wei) × 1e18 / presaleTokenPrice
```

例：价 1e15（0.001 BNB/枚），付 1 BNB → 得 1,000 枚。

---

## 4. 状态机与事件

### 4.1 托管仓 `presaleStatus`（PRESALE 实例上读）

| 值 | 含义 | 允许的下一步 |
|---|---|---|
| 0 | 创建/配置期 | `setupPresale`（协调器）/ `claimAllTokens` / `openPresale` |
| 1 | 认购中 | `subscribe` / `endPresale` |
| 2 | 认购结束（达 softCap） | `launch` |
| 3 | 已开盘 | `claim` / `withdrawUnsoldTokens` / `withdrawRemainingBNB` |
| 4 | 发行失败（STATUS_FAILED） | `refund`（散户）/ `reclaimTokens`（创建者） |

### 4.2 代币 `token.state()`（PoolState，克隆代理上读）

| 值 | 含义 | 税 |
|---|---|---|
| 0 BondingCurve | 初始态，**与池子的转账被禁止** | 无 |
| 1 Migrating | 迁移中（仅存在于编排交易内部） | 无 |
| 2 TaxEnforcedAntiFarmer | 税 + 防夹生效期 | 买卖税 + 防夹 |
| 3 TaxEnforced | 防夹期结束、税继续 | 买卖税 |
| 4 TaxFree | 税到期 | 无 |

正常流程下 0→1→2（→3→4 随时间自动）全部发生在出口交易内，前端只需把 `state ≥ 2` 理解为"已上线"，`state == 0` 理解为"未上线"。**旧版合约创建的代币可能长期停在 0**（见 7.8）。

### 4.3 所有权时间线（新代币）

```
createToken → 出口动作（claimAllTokens / launch / reclaimTokens）
owner=托管仓              owner=0x0（出口交易内自动 renounce）
```

前端判定"是否已上线/是否可信"建议组合读：`token.state() >= 2 && token.owner() == 0x0`。

### 4.4 关键事件与 topic0（WebSocket 订阅 / 索引）

| 事件 | topic0（keccak） | 用途 |
|---|---|---|
| `TokenPresalePairCreated(address,address,address,uint256)` | `0xd82d53ac9fb3ce23bd37e0b97a838b1dd1a29249c5fc8044b050d2717bfe7ac6` | 新代币上架（coordinator 上监听，全量列表增量维护） |
| `PoolStateChanged(uint8,uint8)` | `0x415234d2d8252539e96fb6c66ec4b3a9fd441ef58da0de24639c3e655503ec2d` | 上线信号（token 地址上监听；0→1→2 连续两条 = 出口交易执行） |
| `AllTokensClaimed(address,uint256,uint256)` | `0x9beb1609b7ce6d449a3807626b3c2a8fdfd28db995c202b8ab5ec5c6820b950d` | 纯发币领取完成 |
| `Subscribed(address,uint256,uint256)` | `0xf94991dcbea6e8ac439cbc93bd9c62a4d39f04e0ad656df9a703f13552c2787f` | 认购流水 |
| `PresaleFailed(uint256,uint256)` | `0xd0ded4316a63c0a62ce3e3bcc0c0feac58db8ad9c7a81ee1c347a0ec94bea5cc` | 发行失败信号 |
| `LaunchFinalized(uint256,uint256,uint256)` | `0x263b23d9b2cab56070be836744ca814236a9e4ea7a3843341ec410490c2940c2` | 预售开盘完成 |
| `Refunded(address,uint256)` | `0xd7dee2702d63ad89917b6a4da9981c90c4d24f8c2bdfd64c604ecae57d8d0651` | 失败退款 |
| `TokensReclaimed(address,uint256)` | `0x22a8aff78fe371f7e69a64e6fc4276227e72c6512ccee617ff32eef318f4a9f3` | 失败代币回收 |
| `VestingClaimed(address,uint256,uint256)` | `0x4a94c2c356e29a6583071e731bdacf2ca56565ba5efebcff6936eb7923b51721` | vesting 领取 |
| Pancake `Sync(uint112,uint112)` | `0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1` | 池储备变化 → 实时价格推送 |

---

## 5. 价格方案

### 5.1 预售阶段（`presaleStatus 0/1/2`，池子无流动性）

价格 = 固定认购价，直接读托管仓：

```js
const price = await presale.presaleTokenPrice()   // wei，每枚代币的 BNB 价格
```

无需刷新，配置后不变。

### 5.2 上线后（池子有流动性，`presaleStatus == 3` 或纯发币领取完成）

从 Pancake pair 读储备比值：

```js
const pair = await presale.lpAddress()   // 或 PancakeFactory.getPair(token, WBNB)
const [t0, r0, r1] = await Promise.all([
  pair.token0(), pair.getReserves()      // 返回 [reserve0, reserve1, timestamp]
])
const isToken0 = t0.toLowerCase() === token.toLowerCase()
const tokenReserve = isToken0 ? r0 : r1
const bnbReserve   = isToken0 ? r1 : r0
const priceInBNB = bnbReserve / tokenReserve   // 代币与 WBNB 均 18 位小数，直接相除
```

**实时推送**：WebSocket 订阅 pair 的 `Sync` 事件（topic0 见 4.4），每次交易触发储备变化即推送；备选 3–5 秒轮询 `getReserves()`。

**USD 换算**：`priceInBNB × BNB/USD`。BNB/USD 用同链 `router.getAmountsOut(1e18, [WBNB, USDT])` 或币安公共 API（`/api/v3/ticker/price?symbol=BNBUSDT`）。

### 5.3 展示价 vs 执行价

- 储备比值 = 中间价，用于展示
- "买入 X 枚实际花费" 用 `router.getAmountsOut(...)`（含 0.25% 路由费 + 滑点），两者语义不同
- FoT 提示：买家实收 = 报价输出 × (1 − buyTax/10000)

### 5.4 无流动性的兜底展示

`tokenReserve == 0`（纯发币已领取但用户尚未加池）→ 显示"未开盘/无流动性"，不要展示 0 价格。

### 5.5 市值（Market Cap / FDV）

本平台代币**总量恒定**（无增发、无销毁），MCap = FDV，按行业惯例直接用全量计算：

```
市值(USD) = 价格(USD) × totalSupply
```

| 阶段 | 价格来源 | 说明 |
|---|---|---|
| 预售中 | `presaleTokenPrice()`（固定认购价） | 预售估值的展示口径 |
| 已上线 | pair 储备比（5.2 节） | 随 `Sync` 订阅实时更新 |
| 未开盘/无流动性 | — | 显示"—"，勿显示 0 |

实现要点：

```js
const totalSupply = await token.totalSupply()   // 只读一次并缓存（恒定；勿硬编码：测试网 1M、主网 1B）
const priceBNB  = Number(bnbReserve) / Number(tokenReserve)
const mcapUSD   = priceBNB * bnbUsd * Number(totalSupply) / 1e18
```

- **BNB/USD**：测试网用币安公共 API（`/api/v3/ticker/price?symbol=BNBUSDT`，测试网 BNB 无真实价，按惯例用主网价展示）；主网可切链上 `router.getAmountsOut(1e18, [WBNB, USDT])` 免外部依赖
- 市值更新与价格共用同一 `Sync` 订阅，无额外请求
- 若产品要做更严的"流通盘"口径（剔除托管仓/创建者持仓）需自建账本——对 meme 发射平台不建议，固定总量代币 MCap=FDV 是扫描器与竞品的通行展示

---

## 6. 错误对照表

> 全部为 custom error（无参数），revert data 前 4 字节即 selector。
> 前端捕获 `error.data`，截取前 10 字符匹配下表映射友好文案。

### 6.1 CoordinatorFactory（发币入口）

| selector | 错误 | 触发场景 | 建议文案 |
|---|---|---|---|
| `0x432acbfd` | FactoryDisabled | 平台暂停服务 | 平台维护中，暂不可发币 |
| `0x535b7470` | InsufficientCreationFee | msg.value < creationFee | 发币费不足 |
| `0xe2592aed` | EmptyTokenName | name 为空 | 请填写代币名 |
| `0x19c7070a` | EmptyTokenSymbol | symbol 为空 | 请填写符号 |
| `0x259ba1ad` | TokenNotRegistered | setupPresale 的 token 非本平台创建 | 代币不存在 |
| `0x57deb26a` | NotTokenCreator | 非创建者调 setupPresale | 仅创建者可操作 |
| `0x11b61b6a` | AlreadyConfigured | 重复 setupPresale | 预售条款一次性配置，不可修改 |
| `0x1a16b58e` | InvalidMaxBuyPerWallet | maxBuyPerWallet = 0 | 单钱包上限必须大于 0 |
| `0xff3bfcc7` | ZeroMinLiquidity | setupPresale 传 minLiquidityAmount = 0 | 加池下限必须大于 0 |
| `0xc6614516` | CreatorBuyTokensWithoutFunding | creatorBuyTokens>0 但未注资 | 请附购买注资 |
| `0x81e69d9b` | InvalidSalt | reserveTokenAddress salt=0 | 盐值非法 |
| `0x3f5aba5f` | InsufficientReservationFee | 预留费不足 | 预留费不足 |
| `0x5e72c18e` | AddressAlreadyReserved | 地址已被预留 | 该地址已被他人锁定 |
| `0xd64bf586` | AddressAlreadyDeployed | 预言地址已有代码 | 地址已被占用 |
| `0x106874c5` | NotReserver | 兑现他人预留的盐 | 该靓号已被他人预留 |

### 6.2 PRESALE（托管仓）

| selector | 错误 | 触发场景 | 建议文案 |
|---|---|---|---|
| `0xe87ff4be` | PresaleDisabled | 纯发币模式下调了预售函数 | 该代币未开启预售 |
| `0x00bfc921` | InvalidPrice | 预售价为 0 | 价格非法 |
| `0x755f0ed3` | InvalidVestingDelay | vestingDelay 超出 1 分钟 ~ 90 天（testnet 分支标定） | 领取周期须在 1 分钟 ~ 90 天之间 |
| `0x416c61ed` | InvalidVestingRate | vestingRate 超出 5 ~ 20 | 每期释放比例须在 5%~20% |
| `0xf525e320` | InvalidStatus | 状态不对（各类状态守卫兜底） | 当前状态不可执行该操作 |
| `0x7963e2b5` | PresaleNotOpen | 认购未开放 | 预售未开放 |
| `0x4e16195c` | PresaleNotStarted | 早于 startTime | 预售尚未开始 |
| `0x7c946ed7` | ZeroValue | subscribe 附 0 BNB | 请输入金额 |
| `0xc2f5625a` | AmountTooSmall | 换算代币数为 0 | 金额过小 |
| `0xd4556c36` | PresaleSoldOut | 超出 50% 预售份额 | 已售罄 |
| `0x746f4607` | WalletLimitExceeded | 超单钱包上限 | 超出单钱包限购 |
| `0x5be90159` | HardcapReached | 超募资硬顶 | 已达硬顶 |
| `0xbf64110f` | InsufficientBNB | launch 时募资 < minLiquidity | 流动性门槛未达 |
| `0xe4b16145` | SoftCapTooLow | softCap < minLiquidity | 软顶须不小于加池下限 |
| `0xff3bfcc7` | ZeroMinLiquidity | setPresaleTerms/openPresale 遇 minLiquidityAmount = 0 | 加池下限必须大于 0 |
| `0xa4f81929` | TokensAlreadyClaimed | 重复领取/领取后再开预售 | 已领取，不可重复 |
| `0x969bf728` | NothingToClaim | 可领额度为 0（未到周期/已领完） | 暂无可领取份额 |
| `0x0f3f8610` | NoTokensToClaim | 托管仓余额为 0 | 无代币可领 |
| `0x8dda39df` | NotLaunched | 未开盘就 claim | 尚未开盘 |
| `0xa153fa9e` | NoShare | 无任何份额 | 无可领份额 |
| `0xd7ce20a0` | MigrationStateMismatch | 迁移前置状态异常（防御性，正常流程不可达） | 状态异常，请联系平台 |
| `0x452a0e78` | CreatorBuyTooLarge | 创建者购买超上限 | 超出购买上限 |
| `0x655df0b2` | ZeroCreatorBuyValue | 注资 0 | 注资额必须大于 0 |
| `0xbf72d580` | CreatorBuyLocked | 开盘后操作注资 | 开盘后不可操作注资 |
| `0x7e4625d6` | NoBNBToWithdraw | 无残留 BNB | 无可提取余额 |
| `0xa2e5181c` | NotAfterLaunch | 开盘前调 withdraw 类函数 | 尚未开盘 |

OZ 标准错误：`Ownable: caller is not the owner`（string revert，非 4 字节）→ "仅所有者可操作"。

---

## 7. 注意事项与坑位清单

### 7.1 旧流程遗留认知清除（重要）

- **`launch` 前不需要再调 `token.transferOwnership(presale)`** —— 所有权在 createToken 时已自动交托管仓。旧版用户手册/代码若有此步骤，全部删除
- **纯发币领取后不需要任何"状态迁移"操作** —— `claimAllTokens` 已内嵌。前端文案不要再出现"手动迁移/解锁"引导
- 判定代币是否上线：`token.state() >= 2`；判定可信终态：再加 `token.owner() == 0x0`

### 7.2 费用与退款

- `createToken` / `reserveTokenAddress` 均为"多退少不补"：**传多了同交易退回**，前端无需精确凑数，但建议发送前读 `creationFee()` 预填
- 预留费**不退款、不过期**，确认文案要讲清楚

### 7.3 税的可见影响（FoT 代币特性）

- 买入：买家实收 = 池子输出 × (1 − buyTax/10000)。报价页要标注"含 X% 买入税"
- 卖出/向池转账：到池 97%（卖税 3% 时），税款进代币税仓，攒到清算阈值后自动 swap 成 BNB 转入 `feeRecipient`
- 加池：用户自行在 Pancake 加池时，入池代币按卖向计税（到池 = 95%/97%/…按卖税率）——这是 FoT 固有行为，属预期内

### 7.4 LP 信任差异（买家侧风险展示，必做）

| 路径 | LP 归属 | 前端展示建议 |
|---|---|---|
| 预售 `launch` | **死锁 0xdead，永不可撤池** | 徽标："LP 已锁死 ✅" |
| 纯发币用户自行加池 | **创建者钱包自持，可随时撤池** | 徽标："LP 未锁定 ⚠️ 存在撤池风险" |

判定方式：预售开盘代币直接标 ✅；纯发币代币读 `presale.liquidityAdded()`（false = 用户自加池）。

### 7.5 时间相关参数用秒

`taxDuration` / `antiFarmerDuration` / `vestingDelay` / `startTime` 全部为**秒级时间戳/时长**，前端用 `ethers.toUtf8`/`BigInt` 传整秒，勿传毫秒。

### 7.6 金额单位

全链统一 **wei（18 位）**：BNB 与代币同精度。价格、份额、上限均以 1e18 计。展示层再做 `/1e18` 格式化。

### 7.7 gas 预算参考（实测 @0.1 gwei，BSC 测试网常见价位）

| 操作 | gas | ≈BNB @0.1gwei |
|---|---|---|
| createToken | ~4,430,000 | 0.00044 |
| claimAllTokens | ~124,000 | 0.000012 |
| setupPresale | ~170,000 | 0.000017 |
| subscribe | ~70,000 | 0.000007 |
| launch | ~500,000 | 0.00005 |

钱包至少留 0.01 BNB 余量；gas 价波动时前端读 `ethers.getFeeData()` 估算。

### 7.8 新旧代币区分（存量兼容）

- 本文档地址（1.2 节）只覆盖 **2026-09-03 之后**创建的代币
- 旧部署（8 月末那版）创建的存量代币（如测试币 `0xb940...7F37`、`0x9a3e...215b`）：可能长期停留在 `state == 0`、`owner != 0`——它们没有"领取即上线"能力，用户领币后**无法自行加池**（路由层报 `TransferHelper: TRANSFER_FROM_FAILED`，内层原因是 `Transfers to/from pools are restricted in BondingCurve state`，**与滑点无关**，勿用滑点引导用户）
- 列表页以 `coordinator.getAllTokenPresalePairs(0, N)` 为准（只含新代币）；存量代币如需展示，维护静态 allowlist 并对其单独做状态判定（`state < 2` 显示"未上线"）

**旧部署地址对照（识别存量代币用，勿再交互）**：

| 合约 | 旧地址（已废弃） |
|---|---|
| CoordinatorFactory（旧入口） | `0xd1EC0390D9847A711A0ccEA8AAA383eC59C7680a` |
| FlapTaxTokenV3 实现 | `0x47ab84F2FEFD302e92F2806466d1937C6A0914CB` |
| PRESALE 模板 | `0x25BbCaB8460D53d89eF8D308087A3581bD485C30` |
| PresaleFactory | `0x81754273b6B3DCF536B14c8E37a5154e919a0d19` |
| TokenFactory | `0x0609349969A50e14EF0e9b628CCE9aFB0a183bF9` |

**2026-09-01 部署（上一版，已废弃）**：

| 合约 | 地址 |
|---|---|
| CoordinatorFactory | `0xFD20244a99d4331E842e91F04C75032d427B76DD` |
| FlapTaxTokenV3 实现 | `0xeb233e41a6A134c2B7E0Dd4Cc4ee90dD5478deAD` |
| PRESALE 模板 | `0xbFDE33d88c7376A74c49D5A8c80A6db6e06a5d27` |
| PresaleFactory | `0xaDC0427f6CF23E6a55eB49631e71F06979683562` |
| TokenFactory | `0x14bBbb755B03cb109ECC54c59b6BCff8F90E6144` |

存量代币的判定特征：代币克隆的 impl 指向旧实现 `0x47ab...14cb`，或其托管仓克隆指向旧模板 `0x25bb...5c30`，或 `coordinator.tokenExists(token) == false`。

存量代币救援（创建者用 token owner 钱包执行两笔即可恢复加池能力）：`startMigration()` → `finalizeMigration()`（顺序勿反；可选第三笔 `renounceOwnership()` 对齐新终态）。

### 7.9 其他细节

- `setupPresale` 是**一次性**的：条款配置后不可修改（`AlreadyConfigured`），前端提交前给确认弹窗
- `subscribe` 的硬顶/限购/售罄在**同笔交易内原子校验**，无需前端预检（但预读做按钮置灰体验更好）
- vesting 领取公式：`已释放 = 份额 × vestingRate × 已过周期数 / 100`，周期 = `(now - vestingStart) / vestingDelay`；开盘后下一个周期边界前可领为 0（正常，显示"下期释放时间"用 `getUserVestingStatus` 的 `nextVestingTime`）
- `claim` / `refund` 对散户**免 owner 校验**（各领各的）；`claimAllTokens` / `launch` / `withdrawUnsoldTokens` / `reclaimTokens` 仅创建者
- 代币克隆实例地址即 ERC20 合约地址，`name/symbol/decimals/balanceOf/permit` 全套标准接口可用

---

## 8. 视图函数清单

### 8.1 CoordinatorFactory（入口，只读）

| 函数 | 返回 | 用途 |
|---|---|---|
| `tokenPresales(token)` | address | 代币 → 托管仓地址 |
| `presaleTokens(presale)` | address | 反查 |
| `tokenCreators(token)` | address | 代币 → 创建者 |
| `tokenConfigured(token)` | bool | 是否已配预售 |
| `tokenPairDetails(token)` | `(token, presale, creator, createdAt, name, symbol, totalSupply)` | 详情页一次拉齐 |
| `getTokenPresalePairsByCreator(creator, offset, limit)` | 结构体数组 | "我的代币"分页 |
| `getAllTokenPresalePairs(offset, limit)` | 结构体数组 | 全量列表分页 |
| `getCreatorTokenCount(creator)` / `getTotalTokenCount()` | uint256 | 分页总数 |
| `tokenExists(token)` | bool | 合法性校验 |
| `creationFee()` / `reservationFee()` | uint256 | 费用预填 |
| `factoryEnabled()` | bool | 平台开关 |
| `tokenAddressReserver(predicted)` | address | 靓号预留权属查询 |
| `tokenFactory.predictTokenAddress(salt)` | address | CREATE2 预言地址（纯视图，链下搜盐） |

### 8.2 PRESALE（托管仓实例）

| 函数 | 用途 |
|---|---|
| `getLaunchStatus()` | `(enabled, status, bnbAccumulated, tokensSubscribed, lpAdded, tokensClaimed)` 一次拉齐 |
| `getContractBalances()` | `(tokenBalance, bnbBalance)` |
| `getVestedAmount(user)` | 当前可领 vesting 数量 |
| `getUserVestingStatus(user)` | `(share, claimable, claimed, nextVestingTime)` |
| `presaleTokenPrice()` / `softCap()` / `hardcap()` / `maxBuyPerWallet()` / `startTime()` | 条款展示 |
| `accumulatedBNB()` / `totalSubscribedTokens()` | 进度条（配合 softCap/maxPresaleTokens） |
| `creatorShare()` / `poolShare()` / `presaleShare()` | 固定份额展示 |
| `vestingDelay()` / `vestingRate()` / `vestingStart()` | vesting 说明 |
| `subscribedTokens(user)` / `contributions(user)` / `claimedTokens(user)` | 个人持仓页 |
| `lpAddress()` | pair 地址（价格查询用） |
| `liquidityAdded()` | LP 状态（7.4 风险徽标） |
| `creatorBuyBnb()` / `creatorBuyTokens()` | 创建者购买注资状态 |

### 8.3 代币（克隆实例）

| 函数 | 用途 |
|---|---|
| `state()` | 上线判定（见 4.2） |
| `owner()` | 终态判定（0x0 = 已放弃） |
| `maxSupply()` / `totalSupply()` | 总量（**读链，勿硬编码**） |
| `poolState()` | 打包读取（state/buyTax/sellTax/threshold/…），详情页一次拉 |
| 标准 ERC20 + `permit()` | 转账/授权/签名授权 |

---

## 9. viem 快速上手

```ts
import { createPublicClient, createWalletClient, custom, http, webSocket, parseAbi, formatUnits } from "viem";
import { bscTestnet } from "viem/chains";

const RPC  = "https://bsc-testnet-rpc.publicnode.com";
const WSRPC = "wss://bsc-testnet-rpc.publicnode.com";
const COORDINATOR = "0xfb5a2029D8464C3dFB4baEaD9ee44853E2f9cA45";

const client   = createPublicClient({ chain: bscTestnet, transport: http(RPC) });
const wsClient = createPublicClient({ chain: bscTestnet, transport: webSocket(WSRPC) });
const wallet   = createWalletClient({ chain: bscTestnet, transport: custom(window.ethereum) });

// ---------- ABI（parseAbi 人类可读形式，按需声明用到的条目即可） ----------
const coordinatorAbi = parseAbi([
  "function createToken((string name, string symbol, string meta, uint16 buyTax, uint16 sellTax, address feeRecipient, uint256 taxDuration, uint256 antiFarmerDuration, uint256 liqExpectedOutputAmount) tokenConfig, bytes32 salt) payable returns (address token, address presale)",
  "function creationFee() view returns (uint256)",
  "function tokenPresales(address) view returns (address)",
  "event TokenPresalePairCreated(address indexed token, address indexed presale, address indexed creator, uint256 totalSupply)",
  // 声明了 error，viem 会自动解码 revert
  "error InsufficientCreationFee()", "error FactoryDisabled()",
]);
const presaleAbi = parseAbi([
  "function claimAllTokens()", "function subscribe() payable",
  "function lpAddress() view returns (address)",
  "function presaleTokenPrice() view returns (uint256)",
  "function getLaunchStatus() view returns (bool, uint256, uint256, uint256, bool, bool)",
  "error PresaleNotOpen()", "error WalletLimitExceeded()",
]);
const pairAbi = parseAbi([
  "function token0() view returns (address)",
  "function getReserves() view returns (uint112, uint112, uint32)",
  "event Sync(uint112 reserve0, uint112 reserve1)",
]);
const tokenAbi = parseAbi(["function totalSupply() view returns (uint256)"]);

// ---------- ① 发币（纯发币模式） ----------
const fee = await client.readContract({ address: COORDINATOR, abi: coordinatorAbi, functionName: "creationFee" });
const hash = await wallet.writeContract({
  address: COORDINATOR, abi: coordinatorAbi, functionName: "createToken", account,
  args: [{
    name: "MyToken", symbol: "MTK", meta: "ipfs://Qm...",
    buyTax: 200, sellTax: 300, feeRecipient: account,
    taxDuration: 365n * 86400n, antiFarmerDuration: 86400n, liqExpectedOutputAmount: 0n,
  }, "0x0000000000000000000000000000000000000000000000000000000000000000"],
  value: fee,   // 多退少不补
});
const rc = await client.waitForTransactionReceipt({ hash });
const created = rc.logs.find(l => l.topic0 === "0xd82d53ac9fb3ce23bd37e0b97a838b1dd1a29249c5fc8044b050d2717bfe7ac6");
// 解码 created.args 拿 token / presale 地址

// ---------- ② 一键领取（领取即上线） ----------
const presaleAddr = await client.readContract({ address: COORDINATOR, abi: coordinatorAbi, functionName: "tokenPresales", args: [tokenAddr] });
await wallet.writeContract({ address: presaleAddr, abi: presaleAbi, functionName: "claimAllTokens", account });
// 之后 token.state() == 2、owner == 0x0，用户自行去 Pancake 加池/交易

// ---------- ③ 预售认购（散户） ----------
await wallet.writeContract({ address: presaleAddr, abi: presaleAbi, functionName: "subscribe", account, value: parseEther("1") });

// ---------- ④ 价格 + 市值（Sync 实时推送，见 5.2/5.5） ----------
async function pricing(tokenAddr: `0x${string}`) {
  const pair = await client.readContract({ address: presaleAddr, abi: presaleAbi, functionName: "lpAddress" });
  const [t0, [r0, r1]] = await Promise.all([
    client.readContract({ address: pair, abi: pairAbi, functionName: "token0" }),
    client.readContract({ address: pair, abi: pairAbi, functionName: "getReserves" }),
  ]);
  const isT0 = t0.toLowerCase() === tokenAddr.toLowerCase();
  const tokenReserve = isT0 ? r0 : r1, bnbReserve = isT0 ? r1 : r0;
  const totalSupply = await client.readContract({ address: tokenAddr, abi: tokenAbi, functionName: "totalSupply" }); // 读一次缓存
  return calc({ tokenReserve, bnbReserve, totalSupply });   // 见 5.5 公式
}
const unwatch = wsClient.watchContractEvent({
  address: pair, abi: pairAbi, eventName: "Sync",
  onLogs: ([{ args }]) => calc({ tokenReserve: ..., bnbReserve: ..., totalSupply: cached }),
});

// ---------- ⑤ 错误处理 ----------
// viem：abi 里声明了 error 即自动解码
try { ... } catch (e) {
  const name = e?.name;   // e.g. "ContractFunctionExecutionError"，e.errorName === "PresaleNotOpen"
  toast(ERROR_MAP[e?.errorName] ?? "交易失败，请稍后重试");   // ERROR_MAP 见第 6 章
}
```

---

## 附录 A：部署核验记录（2026-09-03，testnet 分支）

**部署交易**：`forge script script/Deploy.s.sol`（broadcast 产物 `broadcast/Deploy.s.sol/97/run-latest.json`），部署者 `0x463c...21D3`，7 笔交易全部上链成功（5 笔 CREATE + 2 笔角色授权），实际总 gas 12,281,249 @ 0.1 gwei ≈ 0.00123 BNB：

| 合约 | 部署交易 | 地址 |
|---|---|---|
| FlapTaxTokenV3 impl | `0xeb1b82a70a10baf270b29b9c15dc9dc7fd5838ae35c49a685a078accf5f8dd1b` | `0x0eB92ffcA94EB424C6fbD93698dB9490533A0AcA` |
| TokenFactory | `0x850be091da8ef1583ea2732206473a1ddc6d86238ad2372b7a5140c4336cb415` | `0xab363c6410296A3f39D01d278A34adA9517A5e25` |
| PRESALE template | `0xc5b97a7314cb32d8d56afcf368fc4aaf3013459b02c89e73a10ae609c9bd0cc4` | `0x48a4a9f357Ac0AE1d4118Efc6e0Be320D3f103eC` |
| PresaleFactory | `0xd5be11233b48c8369330a5cba1823817fcc553ecc07972e7544716af4feb8295` | `0x236a6752323324F23301958b06B9b17cB8151294` |
| CoordinatorFactory | `0x74c7bc164697e684e049be4b0c185ae93786f27b482b553108f60ff15418f4b0` | `0xfb5a2029D8464C3dFB4baEaD9ee44853E2f9cA45` |
| TokenFactory 授权 | `0x82f746357d4fb2236bf64c25edee9cfd9339d8c14536a3c5dcaaf4058b34d0a9` | — |
| PresaleFactory 授权 | `0xe0f7cba9c3a01f1632ed76b2770735ba2f5626a52648f56088adf540adf4736d` | — |

**接线核验（全通过）**：
- 5 合约均有代码；两工厂 `hasRole(COORDINATOR_ROLE, coordinator) == true`
- `tokenFactory.flapImplementation == 0x0eB9...0AcA`、`presaleFactory.presaleImplementation == 0x48a4...103eC`
- `coordinator.routerAddress == 0xD99D...50D1`、`creationFee == 0.005 BNB`、`reservationFee == 0.01 BNB`、`factoryEnabled == true`

**冒烟测试（testnet 分支特性端到端，全通过）**——核心验证点：**vestingDelay 下限 1 分钟生效**（5 分钟周期配置成功，main 部署上同参数会被 `InvalidVestingDelay` 拒绝）：

| 步骤 | 交易 | 结果 |
|---|---|---|
| createToken（VST 测试币） | `0x66cbbb6350ce6be24062a41467f07ee78b41ce99ba1bb8a9a1d1694a19c04412` | token `0x1a29af77a57600a392794fa4e879e1893af7feaf`，presale `0x2359557cc443d0a0b662fdfd0f141d239cc03c22`；全量 1M 入托管仓，token 所有权自动交托管仓 |
| setupPresale（vestingDelay=300s=5 分钟，rate=20） | `0xcc7ce4063ebf14991ca71d4a32de60b4e552dfc4dfe8e9b40ff6158c25924bbf` | **配置成功**：链上读回 `vestingDelay == 300`、`vestingRate == 20` —— 1 分钟下限验证通过 |
| openPresale | `0x236ed7974dd091590efcbd99c83dec5bd12421685132456777e54d01e78d49ac` | 认购开放 |
| subscribe（散户 0.006 BNB） | `0x122e260dd8ab1d2ad67e9d3406905b4ed0884fc21427673a9b197d558a8eb69f` | 认购成功 |
| endPresale | `0x224ec3929f7b95b1eae8ab4dcf642448c26e1d7a2859f414c85f8a728362b134` | 达标进待开盘 |
| launch | `0x9ab0205733a6429d34c557d38b0a2236e726c6612ab89741cc159dd9155e4a63` | 加池成功：`presaleStatus == 3`、token `state == 2`、`owner == 0x0`、`liquidityAdded == true`、pair `0xAdE3B04A961a8852963A8A59A320204529d3003a` |

**已知存量（旧部署，与本版行为不同）**：`0xb940...7F37`（SillyFunc）等旧代币已按新行为手动迁移完成（state=2），但 owner 仍在创建者手里（未 renounce，纯装饰性差异）；旧代币不在新 coordinator 的列表里，见 7.8。
