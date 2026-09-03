// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IPancakeRouter02} from "src/lib/interfaces/IPancakeRouter02.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {PresaleFactory, PresaleConfig} from "src/PresaleFactory.sol";
import {PRESALE, ITokenMigration, ZeroMinLiquidity} from "src/Presale.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {ITaxProcessor, TaxProcessorInitParams} from "src/lib/interfaces/ITaxProcessor.sol";
import {TransferHelper} from "src/TransferHelper.sol";

// ---------------------------------------------------------------------------
// 自定义错误
// ---------------------------------------------------------------------------

error FactoryDisabled();
error InsufficientCreationFee();
error EmptyTokenName();
error EmptyTokenSymbol();
error InvalidPrice();
error TokenNotRegistered();
error NotTokenCreator();
error TokenCreationFailed();
error NoSupply();
error TokenTransferFailed();
error NoFeesToWithdraw();
error WithdrawFailed();
error InvalidMaxBuyPerWallet();
error ZeroCreationFee();
error AlreadyConfigured();
error InvalidSalt();
error InsufficientReservationFee();
error AddressAlreadyReserved();
error AddressAlreadyDeployed();
error NotReserver();
error CreatorBuyTokensWithoutFunding();
error InvalidAllocation();

// ============================================================================
// CoordinatorFactory - 一站式发币编排（代币 + Pair + TaxProcessor + 托管仓）
// ============================================================================
contract CoordinatorFactory is AccessControl, ReentrancyGuard {
    TokenFactory public tokenFactory;
    PresaleFactory public presaleFactory;
    address public routerAddress;

    bool public factoryEnabled = true;
    uint256 public creationFee = 0.005 ether; // 0.005 BNB = 5e15 wei
    uint256 public reservationFee = 0.01 ether; // 锁定 CA（预留确定性地址）服务费，独立于创建费、不抵扣
    uint256 public totalPairsCreated = 0;

    /// @notice 代币分配比例（bps，和恒为 10000）：默认 30% 创建者 / 20% 底池 / 50% 预售
    /// @dev 仅影响 setupPresale 时刻之后的新币（份额在 configureLaunch 时写入托管仓实例，
    ///      已创建代币的份额随之冻结，不受后续调整影响）
    uint256 public creatorBps = 3000;
    uint256 public poolBps = 2000;
    uint256 public presaleBps = 5000;

    /// @notice 预测地址 → 预留者（CREATE2 预言地址的占位登记，永久有效，发币后保留作凭证）
    mapping(address => address) public tokenAddressReserver;

    mapping(address => address) public tokenPresales;
    mapping(address => address) public presaleTokens;
    mapping(address => address) public tokenCreators;
    /// @notice 代币 → 预售条款是否已配置：每仓仅允许一次 setupPresale（开售后底层条款冻结）
    mapping(address => bool) public tokenConfigured;
    mapping(address => address[]) public creatorTokens;
    address[] public allTokens;

    struct TokenPresalePair {
        address tokenAddress;
        address presaleAddress;
        address creator;
        uint256 createdAt;
        string tokenName;
        string tokenSymbol;
        uint256 totalSupply;
    }

    mapping(address => TokenPresalePair) public tokenPairDetails;

    event TokenPresalePairCreated(
        address indexed token, address indexed presale, address indexed creator, uint256 totalSupply
    );
    event OwnershipTransferred(address indexed token, address indexed presale, address indexed newOwner);
    event PresaleSetup(
        address indexed token, address indexed presale, uint256 creatorShare, uint256 poolShare, uint256 presaleShare
    );
    event FactoryEnabledSet(bool enabled);
    event CreationFeeSet(uint256 fee);
    event ReservationFeeSet(uint256 fee);
    event AllocationUpdated(uint256 creatorBps, uint256 poolBps, uint256 presaleBps);
    event FeesWithdrawn(uint256 amount, address indexed to);
    event TokenAddressReserved(address indexed token, address indexed reserver, uint256 fee);
    event ExcessRefunded(address indexed to, uint256 amount);

    constructor(address _tokenFactory, address _presaleFactory, address _router) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        tokenFactory = TokenFactory(_tokenFactory);
        presaleFactory = PresaleFactory(_presaleFactory);
        routerAddress = _router;
    }

    modifier onlyAdmin() {
        _checkRole(DEFAULT_ADMIN_ROLE);
        _;
    }

    // ---------------------------------------------------------------------------
    // 统一发币入口
    // ---------------------------------------------------------------------------

    /// @dev 创建代币（FlapTaxTokenV3 克隆）+ Pair + TaxProcessor + 托管仓（PRESALE 克隆）。
    ///      代币全量存入托管仓；token 所有权交托管仓（迁移编排前提），托管仓所有权归创建者；
    ///      预售为可选步骤（见 setupPresale）。
    ///      - 不开预售：创建者 claimAllTokens() 一次性领取全部代币，同笔完成迁移（领取即上线）
    ///      - 开预售： 调用 setupPresale() 按当前配置比例分配（默认 30% 创建者 / 20% 底池 / 50% 预售）
    ///      - salt == 0：默认随机地址；salt != 0：CREATE2 确定性地址，须为本人预留的预言地址
    function createToken(TokenConfig memory tokenConfig, bytes32 salt)
        external
        payable
        nonReentrant
        returns (address token, address presale)
    {
        if (!factoryEnabled) revert FactoryDisabled();
        if (msg.value < creationFee) revert InsufficientCreationFee();
        if (bytes(tokenConfig.name).length == 0) revert EmptyTokenName();
        if (bytes(tokenConfig.symbol).length == 0) revert EmptyTokenSymbol();

        // 步骤1: TokenFactory 部署克隆 + Pair + TaxProcessor
        //       salt != 0 时先校验预留权属：预测地址若已被他人锁定则拒绝兑现（本人/未预留放行）
        if (salt != bytes32(0)) {
            address reserver = tokenAddressReserver[tokenFactory.predictTokenAddress(salt)];
            if (reserver != address(0) && reserver != msg.sender) revert NotReserver();
        }
        TokenFactory.TokenBundle memory bundle = tokenFactory.createToken(tokenConfig, salt);
        token = bundle.token;
        if (token == address(0)) revert TokenCreationFailed();

        // 步骤2: 部署 TaxProcessor（部署者=本合约，保证 initialize 权限）
        address taxProcessor = address(new TaxProcessor());

        // 步骤3: 初始化 V3 代币（msg.sender=本合约 → 全量代币铸给本合约）
        IFlapTaxTokenV3(token).initialize(_buildInitParams(tokenConfig, bundle, taxProcessor));

        // 步骤4: 初始化 TaxProcessor（单通道：税 swap 成 BNB 即时转 feeRecipient，bps 全 0）
        ITaxProcessor(taxProcessor)
            .initialize(
                TaxProcessorInitParams({
                quoteToken: _wbnb(),
                router: routerAddress,
                feeReceiver: tokenConfig.feeRecipient,
                marketAddress: address(0),
                dividendAddress: address(0),
                taxToken: token,
                feeRate: 0,
                marketBps: 0,
                deflationBps: 0,
                lpBps: 0,
                dividendBps: 0,
                dividendToken: address(0),
                commissionReceiver: address(0),
                commissionBps: 0,
                converter: address(0),
                liqExpectedOutputAmount: tokenConfig.liqExpectedOutputAmount
            })
            );

        // 步骤5: 创建托管仓（PRESALE 克隆，未配置预售）
        presale = presaleFactory.createPresale(routerAddress);
        PRESALE(payable(presale)).setCoinAndPair(token, bundle.pair);

        // 步骤5: 全量代币转入托管仓
        uint256 supply = IERC20(token).balanceOf(address(this));
        if (supply == 0) revert NoSupply();
        bool transferOk = IERC20(token).transfer(presale, supply);
        if (!transferOk) revert TokenTransferFailed();

        // 步骤6: 授权协调器为配置方（供 setupPresale 配置）；token 所有权交托管仓
        //       （claimAllTokens/reclaimTokens/launch 的迁移编排前提），托管仓所有权交付创建者
        PRESALE(payable(presale)).setConfigurator(address(this));
        ITokenMigration(token).transferOwnership(presale);
        PRESALE(payable(presale)).transferOwnership(msg.sender);
        emit OwnershipTransferred(token, presale, msg.sender);

        // 步骤7: 状态注册
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
            totalSupply: supply
        });

        emit TokenPresalePairCreated(token, presale, msg.sender, supply);

        // 步骤8: 退还多付的创建费（退款失败整笔回滚，绝不吞用户资金）
        if (msg.value > creationFee) {
            uint256 refund = msg.value - creationFee;
            TransferHelper.safeTransferETH(msg.sender, refund);
            emit ExcessRefunded(msg.sender, refund);
        }

        return (token, presale);
    }

    /// @dev 为已创建代币开启预售：分配比例由管理员 setAllocation 配置（默认 30% 创建者 / 20% 底池 / 50% 预售），
    ///      在本函数执行时刻读取并写入托管仓实例（此后冻结）；仅价格/上限/vesting 等由创建者配置；
    ///      token 所有权在 createToken 时已交托管仓
    ///      （launch() 直接编排 startMigration → 加池 → 创建者购买 → finalizeMigration → renounceOwnership）
    /// @dev msg.value 为创建者购买注资（可选）：0 = 不购买；> 0 且 creatorBuyTokens = 0 为 quote
    ///      模式（花掉注资随行就市买入）；> 0 且 creatorBuyTokens > 0 为 token 模式（精确数量，超额退回）。
    ///      此前本函数 non-payable，误发 value 直接 revert；现成为显式注资，误注可经 withdrawCreatorBuy 撤回。
    function setupPresale(address token, PresaleConfig memory presaleConfig) external payable nonReentrant {
        address presale = tokenPresales[token];
        if (presale == address(0)) revert TokenNotRegistered();
        if (tokenCreators[token] != msg.sender) revert NotTokenCreator();
        if (tokenConfigured[token]) revert AlreadyConfigured(); // 条款一次性配置，与底层状态 0 冻结一致
        if (presaleConfig.presaleTokenPrice == 0) revert InvalidPrice();
        // 加池下限前置校验（与 PRESALE.setPresaleTerms 同源规则）：双 0 组合的 status 2 死角
        // 在编排层即拦截，错误归属更清晰（发币表单事故在提交时报错，而非开盘阶段才暴露）
        if (presaleConfig.minLiquidityAmount == 0) revert ZeroMinLiquidity();
        // token 模式漏传资金 = 前端事故：显式报错，杜绝"以为买了、实际静默没买"
        if (presaleConfig.creatorBuyTokens > 0 && msg.value == 0) revert CreatorBuyTokensWithoutFunding();

        tokenConfigured[token] = true;

        // 份额按管理员配置的比例计算（默认 30/20/50；经 setAllocation 可调，仅影响此刻之后的新币）
        uint256 supply = IERC20(token).balanceOf(presale);
        if (supply == 0) revert NoSupply();
        uint256 creatorShare = (supply * creatorBps) / 10_000;
        uint256 poolShare = (supply * poolBps) / 10_000;
        // 余数兜底：presaleShare = supply - 其余两项，三份额之和恒等于 supply（杜绝死锁残留）。
        // 当前 maxSupply = 1e27 可被 10^4 整除，故与 (supply * presaleBps) / 10_000 恒等；
        // 若未来调整 maxSupply 为非整除值，此写法自动把 wei 级余数归入预售份额而非锁死。
        uint256 presaleShare = supply - creatorShare - poolShare;

        PRESALE p = PRESALE(payable(presale));
        p.configureLaunch(true, msg.sender, creatorShare, poolShare, presaleShare);
        p.setPresaleTerms(
            presaleConfig.presaleTokenPrice,
            presaleShare, // 认购上限 = 预售份额（50%），不可由用户配置
            presaleConfig.maxBuyPerWallet,
            presaleConfig.hardcap,
            presaleConfig.minLiquidityAmount,
            presaleConfig.startTime
        );
        // vesting 恒开启（产品规则），仅节奏可配
        p.setVestingConfig(presaleConfig.vestingDelay, presaleConfig.vestingRate);
        // 认购成功线（≥ minLiquidityAmount 由 PRESALE 校验）：endPresale 时未达则判发行失败开放退款
        p.setSoftCap(presaleConfig.softCap);
        if (presaleConfig.slippage > 0) {
            p.setSlippageProtection(presaleConfig.slippage);
        }
        // 每钱包认购上限必须为正：0 会导致 subscribe() 恒 revert，整单报废
        if (presaleConfig.maxBuyPerWallet == 0) revert InvalidMaxBuyPerWallet();

        // 创建者购买注资（置于全部 setter 之后，保证 poolShare 已设置供上限校验）
        if (msg.value > 0) {
            p.fundCreatorBuy{value: msg.value}(presaleConfig.creatorBuyTokens);
        }

        emit PresaleSetup(token, presale, creatorShare, poolShare, presaleShare);
    }

    function _buildInitParams(
        TokenConfig memory tokenConfig,
        TokenFactory.TokenBundle memory bundle,
        address taxProcessor
    ) internal view returns (IFlapTaxTokenV3.InitParams memory) {
        address[] memory pools = new address[](1);
        pools[0] = bundle.pair;

        return IFlapTaxTokenV3.InitParams({
            name: tokenConfig.name,
            symbol: tokenConfig.symbol,
            meta: tokenConfig.meta,
            buyTax: tokenConfig.buyTax,
            sellTax: tokenConfig.sellTax,
            taxProcessor: taxProcessor,
            dividendContract: address(0), // 单通道模型：无 Dividend 实例
            quoteToken: _wbnb(),
            liqExpectedOutputAmount: tokenConfig.liqExpectedOutputAmount,
            taxDuration: tokenConfig.taxDuration,
            pools: pools,
            v2Router: routerAddress,
            antiFarmerDuration: tokenConfig.antiFarmerDuration
        });
    }

    function _wbnb() internal view returns (address) {
        return IPancakeRouter02(routerAddress).WETH();
    }

    // ---------------------------------------------------------------------------
    // 锁定 CA：发币前付费预留确定性代币地址（前端链下搜盐后调用）
    // ---------------------------------------------------------------------------

    /// @dev 校验链：工厂可用 → 盐非零 → 费足 → 预言地址尚无代码（未部署）→ 未被他人预留；
    ///      先登记后退款（CEI + nonReentrant）。预留不过期、不退款；发币经 createToken(config, salt)
    ///      由 NotReserver 校验兑现权属。盐搜索属前端职责，合约内不存在任何枚举逻辑。
    ///      工厂禁用 = 停止一切付费服务，预留同步不可用（同 createToken 门槛）。
    function reserveTokenAddress(bytes32 salt) external payable nonReentrant {
        if (!factoryEnabled) revert FactoryDisabled();
        if (salt == bytes32(0)) revert InvalidSalt();
        if (msg.value < reservationFee) revert InsufficientReservationFee();

        address predicted = tokenFactory.predictTokenAddress(salt);
        if (predicted.code.length != 0) revert AddressAlreadyDeployed();
        if (tokenAddressReserver[predicted] != address(0)) revert AddressAlreadyReserved();

        tokenAddressReserver[predicted] = msg.sender;
        emit TokenAddressReserved(predicted, msg.sender, reservationFee);

        if (msg.value > reservationFee) {
            TransferHelper.safeTransferETH(msg.sender, msg.value - reservationFee);
        }
    }

    // ---------------------------------------------------------------------------
    // 管理
    // ---------------------------------------------------------------------------

    function setFactoryEnabled(bool _enabled) external onlyAdmin {
        factoryEnabled = _enabled;
        emit FactoryEnabledSet(_enabled);
    }

    function setCreationFee(uint256 _fee) external onlyAdmin {
        if (_fee == 0) revert ZeroCreationFee();
        creationFee = _fee;
        emit CreationFeeSet(_fee);
    }

    /// @dev 与创建费同策略：平台费类参数不允许归零（保持防垃圾占位底线）
    function setReservationFee(uint256 _fee) external onlyAdmin {
        if (_fee == 0) revert ZeroCreationFee();
        reservationFee = _fee;
        emit ReservationFeeSet(_fee);
    }

    /// @notice 管理员调整代币分配比例（bps）
    /// @dev 三项均须 > 0 且和 == 10000：任一为 0 会产生畸形托管（零底池/零预售/零创建者份额），
    ///      和 < 10000 会令差额代币永久锁死在托管仓（无提取通道）。
    ///      即时生效，仅影响之后 setupPresale 的新币；已配置代币的份额在实例内冻结不受影响。
    function setAllocation(uint256 _creatorBps, uint256 _poolBps, uint256 _presaleBps) external onlyAdmin {
        if (_creatorBps == 0 || _poolBps == 0 || _presaleBps == 0) revert InvalidAllocation();
        if (_creatorBps + _poolBps + _presaleBps != 10_000) revert InvalidAllocation();
        creatorBps = _creatorBps;
        poolBps = _poolBps;
        presaleBps = _presaleBps;
        emit AllocationUpdated(_creatorBps, _poolBps, _presaleBps);
    }

    // slither-disable-next-line arbitrary-send-eth 仅 admin 可提，收款方 = 调用者本人，非任意目的地
    function withdrawFees() external onlyAdmin {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFeesToWithdraw();
        (bool success,) = msg.sender.call{value: balance}(new bytes(0));
        if (!success) revert WithdrawFailed();
        emit FeesWithdrawn(balance, msg.sender);
    }

    // ---------------------------------------------------------------------------
    // 查询
    // ---------------------------------------------------------------------------

    function getTokenPresale(address token) external view returns (address) {
        return tokenPresales[token];
    }

    function getPresaleToken(address presale) external view returns (address) {
        return presaleTokens[presale];
    }

    function getTokenCreator(address token) external view returns (address) {
        return tokenCreators[token];
    }

    function getFactoryAddresses() external view returns (address _tokenFactory, address _presaleFactory) {
        return (address(tokenFactory), address(presaleFactory));
    }

    function getTokenPresalePairsByCreator(address creator, uint256 offset, uint256 limit)
        external
        view
        returns (TokenPresalePair[] memory)
    {
        address[] storage tokens = creatorTokens[creator];
        return _slicePairs(tokens, offset, limit);
    }

    function getAllTokenPresalePairs(uint256 offset, uint256 limit) external view returns (TokenPresalePair[] memory) {
        return _slicePairs(allTokens, offset, limit);
    }

    function _slicePairs(address[] storage tokens, uint256 offset, uint256 limit)
        internal
        view
        returns (TokenPresalePair[] memory pairs)
    {
        uint256 end = offset + limit;
        if (end > tokens.length) end = tokens.length;
        if (offset >= tokens.length) return new TokenPresalePair[](0);
        pairs = new TokenPresalePair[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            pairs[i - offset] = tokenPairDetails[tokens[i]];
        }
    }

    function getTokenPresalePairDetails(address tokenAddress) external view returns (TokenPresalePair memory pair) {
        return tokenPairDetails[tokenAddress];
    }

    function getCreatorTokenCount(address creator) external view returns (uint256 count) {
        return creatorTokens[creator].length;
    }

    function getTotalTokenCount() external view returns (uint256 count) {
        return allTokens.length;
    }

    function tokenExists(address tokenAddress) external view returns (bool exists) {
        return tokenCreators[tokenAddress] != address(0);
    }
}
