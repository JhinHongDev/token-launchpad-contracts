// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./OpenZeppelinDependencies.sol";
import "./Token.sol";
import "./presaleAA.sol";

/**
 * @title 简化协调器模式实现
 * @dev 在单文件中实现3个独立合约，优化后的协调器架构
 *
 * 架构说明：
 * 1. TokenFactory - 专门创建Token合约 (~8KB)
 * 2. PresaleFactory - 专门创建Presale合约 (~19KB)
 * 3. CoordinatorFactory - 协调所有操作并处理配置关联 (~8KB)
 */

// ============================================================================
// 1️⃣ TokenFactory - 专门负责Token创建 (~8KB)
// ============================================================================
contract TokenFactory is AccessControl {
    bytes32 public constant COORDINATOR_ROLE = keccak256("COORDINATOR_ROLE");

    struct TokenConfig {
        string name;
        string symbol;
        uint256 totalSupply;
        uint256 feeBuy;
        uint256 feeSell;
        address feeRecipient;
        bool lpBurnEnabled;
        uint256 lpBurnFrequency;
        uint256 percentForLPBurn;
        uint256 burnLimit;
        uint256 protectTime;
        uint256 protectFee;
        bool isInsideSell;
        uint256 swapThreshold;
    }

    event TokenCreated(address indexed token, address indexed creator);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev 创建Token合约 - 只能由Coordinator调用
     */
    function createToken(TokenConfig memory config)
        external
        onlyRole(COORDINATOR_ROLE)
        returns (address)
    {
        require(config.feeBuy <= 10000, "Buy fee too high");
        require(config.feeSell <= 10000, "Sell fee too high");
        require(config.feeRecipient != address(0), "Invalid fee recipient");

        // 创建高级配置结构体
        StagedCustomToken.BasicAdvancedConfig memory advancedConfig = StagedCustomToken.BasicAdvancedConfig({
            feeBuy: config.feeBuy,
            feeSell: config.feeSell,
            lpBurnEnabled: config.lpBurnEnabled,
            lpBurnFrequency: config.lpBurnFrequency,
            percentForLPBurn: config.percentForLPBurn,
            burnLimit: config.burnLimit,
            protectTime: config.protectTime,
            protectFee: config.protectFee,
            isInsideSell: config.isInsideSell,
            swapThreshold: config.swapThreshold
        });

        // 创建Token实例 - 这里包含了StagedCustomToken的字节码
        StagedCustomToken token = new StagedCustomToken(
            config.name,
            config.symbol,
            config.totalSupply,
            msg.sender, // Coordinator作为临时owner
            config.feeRecipient,
            advancedConfig
        );

        emit TokenCreated(address(token), tx.origin);
        return address(token);
    }

    /**
     * @dev 创建带Salt的Token合约（CREATE2靓号部署） - 只能由Coordinator调用
     */
    function createTokenWithSalt(TokenConfig memory config, bytes32 salt)
        external
        onlyRole(COORDINATOR_ROLE)
        returns (address)
    {
        require(config.feeBuy <= 10000, "Buy fee too high");
        require(config.feeSell <= 10000, "Sell fee too high");
        require(config.feeRecipient != address(0), "Invalid fee recipient");

        // 创建高级配置结构体
        StagedCustomToken.BasicAdvancedConfig memory advancedConfig = StagedCustomToken.BasicAdvancedConfig({
            feeBuy: config.feeBuy,
            feeSell: config.feeSell,
            lpBurnEnabled: config.lpBurnEnabled,
            lpBurnFrequency: config.lpBurnFrequency,
            percentForLPBurn: config.percentForLPBurn,
            burnLimit: config.burnLimit,
            protectTime: config.protectTime,
            protectFee: config.protectFee,
            isInsideSell: config.isInsideSell,
            swapThreshold: config.swapThreshold
        });

        // 使用 CREATE2 部署 Token 实例
        StagedCustomToken token = new StagedCustomToken{salt: salt}(
            config.name,
            config.symbol,
            config.totalSupply,
            msg.sender, // Coordinator作为临时owner
            config.feeRecipient,
            advancedConfig
        );

        // 校验后 4 位 16 进制字符为 8888
        require(
            uint16(uint160(address(token))) == 0x8888,
            "STEP3_INVALID_VANITY_ADDRESS"
        );

        emit TokenCreated(address(token), tx.origin);
        return address(token);
    }
}

// ============================================================================
// 2️⃣ PresaleFactory - 轻量克隆版 (~3KB)
// ============================================================================
contract PresaleFactory is AccessControl {
    bytes32 public constant COORDINATOR_ROLE = keccak256("COORDINATOR_ROLE");

    // 预先部署好的 PRESALE 模板实现合约地址
    address public immutable presaleImplementation;

    struct PresaleConfig {
        uint256 presaleEthAmount;
        uint256 tradeEthAmount;
        uint256 maxTotalNum;
        uint256 presaleMaxNum;
        uint256 marketDisAmount;
        // LP分配相关参数
        uint256 userLPShare;        // 用户LP分配比例 (基于10000)
        uint256 devLPShare;         // 开发团队LP分配比例 (基于10000)
        address devLPReceiver;      // 开发团队LP接收地址
        bool lpDistributionEnabled; // 是否启用LP分配功能

        // === LGE集成参数 ===
        uint256 startTime;          // 预售开始时间
        uint256 hardcap;            // 硬顶限制
        uint256 maxBuyPerWallet;    // 每个钱包最大购买量

        // Vesting参数
        uint256 vestingDelay;       // 释放延迟（7-90天）
        uint256 vestingRate;        // 释放比例（5-20%）
        bool vestingEnabled;        // 是否启用vesting

        // Backing参数
        uint256 backingShare;       // 资产支撑份额（0-50%）
        address backingReceiver;    // 资产支撑接收地址
    }

    event PresaleCreated(address indexed presale, address indexed creator);

    /**
     * @dev 构造函数：指定 PRESALE 模版合约地址
     */
    constructor(address _presaleImplementation) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        presaleImplementation = _presaleImplementation;
    }

    /**
     * @dev 内部函数：使用 EIP-1167 极简代理字节码直接在内联汇编中创建轻量代理合约
     */
    function _clone(address implementation) internal returns (address instance) {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender, tx.origin));
        assembly {
            // EIP-1167 标准 Minimal Proxy 字节码结构
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "ERC1167: create2 failed");
    }

    /**
     * @dev 创建Presale合约 - 只能由Coordinator调用
     */
    function createPresale(PresaleConfig memory config)
        external
        onlyRole(COORDINATOR_ROLE)
        returns (address)
    {
        require(config.presaleEthAmount > 0, "Invalid presale amount");

        // 🎯 核心改动：不再使用 new PRESALE()，而是直接从模板克隆微型代理
        address presaleAddress = _clone(presaleImplementation);
        PRESALE presale = PRESALE(payable(presaleAddress));

        // 初始化代理合约状态并把 owner 设置为当前 PresaleFactory
        presale.initialize(
            address(this),
            0xD99D1c33F9fC3444f8101754aBC46c52416550D1,
            0x337610d27c682E347C9cD60BD4b3b107C9d34dDd
        );

        // 设置预售参数
        presale.setPoolData(
            config.presaleEthAmount,
            config.tradeEthAmount,
            config.maxTotalNum,
            config.presaleMaxNum,
            config.marketDisAmount,
            10 // 固定解锁率
        );

        // 设置LP分配参数（如果启用）
        if (config.lpDistributionEnabled) {
            presale.setLPDistribution(
                config.userLPShare,
                config.devLPShare,
                config.devLPReceiver,
                config.lpDistributionEnabled
            );
        }

        // === 设置LGE集成参数 ===
        if (config.startTime > 0 || config.hardcap > 0 || config.maxBuyPerWallet > 0) {
            presale.setLGEConfig(
                config.startTime,
                config.hardcap,
                config.maxBuyPerWallet
            );
        }

        // 设置Vesting配置（如果启用）
        if (config.vestingEnabled) {
            presale.setVestingConfig(
                config.vestingDelay,
                config.vestingRate,
                config.vestingEnabled
            );
        }

        // 设置Backing配置（如果有backing份额）
        if (config.backingShare > 0) {
            presale.setBackingConfig(
                config.backingShare,
                config.backingReceiver
            );
        }

        // 直接将预售合约所有权转移给 CoordinatorFactory (即 msg.sender)
        presale.transferOwnership(msg.sender);

        emit PresaleCreated(address(presale), tx.origin);
        return address(presale);
    }
}

// ============================================================================
// 3️⃣ Coordinator - 协调所有操作的主入口 (简化版，移除ConfigManager)
// ============================================================================
contract CoordinatorFactory  is Ownable, ReentrancyGuard {

    // === 核心状态变量 ===
    bool public factoryEnabled = true;
    uint256 public creationFee = 1 * 10**16; // 50 TRX
    uint256 public totalPairsCreated = 0;

    // === 工厂合约实例 ===
    TokenFactory public tokenFactory;
    PresaleFactory public presaleFactory;

    // === 兼容性结构体定义 ===
    struct TokenConfig {
        string name;
        string symbol;
        uint256 totalSupply;
        uint256 feeBuy;
        uint256 feeSell;
        address feeRecipient;
        bool lpBurnEnabled;
        uint256 lpBurnFrequency;
        uint256 percentForLPBurn;
        uint256 burnLimit;
        uint256 protectTime;
        uint256 protectFee;
        bool isInsideSell;
        uint256 swapThreshold;
    }

    struct PresaleConfig {
        uint256 presaleEthAmount;
        uint256 tradeEthAmount;
        uint256 maxTotalNum;
        uint256 presaleMaxNum;
        uint256 marketDisAmount;
        // LP分配相关参数
        uint256 userLPShare;        // 用户LP分配比例 (基于10000)
        uint256 devLPShare;         // 开发团队LP分配比例 (基于10000)
        address devLPReceiver;      // 开发团队LP接收地址
        bool lpDistributionEnabled; // 是否启用LP分配功能

        // === LGE集成参数（基于LEG.txt） ===
        uint256 startTime;          // 预售开始时间
        uint256 hardcap;            // 硬顶限制
        uint256 maxBuyPerWallet;    // 每个钱包最大购买量

        // Vesting参数
        uint256 vestingDelay;       // 释放延迟（7-90天）
        uint256 vestingRate;        // 释放比例（5-20%）
        bool vestingEnabled;        // 是否启用vesting

        // Backing参数
        uint256 backingShare;       // 资产支撑份额（0-50%）
        address backingReceiver;    // 资产支撑接收地址
    }

    // === 核心映射 ===
    mapping(address => address) public tokenPresales;      // 代币 => 预售合约
    mapping(address => address) public presaleTokens;      // 预售 => 代币合约
    mapping(address => address) public tokenCreators;      // 代币 => 创建者地址

    // === 查询支持数据结构 ===
    struct TokenPresalePair {
        address tokenAddress;
        address presaleAddress;
        address creator;
        uint256 createdAt;
        string tokenName;
        string tokenSymbol;
        uint256 totalSupply;
    }

    // 创建者 => 代币地址数组
    mapping(address => address[]) public creatorTokens;

    // 所有创建的代币地址数组（用于全局查询）
    address[] public allTokens;

    // 代币地址 => 详细信息
    mapping(address => TokenPresalePair) public tokenPairDetails;

    // === 核心事件 ===
    event TokenPresalePairCreated(
        address indexed token,
        address indexed presale,
        address indexed creator,
        uint256 totalSupply
    );

    event CoordinatorInitialized(
        address tokenFactory,
        address presaleFactory
    );

    event OwnershipTransferred(address indexed token, address indexed presale, address indexed newOwner);
    event TokenPresaleLinked(address indexed token, address indexed presale);

    // === LEG 相关事件 ===
    event LGEConfigSet(
        address indexed presale,
        address indexed token,
        address indexed creator,
        uint256 startTime,
        uint256 hardcap,
        uint256 maxBuyPerWallet
    );

    event VestingConfigSet(
        address indexed presale,
        address indexed token,
        address indexed creator,
        uint256 vestingDelay,
        uint256 vestingRate,
        bool vestingEnabled
    );

    event BackingConfigSet(
        address indexed presale,
        address indexed token,
        address indexed creator,
        uint256 backingShare,
        address backingReceiver
    );

    /**
     * @dev 构造函数 - 部署并初始化所有工厂合约
     */
    constructor(address _presaleImplementation) Ownable() {
        // 部署各个工厂合约
        tokenFactory = new TokenFactory();
        presaleFactory = new PresaleFactory(_presaleImplementation);

        // 授权Coordinator调用各工厂
        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(this));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(this));

        emit CoordinatorInitialized(
            address(tokenFactory),
            address(presaleFactory)
        );
    }

    /**
     * @dev 🎯 核心功能：创建代币和预售合约对（简化协调器模式）
     *
     * 协调器执行流程：
     * 1. 调用TokenFactory创建Token合约
     * 2. 调用PresaleFactory创建Presale合约
     * 3. 直接建立Token和Presale的关联关系
     * 4. 转移所有权给用户
     * 5. 更新状态映射并发射事件
     *
     * 优势：
     * - 每个工厂合约都在24KB限制内
     * - 简化的架构，移除了ConfigManager
     * - 保持完全的接口兼容性
     * - 原子性操作（要么全成功要么全失败）
     */
    function createTokenAndPresale(
        TokenConfig memory tokenConfig,
        PresaleConfig memory presaleConfig
    ) external payable nonReentrant returns (address token, address presale) {
        // 🔍 步骤1: 基础验证
        require(factoryEnabled, "STEP1_FACTORY_DISABLED");
        require(msg.value >= creationFee, "STEP1_INSUFFICIENT_FEE");
        require(bytes(tokenConfig.name).length > 0, "STEP1_EMPTY_TOKEN_NAME");
        require(bytes(tokenConfig.symbol).length > 0, "STEP1_EMPTY_TOKEN_SYMBOL");
        require(tokenConfig.totalSupply > 0, "STEP1_ZERO_TOTAL_SUPPLY");
        require(presaleConfig.presaleEthAmount > 0, "STEP1_ZERO_PRESALE_AMOUNT");

        // 🔍 步骤2: Token工厂验证
        require(address(tokenFactory) != address(0), "STEP2_TOKEN_FACTORY_NULL");

        // 🎯 协调器模式实现 - 调用各个专门的工厂

        // 步骤2: 通过TokenFactory创建Token合约
        // 精度处理: Token 构造函数按原值铸造 (_mint 不乘 10^18),
        // 而下方 approve 授权按 totalSupply * 10**18 计算。
        // 因此这里统一乘 10**18 传给 TokenFactory,
        // 使链上 totalSupply = 用户输入的整数枚数 * 10^18 (与 approve 一致)。
        TokenFactory.TokenConfig memory tokenFactoryConfig = TokenFactory.TokenConfig({
            name: tokenConfig.name,
            symbol: tokenConfig.symbol,
            totalSupply: tokenConfig.totalSupply * 10**18,
            feeBuy: tokenConfig.feeBuy,
            feeSell: tokenConfig.feeSell,
            feeRecipient: tokenConfig.feeRecipient,
            lpBurnEnabled: tokenConfig.lpBurnEnabled,
            lpBurnFrequency: tokenConfig.lpBurnFrequency,
            percentForLPBurn: tokenConfig.percentForLPBurn,
            burnLimit: tokenConfig.burnLimit,
            protectTime: tokenConfig.protectTime,
            protectFee: tokenConfig.protectFee,
            isInsideSell: tokenConfig.isInsideSell,
            swapThreshold: tokenConfig.swapThreshold
        });

        // 🔍 步骤3: 创建Token
        token = tokenFactory.createToken(tokenFactoryConfig);
        require(token != address(0), "STEP3_TOKEN_CREATION_FAILED");

        // 🔍 步骤4: Presale工厂验证
        require(address(presaleFactory) != address(0), "STEP4_PRESALE_FACTORY_NULL");

        // 步骤4: 通过PresaleFactory创建Presale合约
        PresaleFactory.PresaleConfig memory presaleFactoryConfig = PresaleFactory.PresaleConfig({
            presaleEthAmount: presaleConfig.presaleEthAmount,
            tradeEthAmount: presaleConfig.tradeEthAmount,
            maxTotalNum: presaleConfig.maxTotalNum,
            presaleMaxNum: presaleConfig.presaleMaxNum,
            marketDisAmount: presaleConfig.marketDisAmount,
            userLPShare: presaleConfig.userLPShare,
            devLPShare: presaleConfig.devLPShare,
            devLPReceiver: presaleConfig.devLPReceiver,
            lpDistributionEnabled: presaleConfig.lpDistributionEnabled,
            // LGE集成参数
            startTime: presaleConfig.startTime,
            hardcap: presaleConfig.hardcap,
            maxBuyPerWallet: presaleConfig.maxBuyPerWallet,
            vestingDelay: presaleConfig.vestingDelay,
            vestingRate: presaleConfig.vestingRate,
            vestingEnabled: presaleConfig.vestingEnabled,
            backingShare: presaleConfig.backingShare,
            backingReceiver: presaleConfig.backingReceiver
        });

        // 🔍 步骤5: 创建Presale
        presale = presaleFactory.createPresale(presaleFactoryConfig);
        require(presale != address(0), "STEP5_PRESALE_CREATION_FAILED");

        // 🔍 步骤5.1: 触发LEG相关事件
        // 触发LGE基础配置事件（如果有配置）
        if (presaleConfig.startTime > 0 || presaleConfig.hardcap > 0 || presaleConfig.maxBuyPerWallet > 0) {
            emit LGEConfigSet(
                presale,
                token,
                msg.sender,
                presaleConfig.startTime,
                presaleConfig.hardcap,
                presaleConfig.maxBuyPerWallet
            );
        }

        // 触发Vesting配置事件（如果启用）
        if (presaleConfig.vestingEnabled) {
            emit VestingConfigSet(
                presale,
                token,
                msg.sender,
                presaleConfig.vestingDelay,
                presaleConfig.vestingRate,
                presaleConfig.vestingEnabled
            );
        }

        // 触发Backing配置事件（如果有backing份额）
        if (presaleConfig.backingShare > 0) {
            emit BackingConfigSet(
                presale,
                token,
                msg.sender,
                presaleConfig.backingShare,
                presaleConfig.backingReceiver
            );
        }

        // 🔍 步骤6: 开始关联设置
        // 步骤6: 直接建立关联关系（CoordinatorFactory有权限）
        // 🔍 步骤6.1: 设置代币白名单
        address[] memory presaleArray = new address[](1);
        presaleArray[0] = presale;
        StagedCustomToken(payable(token)).setExcludeFee(presaleArray, true);
        // 移除 try-catch，直接调用，让原始错误信息传递

        // 🔍 步骤6.2: 计算代币总量
        uint256 totalSupplyWithDecimals = tokenConfig.totalSupply * 10**18;
        require(totalSupplyWithDecimals > 0, "STEP6_2_INVALID_TOTAL_SUPPLY");

        // 🔍 步骤6.3: 授权预售合约
        try StagedCustomToken(payable(token)).approve(presale, totalSupplyWithDecimals) {
            // 成功
        } catch {
            revert("STEP6_3_APPROVE_FAILED");
        }

        // 🔍 步骤6.4: 设置代币地址到预售合约
        try PRESALE(payable(presale)).setCoinAddress(token) {
            // 成功
        } catch {
            revert("STEP6_4_SET_COIN_ADDRESS_FAILED");
        }

        // 🔍 步骤6.5: 设置预售合约地址到代币
        try StagedCustomToken(payable(token)).setPresaleContract(presale) {
            // 成功
        } catch {
            revert("STEP6_5_SET_PRESALE_CONTRACT_FAILED");
        }

        // 发射关联事件
        emit TokenPresaleLinked(token, presale);

        // 🔍 步骤7: 转移所有权
        // 🔍 步骤7.1: 转移Token所有权
        try StagedCustomToken(payable(token)).transferOwnership(msg.sender) {
            // 成功
        } catch {
            revert("STEP7_1_TOKEN_OWNERSHIP_TRANSFER_FAILED");
        }

        // 🔍 步骤7.2: 转移Presale所有权
        try PRESALE(payable(presale)).transferOwnership(msg.sender) {
            // 成功
        } catch {
            revert("STEP7_2_PRESALE_OWNERSHIP_TRANSFER_FAILED");
        }

        // 发射所有权转移事件
        emit OwnershipTransferred(token, presale, msg.sender);

        // 步骤5: 更新Coordinator状态映射
        tokenPresales[token] = presale;
        presaleTokens[presale] = token;
        tokenCreators[token] = msg.sender;
        totalPairsCreated++;

        // 步骤5.1: 更新查询支持数据结构
        creatorTokens[msg.sender].push(token);
        allTokens.push(token);

        // 记录详细信息
        tokenPairDetails[token] = TokenPresalePair({
            tokenAddress: token,
            presaleAddress: presale,
            creator: msg.sender,
            createdAt: block.timestamp,
            tokenName: tokenConfig.name,
            tokenSymbol: tokenConfig.symbol,
            totalSupply: tokenConfig.totalSupply
        });

        // 步骤6: 发射事件（保持兼容性）
        emit TokenPresalePairCreated(token, presale, msg.sender, tokenConfig.totalSupply);

        return (token, presale);
    }

    /**
     * @dev 简单模式发币：只创建 Token，不需要预售合约
     * 1. 调用 TokenFactory 创建 Token 合约（代币初始铸造给 CoordinatorFactory）
     * 2. 将铸造的总代币全额划转给创建者 (msg.sender)
     * 3. 将 Token 合约所有权转移给创建者 (msg.sender)
     * 4. 更新状态映射并触发事件，创建者拿回代币和所有权后可直接去 PancakeSwap 添加流动性开盘
     */
    function createSimpleToken(
        TokenConfig memory tokenConfig
    ) external payable nonReentrant returns (address token) {
        // 步骤1: 基础验证
        require(factoryEnabled, "STEP1_FACTORY_DISABLED");
        require(msg.value >= creationFee, "STEP1_INSUFFICIENT_FEE");
        require(bytes(tokenConfig.name).length > 0, "STEP1_EMPTY_TOKEN_NAME");
        require(bytes(tokenConfig.symbol).length > 0, "STEP1_EMPTY_TOKEN_SYMBOL");
        require(tokenConfig.totalSupply > 0, "STEP1_ZERO_TOTAL_SUPPLY");

        // 步骤2: Token工厂验证
        require(address(tokenFactory) != address(0), "STEP2_TOKEN_FACTORY_NULL");

        TokenFactory.TokenConfig memory tokenFactoryConfig = TokenFactory.TokenConfig({
            name: tokenConfig.name,
            symbol: tokenConfig.symbol,
            totalSupply: tokenConfig.totalSupply * 10**18,
            feeBuy: tokenConfig.feeBuy,
            feeSell: tokenConfig.feeSell,
            feeRecipient: tokenConfig.feeRecipient,
            lpBurnEnabled: tokenConfig.lpBurnEnabled,
            lpBurnFrequency: tokenConfig.lpBurnFrequency,
            percentForLPBurn: tokenConfig.percentForLPBurn,
            burnLimit: tokenConfig.burnLimit,
            protectTime: tokenConfig.protectTime,
            protectFee: tokenConfig.protectFee,
            isInsideSell: tokenConfig.isInsideSell,
            swapThreshold: tokenConfig.swapThreshold
        });

        // 步骤3: 通过 TokenFactory 创建 Token
        token = tokenFactory.createToken(tokenFactoryConfig);
        require(token != address(0), "STEP3_TOKEN_CREATION_FAILED");

        // 步骤4: 计算带精度的总供应量，将代币从 CoordinatorFactory 全额划转给创建者 (msg.sender)
        uint256 totalSupplyWithDecimals = tokenConfig.totalSupply * 10**18;
        require(totalSupplyWithDecimals > 0, "STEP4_INVALID_TOTAL_SUPPLY");

        bool transferSuccess = IERC20(token).transfer(msg.sender, totalSupplyWithDecimals);
        require(transferSuccess, "STEP4_TOKEN_TRANSFER_FAILED");

        // 步骤5: 转移 Token 所有权给创建者 (msg.sender)
        try StagedCustomToken(payable(token)).transferOwnership(msg.sender) {
            // 成功
        } catch {
            revert("STEP5_TOKEN_OWNERSHIP_TRANSFER_FAILED");
        }

        // 发射所有权转移事件（预售合约传零地址）
        emit OwnershipTransferred(token, address(0), msg.sender);

        // 步骤6: 更新 Coordinator 状态映射
        tokenCreators[token] = msg.sender;
        totalPairsCreated++;

        // 更新查询支持数据结构
        creatorTokens[msg.sender].push(token);
        allTokens.push(token);

        tokenPairDetails[token] = TokenPresalePair({
            tokenAddress: token,
            presaleAddress: address(0), // 简单模式没有预售合约，传零地址
            creator: msg.sender,
            createdAt: block.timestamp,
            tokenName: tokenConfig.name,
            tokenSymbol: tokenConfig.symbol,
            totalSupply: tokenConfig.totalSupply
        });

        // 发射配对创建事件（保持与现有 DApp 界面和索引兼容，presale 传零地址）
        emit TokenPresalePairCreated(token, address(0), msg.sender, tokenConfig.totalSupply);

        return token;
    }

    /**
     * @dev 简单模式发币（带 8888 靓号）：使用 CREATE2 部署 Token，无需预售合约
     */
    function createSimpleTokenWithSalt(
        TokenConfig memory tokenConfig,
        bytes32 salt
    ) external payable nonReentrant returns (address token) {
        // 步骤1: 基础验证
        require(factoryEnabled, "STEP1_FACTORY_DISABLED");
        require(msg.value >= creationFee, "STEP1_INSUFFICIENT_FEE");
        require(bytes(tokenConfig.name).length > 0, "STEP1_EMPTY_TOKEN_NAME");
        require(bytes(tokenConfig.symbol).length > 0, "STEP1_EMPTY_TOKEN_SYMBOL");
        require(tokenConfig.totalSupply > 0, "STEP1_ZERO_TOTAL_SUPPLY");

        // 步骤2: Token工厂验证
        require(address(tokenFactory) != address(0), "STEP2_TOKEN_FACTORY_NULL");

        TokenFactory.TokenConfig memory tokenFactoryConfig = TokenFactory.TokenConfig({
            name: tokenConfig.name,
            symbol: tokenConfig.symbol,
            totalSupply: tokenConfig.totalSupply * 10**18,
            feeBuy: tokenConfig.feeBuy,
            feeSell: tokenConfig.feeSell,
            feeRecipient: tokenConfig.feeRecipient,
            lpBurnEnabled: tokenConfig.lpBurnEnabled,
            lpBurnFrequency: tokenConfig.lpBurnFrequency,
            percentForLPBurn: tokenConfig.percentForLPBurn,
            burnLimit: tokenConfig.burnLimit,
            protectTime: tokenConfig.protectTime,
            protectFee: tokenConfig.protectFee,
            isInsideSell: tokenConfig.isInsideSell,
            swapThreshold: tokenConfig.swapThreshold
        });

        // 步骤3: 通过 TokenFactory 使用 CREATE2 创建 8888 靓号 Token
        token = tokenFactory.createTokenWithSalt(tokenFactoryConfig, salt);
        require(token != address(0), "STEP3_TOKEN_CREATION_FAILED");

        // 步骤4: 计算带精度的总供应量，将代币从 CoordinatorFactory 全额划转给创建者 (msg.sender)
        uint256 totalSupplyWithDecimals = tokenConfig.totalSupply * 10**18;
        require(totalSupplyWithDecimals > 0, "STEP4_INVALID_TOTAL_SUPPLY");

        bool transferSuccess = IERC20(token).transfer(msg.sender, totalSupplyWithDecimals);
        require(transferSuccess, "STEP4_TOKEN_TRANSFER_FAILED");

        // 步骤5: 转移 Token 所有权给创建者 (msg.sender)
        try StagedCustomToken(payable(token)).transferOwnership(msg.sender) {
            // 成功
        } catch {
            revert("STEP5_TOKEN_OWNERSHIP_TRANSFER_FAILED");
        }

        // 发射所有权转移事件（预售合约传零地址）
        emit OwnershipTransferred(token, address(0), msg.sender);

        // 步骤6: 更新 Coordinator 状态映射
        tokenCreators[token] = msg.sender;
        totalPairsCreated++;

        // 更新查询支持数据结构
        creatorTokens[msg.sender].push(token);
        allTokens.push(token);

        tokenPairDetails[token] = TokenPresalePair({
            tokenAddress: token,
            presaleAddress: address(0), // 简单模式没有预售合约，传零地址
            creator: msg.sender,
            createdAt: block.timestamp,
            tokenName: tokenConfig.name,
            tokenSymbol: tokenConfig.symbol,
            totalSupply: tokenConfig.totalSupply
        });

        // 发射配对创建事件（保持与现有 DApp 界面和索引兼容，presale 传零地址）
        emit TokenPresalePairCreated(token, address(0), msg.sender, tokenConfig.totalSupply);

        return token;
    }

    /**
     * @dev  靓号发币功能：创建代币和预售合约对（使用 CREATE2 部署 8888 靓号 Token）
     */
    function createTokenAndPresaleWithSalt(
        TokenConfig memory tokenConfig,
        PresaleConfig memory presaleConfig,
        bytes32 salt
    ) external payable nonReentrant returns (address token, address presale) {
        // 步骤1: 基础验证
        require(factoryEnabled, "STEP1_FACTORY_DISABLED");
        require(msg.value >= creationFee, "STEP1_INSUFFICIENT_FEE");
        require(bytes(tokenConfig.name).length > 0, "STEP1_EMPTY_TOKEN_NAME");
        require(bytes(tokenConfig.symbol).length > 0, "STEP1_EMPTY_TOKEN_SYMBOL");
        require(tokenConfig.totalSupply > 0, "STEP1_ZERO_TOTAL_SUPPLY");
        require(presaleConfig.presaleEthAmount > 0, "STEP1_ZERO_PRESALE_AMOUNT");

        // 步骤2: Token工厂验证
        require(address(tokenFactory) != address(0), "STEP2_TOKEN_FACTORY_NULL");

        TokenFactory.TokenConfig memory tokenFactoryConfig = TokenFactory.TokenConfig({
            name: tokenConfig.name,
            symbol: tokenConfig.symbol,
            totalSupply: tokenConfig.totalSupply * 10**18,
            feeBuy: tokenConfig.feeBuy,
            feeSell: tokenConfig.feeSell,
            feeRecipient: tokenConfig.feeRecipient,
            lpBurnEnabled: tokenConfig.lpBurnEnabled,
            lpBurnFrequency: tokenConfig.lpBurnFrequency,
            percentForLPBurn: tokenConfig.percentForLPBurn,
            burnLimit: tokenConfig.burnLimit,
            protectTime: tokenConfig.protectTime,
            protectFee: tokenConfig.protectFee,
            isInsideSell: tokenConfig.isInsideSell,
            swapThreshold: tokenConfig.swapThreshold
        });

        // 步骤3: 通过 TokenFactory 使用 CREATE2 创建 8888 靓号 Token
        token = tokenFactory.createTokenWithSalt(tokenFactoryConfig, salt);
        require(token != address(0), "STEP3_TOKEN_CREATION_FAILED");

        // 步骤4: Presale工厂验证
        require(address(presaleFactory) != address(0), "STEP4_PRESALE_FACTORY_NULL");

        PresaleFactory.PresaleConfig memory presaleFactoryConfig = PresaleFactory.PresaleConfig({
            presaleEthAmount: presaleConfig.presaleEthAmount,
            tradeEthAmount: presaleConfig.tradeEthAmount,
            maxTotalNum: presaleConfig.maxTotalNum,
            presaleMaxNum: presaleConfig.presaleMaxNum,
            marketDisAmount: presaleConfig.marketDisAmount,
            userLPShare: presaleConfig.userLPShare,
            devLPShare: presaleConfig.devLPShare,
            devLPReceiver: presaleConfig.devLPReceiver,
            lpDistributionEnabled: presaleConfig.lpDistributionEnabled,
            startTime: presaleConfig.startTime,
            hardcap: presaleConfig.hardcap,
            maxBuyPerWallet: presaleConfig.maxBuyPerWallet,
            vestingDelay: presaleConfig.vestingDelay,
            vestingRate: presaleConfig.vestingRate,
            vestingEnabled: presaleConfig.vestingEnabled,
            backingShare: presaleConfig.backingShare,
            backingReceiver: presaleConfig.backingReceiver
        });

        // 步骤5: 创建Presale
        presale = presaleFactory.createPresale(presaleFactoryConfig);
        require(presale != address(0), "STEP5_PRESALE_CREATION_FAILED");

        if (presaleConfig.startTime > 0 || presaleConfig.hardcap > 0 || presaleConfig.maxBuyPerWallet > 0) {
            emit LGEConfigSet(
                presale,
                token,
                msg.sender,
                presaleConfig.startTime,
                presaleConfig.hardcap,
                presaleConfig.maxBuyPerWallet
            );
        }

        if (presaleConfig.vestingEnabled) {
            emit VestingConfigSet(
                presale,
                token,
                msg.sender,
                presaleConfig.vestingDelay,
                presaleConfig.vestingRate,
                presaleConfig.vestingEnabled
            );
        }

        if (presaleConfig.backingShare > 0) {
            emit BackingConfigSet(
                presale,
                token,
                msg.sender,
                presaleConfig.backingShare,
                presaleConfig.backingReceiver
            );
        }

        // 步骤6: 关联设置
        address[] memory presaleArray = new address[](1);
        presaleArray[0] = presale;
        StagedCustomToken(payable(token)).setExcludeFee(presaleArray, true);

        uint256 totalSupplyWithDecimals = tokenConfig.totalSupply * 10**18;
        require(totalSupplyWithDecimals > 0, "STEP6_2_INVALID_TOTAL_SUPPLY");

        try StagedCustomToken(payable(token)).approve(presale, totalSupplyWithDecimals) {
        } catch {
            revert("STEP6_3_APPROVE_FAILED");
        }

        try PRESALE(payable(presale)).setCoinAddress(token) {
        } catch {
            revert("STEP6_4_SET_COIN_ADDRESS_FAILED");
        }

        try StagedCustomToken(payable(token)).setPresaleContract(presale) {
        } catch {
            revert("STEP6_5_SET_PRESALE_CONTRACT_FAILED");
        }

        emit TokenPresaleLinked(token, presale);

        // 步骤7: 转移所有权
        try StagedCustomToken(payable(token)).transferOwnership(msg.sender) {
        } catch {
            revert("STEP7_1_TOKEN_OWNERSHIP_TRANSFER_FAILED");
        }

        try PRESALE(payable(presale)).transferOwnership(msg.sender) {
        } catch {
            revert("STEP7_2_PRESALE_OWNERSHIP_TRANSFER_FAILED");
        }

        emit OwnershipTransferred(token, presale, msg.sender);

        tokenPresales[token] = presale;
        presaleTokens[presale] = token;
        tokenCreators[token] = msg.sender;
        totalPairsCreated++;

        creatorTokens[msg.sender].push(token);
        allTokens.push(token);

        tokenPairDetails[token] = TokenPresalePair({
            tokenAddress: token,
            presaleAddress: presale,
            creator: msg.sender,
            createdAt: block.timestamp,
            tokenName: tokenConfig.name,
            tokenSymbol: tokenConfig.symbol,
            totalSupply: tokenConfig.totalSupply
        });

        emit TokenPresalePairCreated(token, presale, msg.sender, tokenConfig.totalSupply);

        return (token, presale);
    }

    // ============================================================================
    // 📋 查询和管理函数（保持向后兼容）
    // ============================================================================

    /**
     * @dev 获取Token对应的Presale地址
     */
    function getTokenPresale(address token) external view returns (address) {
        return tokenPresales[token];
    }

    /**
     * @dev 获取Presale对应的Token地址
     */
    function getPresaleToken(address presale) external view returns (address) {
        return presaleTokens[presale];
    }

    /**
     * @dev 获取Token的创建者
     */
    function getTokenCreator(address token) external view returns (address) {
        return tokenCreators[token];
    }

    /**
     * @dev 获取工厂合约地址（用于调试和验证）
     */
    function getFactoryAddresses() external view returns (
        address _tokenFactory,
        address _presaleFactory
    ) {
        return (
            address(tokenFactory),
            address(presaleFactory)
        );
    }

    // ============================================================================
    // 📊 查询功能
    // ============================================================================

    /**
     * @dev 根据创建者地址查询代币预售合约对（分页）
     * @param creator 创建者地址
     * @param offset 偏移量
     * @param limit 限制数量
     * @return pairs 代币预售合约对数组
     * @return total 该创建者的总数量
     */
    function getTokenPresalePairsByCreator(
        address creator,
        uint256 offset,
        uint256 limit
    ) external view returns (TokenPresalePair[] memory pairs, uint256 total) {
        address[] memory creatorTokenList = creatorTokens[creator];
        total = creatorTokenList.length;

        if (offset >= total) {
            return (new TokenPresalePair[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 resultLength = end - offset;
        pairs = new TokenPresalePair[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            address tokenAddr = creatorTokenList[offset + i];
            pairs[i] = tokenPairDetails[tokenAddr];
        }

        return (pairs, total);
    }

    /**
     * @dev 获取所有代币预售合约对（分页）
     * @param offset 偏移量
     * @param limit 限制数量
     * @return pairs 代币预售合约对数组
     * @return total 总数量
     */
    function getAllTokenPresalePairs(
        uint256 offset,
        uint256 limit
    ) external view returns (TokenPresalePair[] memory pairs, uint256 total) {
        total = allTokens.length;

        if (offset >= total) {
            return (new TokenPresalePair[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 resultLength = end - offset;
        pairs = new TokenPresalePair[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            address tokenAddr = allTokens[offset + i];
            pairs[i] = tokenPairDetails[tokenAddr];
        }

        return (pairs, total);
    }

    /**
     * @dev 根据代币地址获取详细信息
     * @param tokenAddress 代币地址
     * @return pair 代币预售合约对信息
     */
    function getTokenPresalePairDetails(address tokenAddress)
        external view returns (TokenPresalePair memory pair) {
        return tokenPairDetails[tokenAddress];
    }

    /**
     * @dev 获取创建者的代币数量
     * @param creator 创建者地址
     * @return count 代币数量
     */
    function getCreatorTokenCount(address creator) external view returns (uint256 count) {
        return creatorTokens[creator].length;
    }

    /**
     * @dev 获取总代币数量
     * @return count 总代币数量
     */
    function getTotalTokenCount() external view returns (uint256 count) {
        return allTokens.length;
    }

    /**
     * @dev 检查代币是否存在
     * @param tokenAddress 代币地址
     * @return exists 是否存在
     */
    function tokenExists(address tokenAddress) external view returns (bool exists) {
        return tokenPairDetails[tokenAddress].tokenAddress != address(0);
    }

    // ============================================================================
    // 🔧 管理员功能
    // ============================================================================

    /**
     * @dev 设置工厂启用状态
     */
    function setFactoryEnabled(bool _enabled) external onlyOwner {
        factoryEnabled = _enabled;
    }

    /**
     * @dev 设置创建费用
     */
    function setCreationFee(uint256 _fee) external onlyOwner {
        creationFee = _fee;
    }

    /**
     * @dev 提取费用
     */
    function withdrawFees() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /**
     * @dev 接收ETH
     */
    receive() external payable {}
}