// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPancakeRouter02} from "src/lib/interfaces/IPancakeRouter02.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {TransferHelper} from "src/TransferHelper.sol";

// ---------------------------------------------------------------------------
// 自定义错误
// ---------------------------------------------------------------------------

error AlreadyInitialized();
error PresaleDisabled();
error InvalidCreator();
error EmptyAllocation();
error InvalidPrice();
error InvalidVestingDelay();
error InvalidVestingRate();
error SlippageTooHigh();
error TokenAlreadySet();
error InvalidStatus();
error PresaleNotOpen();
error ZeroValue();
error PresaleNotStarted();
error AmountTooSmall();
error PresaleSoldOut();
error WalletLimitExceeded();
error HardcapReached();
error InsufficientBNB();
error PoolShareNotSet();
error TokenNotSet();
error MigrationStateMismatch();
error LiquidityAlreadyAdded();
error NotLaunched();
error NoShare();
error NothingToClaim();
error TokensAlreadyClaimed();
error NoTokensToClaim();
error NotAfterLaunch();
error NoBNBToWithdraw();
error SoftCapTooLow();

/// @notice 代币迁移操作接口（FlapTaxTokenV3 最小子集）
interface ITokenMigration {
    function state() external view returns (IFlapTaxTokenV3.PoolState);
    function startMigration() external;
    function finalizeMigration() external;
    function renounceOwnership() external;
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}

/// @title PRESALE — Launchpad 分配/认购/锁仓/加池/迁移编排合约
/// @dev 两种模式：
///     - 纯发币模式（presaleEnabled=false）：全部代币存入本合约，创建者通过 claimAllTokens 一次性领取
///     - 预售模式（presaleEnabled=true）：30% 创建者 / 20% 底池 / 50% 预售，散户 BNB 认购代币份额，
///       launch() 自动完成 startMigration → 加池(LP 死锁 0xdead) → finalizeMigration → renounceOwnership
///     - 失败终态（STATUS_FAILED=4）：endPresale 时未达 softCap 则宣告发行失败，散户经 refund()
///       精确取回缴款、创建者经 reclaimTokens() 回收代币，其余功能全部封锁
contract PRESALE is Ownable, ReentrancyGuard {
    uint256 private constant BPS_DENOMINATOR = 10000;
    uint256 private constant DEFAULT_SLIPPAGE = 500; // 5%
    uint256 public constant STATUS_FAILED = 4; // 发行失败终态：开放 refund()/reclaimTokens()
    address private constant LP_LOCK_ADDRESS = address(0xdead);

    // BSC 测试网路由
    IPancakeRouter02 router;

    address public coinAddress;
    address public lpAddress;

    // === 配置 ===
    bool public presaleEnabled;
    address public creator;

    /// @notice 配置期授权方（协调器）：仅允许在开盘前调用配置类函数
    address public configurator;
    uint256 public creatorShare; // 代币数量（wei）
    uint256 public poolShare; // 代币数量（wei），加池用
    uint256 public presaleShare; // 代币数量（wei），预售用
    uint256 public presaleTokenPrice; // 每 1 枚代币的 BNB 价格（wei，18 位）
    uint256 public maxPresaleTokens; // 预售代币上限
    uint256 public maxBuyPerWallet; // 每钱包认购代币上限
    uint256 public hardcap; // BNB 硬顶（0 = 不限）
    uint256 public minLiquidityAmount; // 加池最低 BNB
    uint256 public startTime; // 认购开始时间（0 = 立即）
    uint256 public slippageProtection; // 滑点保护 bps
    uint256 public softCap; // 认购成功线（BNB wei）：endPresale 达标进待开盘，未达进 FAILED 开放退款

    // === 生命周期 ===
    // 0=创建 1=认购中 2=认购结束 3=已开盘 4=发行失败（未达 softCap 收官，开放退款）
    uint256 public presaleStatus;

    // === 认购 ===
    uint256 public accumulatedBNB; // 认购累积 BNB（全部用于加池）
    uint256 public totalSubscribedTokens;
    mapping(address => uint256) public subscribedTokens;
    mapping(address => uint256) public contributions; // 每钱包实际缴款（BNB wei）：Failed 退款精确口径

    // === 未售出部分（launch 后归创建者提取）===
    uint256 public unsoldWithdrawn; // 已提取的未售出代币量（防重复提取）

    // === vesting ===
    uint256 public vestingDelay;
    uint256 public vestingRate; // 每周期释放百分比
    uint256 public vestingStart; // 开盘时间
    mapping(address => uint256) public claimedTokens;
    uint256 public totalClaimed;

    // === 流动性 ===
    bool public liquidityAdded;
    uint256 public totalLPTokens; // 均为 0（LP 全部死锁黑洞，合约不持有）

    // === 纯发币模式 ===
    bool public tokensClaimed;

    bool private _initialized;

    event PresaleConfigured(
        bool enabled, address indexed creator, uint256 creatorShare, uint256 poolShare, uint256 presaleShare
    );
    event PresaleTermsSet(
        uint256 tokenPrice,
        uint256 maxTokens,
        uint256 maxBuyPerWallet,
        uint256 hardcap,
        uint256 minLiquidity,
        uint256 startTime
    );
    event VestingConfigSet(uint256 delay, uint256 rate, bool enabled);
    event CoinAndPairSet(address indexed token, address indexed pair);
    event ConfiguratorSet(address indexed configurator);
    event PresaleOpened();
    event PresaleEnded();
    event Subscribed(address indexed user, uint256 tokenAmount, uint256 bnbAmount);
    event LaunchFinalized(uint256 bnbAmount, uint256 tokenAmount, uint256 timestamp);
    event VestingClaimed(address indexed user, uint256 amount, uint256 timestamp);
    event AllTokensClaimed(address indexed user, uint256 amount, uint256 timestamp);
    event UnsoldTokensWithdrawn(address indexed to, uint256 amount, uint256 timestamp);
    event RemainingBNBWithdrawn(uint256 amount, address indexed to);
    event LiquidityAdded(uint256 tokenAmount, uint256 bnbAmount, uint256 lpTokens, address indexed lpReceiver);
    event SoftCapSet(uint256 softCap);
    event PresaleFailed(uint256 raisedBNB, uint256 softCap);
    event Refunded(address indexed user, uint256 amount);
    event TokensReclaimed(address indexed owner, uint256 amount);

    function initialize(address _owner, address _router) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        _transferOwnership(_owner);
        router = IPancakeRouter02(_router);
        slippageProtection = DEFAULT_SLIPPAGE;
        vestingDelay = 7 days;
        vestingRate = 10;
        minLiquidityAmount = 0.1 ether;
        softCap = minLiquidityAmount; // 默认与加池下限一致，行为向后兼容
    }

    constructor() {}

    /// @dev 仅配置期（状态 0）可调用：开售后一切条款冻结，杜绝认购进行中改价改规则
    modifier onlyConfigPhase() {
        if (presaleStatus != 0) revert InvalidStatus();
        _;
    }

    modifier onlyOwnerOrConfigurator() {
        if (msg.sender != owner() && msg.sender != configurator) revert InvalidStatus();
        _;
    }

    /// @notice 设置配置期授权方（仅 owner，配置期内）
    function setConfigurator(address _configurator) external onlyOwner onlyConfigPhase {
        configurator = _configurator;
        emit ConfiguratorSet(_configurator);
    }

    // ---------------------------------------------------------------------------
    // 配置（仅 owner，必须在开盘前）
    // ---------------------------------------------------------------------------

    function configureLaunch(
        bool _presaleEnabled,
        address _creator,
        uint256 _creatorShare,
        uint256 _poolShare,
        uint256 _presaleShare
    ) external onlyOwnerOrConfigurator onlyConfigPhase {
        if (tokensClaimed) revert TokensAlreadyClaimed(); // 抽干托管仓后禁止重开预售，封死“领完全量代币再设局募资”骗局
        if (_presaleEnabled) {
            if (_creator == address(0)) revert InvalidCreator();
            if (_creatorShare + _poolShare + _presaleShare == 0) revert EmptyAllocation();
            creator = _creator;
        }
        presaleEnabled = _presaleEnabled;
        creatorShare = _creatorShare;
        poolShare = _poolShare;
        presaleShare = _presaleShare;
        emit PresaleConfigured(_presaleEnabled, _creator, _creatorShare, _poolShare, _presaleShare);
    }

    function setPresaleTerms(
        uint256 _tokenPrice,
        uint256 _maxTokens,
        uint256 _maxBuyPerWallet,
        uint256 _hardcap,
        uint256 _minLiquidity,
        uint256 _startTime
    ) external onlyOwnerOrConfigurator onlyConfigPhase {
        if (presaleEnabled && _tokenPrice == 0) revert InvalidPrice();
        presaleTokenPrice = _tokenPrice;
        maxPresaleTokens = _maxTokens;
        maxBuyPerWallet = _maxBuyPerWallet;
        hardcap = _hardcap;
        minLiquidityAmount = _minLiquidity;
        startTime = _startTime;
        emit PresaleTermsSet(_tokenPrice, _maxTokens, _maxBuyPerWallet, _hardcap, _minLiquidity, _startTime);
    }

    /// @notice 设置 vesting 释放节奏（vesting 恒开启；Delay 7-90天 / Rate 5-20%）
    function setVestingConfig(uint256 _vestingDelay, uint256 _vestingRate)
        external
        onlyOwnerOrConfigurator
        onlyConfigPhase
    {
        if (_vestingDelay < 7 days || _vestingDelay > 90 days) revert InvalidVestingDelay();
        if (_vestingRate < 5 || _vestingRate > 20) revert InvalidVestingRate();
        vestingDelay = _vestingDelay;
        vestingRate = _vestingRate;
        emit VestingConfigSet(_vestingDelay, _vestingRate, true);
    }

    function setSlippageProtection(uint256 _slippage) external onlyOwnerOrConfigurator onlyConfigPhase {
        if (_slippage > 1000) revert SlippageTooHigh();
        slippageProtection = _slippage;
    }

    /// @notice 设置认购成功线；必须 ≥ 加池下限，否则 launch 的 InsufficientBNB 将成为永远不可满足的死门槛
    function setSoftCap(uint256 _softCap) external onlyOwnerOrConfigurator onlyConfigPhase {
        if (_softCap < minLiquidityAmount) revert SoftCapTooLow();
        softCap = _softCap;
        emit SoftCapSet(_softCap);
    }

    function setCoinAndPair(address _coin, address _pair) external onlyOwner {
        if (coinAddress != address(0)) revert TokenAlreadySet();
        coinAddress = _coin;
        lpAddress = _pair;
        emit CoinAndPairSet(_coin, _pair);
    }

    // ---------------------------------------------------------------------------
    // 认购
    // ---------------------------------------------------------------------------

    function openPresale() external onlyOwner {
        if (!presaleEnabled) revert PresaleDisabled();
        if (presaleStatus != 0) revert InvalidStatus();
        // 终检（条款冻结前最后一道闸）：任何配置路径下 softCap < minLiquidityAmount 都不可开盘，
        // 否则 status 2 死角（launch 的 InsufficientBNB 永不可满足，而 refund 仅 FAILED 态开放）
        if (softCap < minLiquidityAmount) revert SoftCapTooLow();
        presaleStatus = 1;
        emit PresaleOpened();
    }

    /// @notice 结束认购并判定结果：达标 → 待开盘(2)；未达 softCap → 发行失败(4)，开放 refund()
    /// @dev 判定只用内部累计 accumulatedBNB，不用合约余额（receive 直接打款的款项不计入，抗操纵）
    function endPresale() external onlyOwner {
        if (presaleStatus != 1) revert InvalidStatus();
        if (accumulatedBNB >= softCap) {
            presaleStatus = 2;
            emit PresaleEnded();
        } else {
            presaleStatus = STATUS_FAILED;
            emit PresaleFailed(accumulatedBNB, softCap);
        }
    }

    /// @notice 散户认购：以 BNB 按 presaleTokenPrice 认购代币份额
    function subscribe() external payable nonReentrant {
        if (presaleStatus != 1) revert PresaleNotOpen();
        if (msg.value == 0) revert ZeroValue();
        if (presaleTokenPrice == 0) revert InvalidPrice();
        if (block.timestamp < startTime) revert PresaleNotStarted();

        uint256 tokenAmount = (msg.value * 1e18) / presaleTokenPrice;
        if (tokenAmount == 0) revert AmountTooSmall();
        if (totalSubscribedTokens + tokenAmount > maxPresaleTokens) revert PresaleSoldOut();
        if (subscribedTokens[msg.sender] + tokenAmount > maxBuyPerWallet) revert WalletLimitExceeded();
        if (hardcap > 0 && accumulatedBNB + msg.value > hardcap) revert HardcapReached();

        accumulatedBNB += msg.value;
        totalSubscribedTokens += tokenAmount;
        subscribedTokens[msg.sender] += tokenAmount;
        contributions[msg.sender] += msg.value; // 精确缴款账本（Failed 退款口径，无舍入）

        emit Subscribed(msg.sender, tokenAmount, msg.value);
    }

    // ---------------------------------------------------------------------------
    // 开盘（自动迁移三步 + LP 死锁 + 放弃所有权）
    // ---------------------------------------------------------------------------

    /// @dev 前提：合约是 token 的 owner（由 Coordinator 在创建时移交）
    // slither-disable-next-line reentrancy-eth nonReentrant 守卫 + 状态写在最后，外部调用为可信路由器
    function launch() external onlyOwner nonReentrant {
        if (!presaleEnabled) revert PresaleDisabled();
        if (presaleStatus != 2) revert InvalidStatus();
        if (accumulatedBNB < minLiquidityAmount) revert InsufficientBNB();
        if (coinAddress == address(0)) revert TokenNotSet();
        if (poolShare == 0) revert PoolShareNotSet();

        ITokenMigration token = ITokenMigration(coinAddress);

        // 步骤1: BondingCurve → Migrating（允许池转账）
        if (token.state() == IFlapTaxTokenV3.PoolState.BondingCurve) {
            token.startMigration();
        }
        if (token.state() != IFlapTaxTokenV3.PoolState.Migrating) revert MigrationStateMismatch();

        // 步骤2: Migrating 状态加池（无税），LP 全部死锁 0xdead
        _addLiquidity(poolShare, accumulatedBNB);

        // 步骤3: Migrating → TaxEnforcedAntiFarmer（税启动）
        token.finalizeMigration();
        if (token.state() != IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer) revert MigrationStateMismatch();

        // 步骤4: 放弃 token 所有权（权限已无用）
        token.renounceOwnership();

        presaleStatus = 3;
        vestingStart = block.timestamp;

        emit LaunchFinalized(accumulatedBNB, poolShare, block.timestamp);
    }

    // 仅被 launch()（nonReentrant）调用，无独立入口，无重入面
    // slither-disable-next-line reentrancy-eth
    function _addLiquidity(uint256 tokenAmount, uint256 bnbAmount) internal {
        if (liquidityAdded) revert LiquidityAlreadyAdded();

        uint256 tokenMin = (tokenAmount * (BPS_DENOMINATOR - slippageProtection)) / BPS_DENOMINATOR;
        uint256 bnbMin = (bnbAmount * (BPS_DENOMINATOR - slippageProtection)) / BPS_DENOMINATOR;

        TransferHelper.safeApprove(coinAddress, address(router), tokenAmount);

        (uint256 amountToken, uint256 amountETH, uint256 liquidity) = router.addLiquidityETH{value: bnbAmount}(
            coinAddress,
            tokenAmount,
            tokenMin,
            bnbMin,
            LP_LOCK_ADDRESS, // LP 永久死锁，防撤池
            block.timestamp + 300
        );

        liquidityAdded = true;
        totalLPTokens = liquidity;
        accumulatedBNB = 0;

        emit LiquidityAdded(amountToken, amountETH, liquidity, LP_LOCK_ADDRESS);
    }

    // ---------------------------------------------------------------------------
    // 领取
    // ---------------------------------------------------------------------------

    /// @notice 预售模式领取：创建者 30% + 散户 50% 份额共用本函数（各自份额不同地址）
    /// @dev vesting 开启时按周期释放；关闭时一次性全部
    function claim() external nonReentrant {
        if (!presaleEnabled || presaleStatus != 3) revert NotLaunched();

        uint256 share = subscribedTokens[msg.sender];
        if (msg.sender == creator) share += creatorShare;
        if (share == 0) revert NoShare();

        uint256 vested = _vestedOf(msg.sender, share);
        uint256 claimable = vested - claimedTokens[msg.sender];
        if (claimable == 0) revert NothingToClaim();

        claimedTokens[msg.sender] += claimable;
        totalClaimed += claimable;

        TransferHelper.safeTransfer(coinAddress, msg.sender, claimable);
        emit VestingClaimed(msg.sender, claimable, block.timestamp);
    }

    /// @notice 纯发币模式领取：全部代币一次性给创建者
    function claimAllTokens() external onlyOwner nonReentrant {
        if (presaleEnabled) revert PresaleDisabled();
        if (tokensClaimed) revert TokensAlreadyClaimed();

        uint256 balance = IERC20(coinAddress).balanceOf(address(this));
        if (balance == 0) revert NoTokensToClaim();

        tokensClaimed = true;
        TransferHelper.safeTransfer(coinAddress, msg.sender, balance);
        emit AllTokensClaimed(msg.sender, balance, block.timestamp);
    }

    /// @notice 开盘后创建者按 vesting 曲线分批提取未售出的预售份额（presaleShare - 已认购量）
    /// @dev 与创建者 30% 份额共用 vestingDelay/vestingRate 释放节奏（周期数 = (now - vestingStart)/delay）；
    ///      unsoldWithdrawn 累计防超提；与散户/创建者 claim 份额互不相交（总体守恒：20%池+50%预售+30%创建者）
    function withdrawUnsoldTokens() external onlyOwner nonReentrant {
        if (presaleStatus != 3) revert NotAfterLaunch();

        uint256 unsold = presaleShare - totalSubscribedTokens; // launch 后为常值
        if (unsold == 0) revert NothingToClaim();

        // 按 vesting 曲线分批释放（与创建者 30% 份额同一节奏）
        uint256 periods = (block.timestamp - vestingStart) / vestingDelay;
        uint256 vested = (unsold * vestingRate * periods) / 100;
        if (vested > unsold) vested = unsold;

        uint256 amount = vested - unsoldWithdrawn;
        if (amount == 0) revert NothingToClaim();

        uint256 balance = IERC20(coinAddress).balanceOf(address(this));
        if (balance < amount) revert NoTokensToClaim();

        unsoldWithdrawn += amount;
        TransferHelper.safeTransfer(coinAddress, msg.sender, amount);
        emit UnsoldTokensWithdrawn(msg.sender, amount, block.timestamp);
    }

    /// @notice 开盘后合约内残留 BNB 提取（路由器找零等）
    /// @dev 用低层 call 转账（TransferHelper），owner 为合约钱包（如 Safe 多签）时不会被 2300 gas 卡死
    function withdrawRemainingBNB() external onlyOwner nonReentrant {
        if (presaleStatus != 3) revert NotAfterLaunch();
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoBNBToWithdraw();
        TransferHelper.safeTransferETH(owner(), balance);
        emit RemainingBNBWithdrawn(balance, owner());
    }

    // ---------------------------------------------------------------------------
    // 发行失败结算（endPresale 未达 softCap 进入 STATUS_FAILED 后）
    // Failed 态下 subscribe/claim/launch/withdrawUnsoldTokens/withdrawRemainingBNB
    // 均被各自的状态检查天然封锁，唯一出口是退款与代币回收。
    // ---------------------------------------------------------------------------

    /// @notice 领回本人全部认购款；按 subscribe 时记录的缴款额精确退款（无任何截留）
    /// @dev CEI：先清账再转账；权限开放（任何人只能退自己名下的钱）
    function refund() external nonReentrant {
        if (presaleStatus != STATUS_FAILED) revert InvalidStatus();

        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NothingToClaim();
        contributions[msg.sender] = 0;

        TransferHelper.safeTransferETH(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }

    /// @notice 失败结算后创建者收回托管仓内剩余代币（散户从未取得代币，全量退回即守恒）
    function reclaimTokens() external onlyOwner nonReentrant {
        if (presaleStatus != STATUS_FAILED) revert InvalidStatus();
        if (coinAddress == address(0)) revert TokenNotSet();

        uint256 balance = IERC20(coinAddress).balanceOf(address(this));
        if (balance == 0) revert NoTokensToClaim();

        TransferHelper.safeTransfer(coinAddress, msg.sender, balance);
        emit TokensReclaimed(msg.sender, balance);
    }

    // 已知残留边界：经 receive() 直接捐入的非认购 BNB 属捐赠尘埃，无退出通道
    // （与历史行为一致）；不提供 owner 打扫入口以防误伤未领取退款的用户。

    // ---------------------------------------------------------------------------
    // 工具 & 视图
    // ---------------------------------------------------------------------------

    function _vestedOf(address user, uint256 share) internal view returns (uint256) {
        uint256 periods = (block.timestamp - vestingStart) / vestingDelay;
        uint256 vested = (share * vestingRate * periods) / 100;
        return vested > share ? share : vested;
    }

    /// @notice 用户当前可领取的 vesting 数量
    function getVestedAmount(address user) public view returns (uint256) {
        if (!presaleEnabled || presaleStatus != 3) return 0;

        uint256 share = subscribedTokens[user];
        if (user == creator) share += creatorShare;
        if (share == 0) return 0;

        uint256 vested = _vestedOf(user, share);
        uint256 claimed = claimedTokens[user];
        return vested > claimed ? vested - claimed : 0;
    }

    function getUserVestingStatus(address user)
        external
        view
        returns (uint256 share, uint256 claimable, uint256 claimed, uint256 nextVestingTime)
    {
        share = subscribedTokens[user];
        if (user == creator) share += creatorShare;
        claimable = getVestedAmount(user);
        claimed = claimedTokens[user];
        if (vestingStart > 0) {
            nextVestingTime = vestingStart + vestingDelay;
        }
    }

    function getLaunchStatus()
        external
        view
        returns (
            bool enabled,
            uint256 status,
            uint256 bnbAccumulated,
            uint256 tokensSubscribed,
            bool lpAdded,
            bool tokensClaimed_
        )
    {
        return (presaleEnabled, presaleStatus, accumulatedBNB, totalSubscribedTokens, liquidityAdded, tokensClaimed);
    }

    function getContractBalances() external view returns (uint256 tokenBalance, uint256 bnbBalance) {
        tokenBalance = coinAddress != address(0) ? IERC20(coinAddress).balanceOf(address(this)) : 0;
        bnbBalance = address(this).balance;
    }

    receive() external payable {}
}
