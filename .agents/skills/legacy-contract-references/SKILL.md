---
name: legacy-contract-references
description: >
  Historical reference for the OLD (legacy) flap-clone contracts: TokenFactory /
  PresaleFactory / CoordinatorFactory, StagedCustomToken, PRESALE, vendored
  OpenZeppelin dependencies and Pancake interfaces. Use when you need to
  understand WHY the current architecture was refactored, compare old vs new
  design decisions, or check how a legacy feature (bonding curve, inside
  trading, LP burn, vesting) worked. NEVER use as a basis for new code — the
  current contracts (src/Flap*.sol) are the only source of truth. The legacy
  code is NOT compiled and MUST NOT be modified.
---

# Legacy Reference（旧版合约参考）

本 skill 存放 `flap-clone` 第一代（legacy）合约的完整代码，**仅供历史参考**。

> 红线：这些文件**任何情况下都不得改动、不得移植**。它们已从 `src/legacy/` 移出，
> 不再参与 `forge` 编译，仅作为理解旧版设计的历史文档保留。

## 何时使用本 skill

- 需要理解**为什么**当前架构是这样（例如：为什么剔除内盘交易、为什么发币与预售解耦、为什么税收处理器单通道化）
- 对照旧版与新版的**设计差异**（见下方对照表）
- 查询某个旧功能（内盘交易、LP 燃烧、滑点保护、Vesting）曾经如何实现
- 评审新代码时确认没有"继承"旧版低质编码习惯

## 何时不要使用

- 编写任何新合约或修改现有合约时——**一律以 `src/` 下当前代码为准**
- 需要 OZ 库时——直接使用 `@openzeppelin/contracts`（remapping），不要参考 `OpenZeppelinDependencies.sol` 的手写 vendoring

## 文件清单与职责

| 文件 | 内容 | 职责 |
|---|---|---|
| `references/CoordinatorFactory.sol` | `TokenFactory`、`PresaleFactory`、`CoordinatorFactory` 三个合约 | 旧版发币 + 预售 + 统筹流程（含步进式状态机） |
| `references/Token.sol` | `StagedCustomToken`（ERC20, Ownable） | 旧版代币：预设预售合约、内盘交易、LP 燃烧 |
| `references/presaleAA.sol` | `TransferHelper` 库 + `PRESALE` 合约 | 旧版预售：BNB 认购、内盘交易、滑点保护、LP 份额分配（80/20）、Vesting |
| `references/OpenZeppelinDependencies.sol` | 手写 vendored OZ（Context/IERC20/ERC20/Ownable/ReentrancyGuard/AccessControl/Address） | 旧版自带的 OZ 依赖，避免外部依赖 |
| `references/Interfaces.sol` | Pancake V2 Pair/Factory/Router01/Router02 接口 | 旧版 DEX 接口定义 |

## 编码风格警示

旧版代码存在以下已明确废弃的编码习惯，**新代码严禁继承**：

- 大段字符串 `require(..., "STRING_REASON")` → 新版用 Custom Errors
- 跨合约冗余状态同步、混乱 try-catch 链 → 新版高内聚低耦合
- 手写 OZ 依赖 → 新版用官方库
- 虚拟内盘价格逻辑（`insidePrice` / `trade` / `tradeUnlock`）→ 已彻底剔除