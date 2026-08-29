// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IPancakeRouter02, IPancakeFactory} from "src/lib/interfaces/IPancakeRouter02.sol";
import {Clones} from "src/Clones.sol";

// ---------------------------------------------------------------------------
// 自定义错误
// ---------------------------------------------------------------------------

error BuyFeeTooHigh();
error SellFeeTooHigh();
error InvalidFeeRecipient();
error InvalidTaxDuration();
error InvalidAntiFarmerDuration();

// ============================================================================
// TokenFactory - 克隆 FlapTaxTokenV3 模板 + 创建 Pair
// ============================================================================

struct TokenConfig {
    string name;
    string symbol;
    string meta; // 代币描述/元数据 IPFS CID（对齐 IFlapTaxTokenV3.InitParams.meta）
    uint16 buyTax; // 买税 bps（上限 MAX_TAX_BPS = 1000 即 10%）
    uint16 sellTax; // 卖税 bps（上限 MAX_TAX_BPS = 1000 即 10%）
    address feeRecipient; // 唯一税金收款人（税金清算 swap 成 BNB 后接收；也是各类失败路径的兜底接收）
    uint256 taxDuration; // 税持续时间（秒）
    uint256 antiFarmerDuration; // 防 farm 税持续时间（秒，<= taxDuration，支持 0）
    uint256 liqExpectedOutputAmount; // 清算参考输出（BNB wei，0 = 关闭方向调节）
}

contract TokenFactory is AccessControl {
    bytes32 public constant COORDINATOR_ROLE = keccak256("COORDINATOR_ROLE");

    /// @notice 买卖税率上限：1000 bps = 10%（产品规则）
    uint256 public constant MAX_TAX_BPS = 1000;

    // FlapTaxTokenV3 实现合约（含 MIN/START_LIQ_THRESHOLD immutables）
    address public immutable flapImplementation;
    address public immutable routerAddress;

    struct TokenBundle {
        address token;
        address pair;
    }

    event TokenCreated(address indexed token, address indexed creator, address pair);

    constructor(address _flapImplementation, address _router, address _coordinator) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COORDINATOR_ROLE, _coordinator);
        flapImplementation = _flapImplementation;
        routerAddress = _router;
    }

    /// @dev 部署克隆 → 创建 V2 交易对。TaxProcessor 由 Coordinator 部署并初始化（其部署者为调用链协调器）。
    ///      salt == 0 走 CREATE（默认随机地址）；salt != 0 走 CREATE2 确定性地址（付费预留 CA / 五连 8 靓号档位，
    ///      目标地址已被占用时按 EIP-684 回滚 CloneFailed，天然防重复发币）。
    function createToken(TokenConfig memory config, bytes32 salt)
        external
        onlyRole(COORDINATOR_ROLE)
        returns (TokenBundle memory)
    {
        if (config.buyTax > MAX_TAX_BPS) revert BuyFeeTooHigh();
        if (config.sellTax > MAX_TAX_BPS) revert SellFeeTooHigh();
        if (config.feeRecipient == address(0)) revert InvalidFeeRecipient();
        if (config.taxDuration == 0) revert InvalidTaxDuration();
        if (config.antiFarmerDuration > config.taxDuration) {
            revert InvalidAntiFarmerDuration();
        }

        address token;
        if (salt == bytes32(0)) {
            token = Clones.clone(flapImplementation);
        } else {
            token = Clones.cloneDeterministic(flapImplementation, salt);
        }

        IPancakeRouter02 router = IPancakeRouter02(routerAddress);
        address pair = IPancakeFactory(router.factory()).createPair(token, router.WETH());

        emit TokenCreated(token, tx.origin, pair);
        return TokenBundle({token: token, pair: pair});
    }

    /// @notice 预言 CREATE2 确定性部署地址（与 createToken 非 0 盐路径一一对应），供预留校验与前端搜盐。
    ///         前端可循环调用本视图完成尾缀搜索；或以本函数结果为基准在本地复刻同一公式提速。
    function predictTokenAddress(bytes32 salt) external view returns (address predicted) {
        return Clones.predictDeterministicAddress(flapImplementation, salt, address(this));
    }
}
