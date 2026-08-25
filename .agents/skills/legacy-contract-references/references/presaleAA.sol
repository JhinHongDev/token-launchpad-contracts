// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "./OpenZeppelinDependencies.sol";
import "./Interfaces.sol";
import "./Token.sol";

library TransferHelper {
    function safeApprove(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('approve(address,uint256)')));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x095ea7b3, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper: APPROVE_FAILED"
        );
    }

    function safeTransfer(address token, address to, uint value) internal {
        // bytes4(keccak256(bytes('transfer(address,uint256)')));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper: TRANSFER_FAILED"
        );
    }

    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint value
    ) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "TransferHelper: TRANSFER_FROM_FAILED"
        );
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }
}

contract PRESALE is Ownable, ReentrancyGuard {
    using Address for address;
    //bsc测试网
    IPancakeRouter02 router =
        IPancakeRouter02(0xD99D1c33F9fC3444f8101754aBC46c52416550D1);

    // BSC测试网PancakeSwap路由器
    address public coinAddress;
    address public lpAddress;
    address public USDT = 0x337610d27c682E347C9cD60BD4b3b107C9d34dDd;

    // 获取usdt价格地址
    address public constant PANCAKE_FACTORY =
        0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address public constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    // === 流动性管理相关状态变量 ===
    address public factoryAddress; // 工厂合约地址
    bool public liquidityAdded = false; // 防重复添加流动性标志
    uint256 public slippageProtection = 500; // 滑点保护 5% = 500/10000
    uint256 public liquidityTokenAmount; // 用于流动性的代币数量
    uint256 public liquidityBNBAmount; // 用于流动性的BNB数量
    address public lpTokenReceiver; // LP代币接收地址
    uint256 public totalLPTokens; // 总LP代币数量

    mapping(address => bool) public managerList;
    mapping(address => preSaleStruct) public preSaleAddress;
    mapping(address => uint256) public lockAmount;
    mapping(uint256 => address) public addressIndex;
    mapping(address => uint256) public tradeCount;
    mapping(address => bool) public canTrade;

    uint256 private preSaleEthAmount;
    uint256 private tadeEthAmount;
    uint256 private coinAmount;
    uint256 private preSaleMaxNum;
    uint256 private maxTotalNum;
    uint256 private totalNum = 0;

    uint256 private allTradeBNB;
    uint256 private allTradeAmount;

    // === BNB累积机制相关状态变量 ===
    uint256 public accumulatedBNB = 0; // 累积的BNB总量
    uint256 public totalPresaleBNB = 0; // 预售阶段累积的BNB
    bool public bnbAccumulationEnabled = true; // BNB累积开关

    // === BNB流动性相关状态变量 ===
    uint256 public processedBNB = 0; // 已处理的BNB数量
    uint256 public liquiditySlippage = 300; // 流动性滑点保护 3% = 300/10000
    bool public liquidityEnabled = true; // 流动性功能开关
    // BSC 上的原生币是 BNB，统一使用 18 位精度（0.1 BNB = 0.1 ether）
    uint256 public minLiquidityAmount = 0.1 ether;

    // === 预售完成流程相关状态变量 ===
    bool public presaleFinalized = false; // 预售是否已完成处理
    uint256 public finalizedTokenAmount = 0; // 最终用于流动性的代币数量
    bool public autoFinalizationEnabled = true; // 自动完成开关

    uint256 public presaleStatus = 0;
    uint256 public lastIndex = 0;

    uint256 public nowStage = 0;
    uint256 public stageUnlockRate = 10;
    // 代币数量使用 18 位基础单位；该值由 setPoolData 的 _coin 覆盖
    uint256 public marketDisAmount = 1500000 ether;
    uint256 public lastMarketAmount = 0;

    uint256 public feeTotal = 8000;

    uint256 public maxInsideNum = 1;

    // === LP分配机制相关状态变量 ===
    uint256 public userLPShare = 8000; // 用户LP分配比例 (80% = 8000/10000)
    uint256 public devLPShare = 2000; // 开发团队LP分配比例 (20% = 2000/10000)
    address public devLPReceiver; // 开发团队LP接收地址
    uint256 public constant LP_SHARE_BASE = 10000; // 分配比例基数
    bool public lpDistributionEnabled = false; // LP分配功能开关

    // === LGE集成：Vesting释放机制 ===
    uint256 public vestingDelay = 7 days; // 释放延迟（7-90天）
    uint256 public vestingRate = 10; // 释放比例（5-20%）
    uint256 public lastVestingTime; // 上次释放时间
    uint256 public totalVestedAmount; // 总已释放数量
    bool public vestingEnabled = false; // 是否启用vesting
    mapping(address => uint256) public userVestedClaimed; // 用户已领取的vested数量

    // === LGE集成：Backing资产支撑机制 ===
    uint256 public backingShare = 0; // 资产支撑份额（0-50%）
    address public backingReceiver; // 资产支撑接收地址
    uint256 public totalBackingAllocated; // 总分配的backing资金

    // === LGE集成：时间控制和限制 ===
    uint256 public startTime; // 预售开始时间
    uint256 public hardcap; // 硬顶限制
    uint256 public maxBuyPerWallet; // 每个钱包最大购买量

    struct preSaleStruct {
        address user;
        uint256 preSaleCount;
        uint256 hasUnlockAmount;
        uint256 stage;
        bool verify;
    }

    event Minted(address indexed to, uint256 amount, uint256 ethAmount);
    event Unlock(
        address indexed to,
        uint256 ethAmount,
        uint256 coinAmount,
        uint256 time
    );

    // === 流动性管理相关事件 ===
    event LiquidityAdded(
        uint256 tokenAmount,
        uint256 bnbAmount,
        uint256 liquidityTokens,
        address indexed receiver
    );

    event LiquidityConfigured(
        uint256 tokenAmount,
        uint256 bnbAmount,
        uint256 slippage,
        address indexed receiver
    );

    event FactoryAddressSet(
        address indexed oldFactory,
        address indexed newFactory
    );
    event LiquidityFailed(
        string reason,
        uint256 tokenAmount,
        uint256 bnbAmount
    );

    // === BNB流动性相关事件 ===
    event BNBLiquidityAdded(
        uint256 tokenAmount,
        uint256 bnbAmount,
        uint256 liquidityTokens,
        address indexed receiver
    );

    // === BNB累积机制相关事件 ===
    event BNBAccumulated(
        address indexed user,
        uint256 amount,
        uint256 totalAccumulated
    );
    event BNBAccumulationToggled(bool oldEnabled, bool newEnabled);

    // === BNB流动性相关事件 ===
    event BNBProcessed(uint256 bnbAmount, uint256 totalProcessed);
    event LiquidityConfigUpdated(
        uint256 slippage,
        uint256 minAmount,
        bool enabled
    );
    event LiquidityProcessFailed(string reason, uint256 bnbAmount);
    event EmergencyWithdraw(
        string tokenType,
        uint256 amount,
        address indexed to
    );

    // === 预售完成流程相关事件 ===
    event PresaleFinalizationStarted(uint256 bnbAmount, uint256 timestamp);
    event TokensReceivedFromFactory(
        uint256 tokenAmount,
        address indexed factory
    );
    event LiquidityParametersCalculated(uint256 tokenAmount, uint256 bnbAmount);
    event PresaleFinalizationCompleted(
        uint256 tokenAmount,
        uint256 bnbAmount,
        uint256 liquidityTokens,
        address indexed lpReceiver,
        uint256 timestamp
    );
    event PresaleFinalizationFailed(string reason, uint256 step);

    // === LP分配相关事件 ===
    event LPDistributionSet(
        uint256 userShare,
        uint256 devShare,
        address devReceiver,
        bool enabled
    );
    event LPDistributed(
        address indexed user,
        uint256 userAmount,
        uint256 devAmount,
        address devReceiver,
        uint256 timestamp
    );

    // === LGE集成相关事件 ===
    event VestingConfigSet(uint256 delay, uint256 rate, bool enabled);
    event BackingConfigSet(uint256 share, address receiver);
    event VestedLPClaimed(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );
    event BackingFundsAllocated(
        uint256 amount,
        address receiver,
        uint256 timestamp
    );
    event LGEConfigSet(
        uint256 startTime,
        uint256 hardcap,
        uint256 maxBuyPerWallet
    );

    bool private _initialized;

    function initialize(address _owner, address _router, address _usdt) external {
        require(!_initialized, "Already initialized");
        _initialized = true;

        _transferOwnership(_owner);
        router = IPancakeRouter02(_router);
        USDT = _usdt;
        slippageProtection = 500;
        bnbAccumulationEnabled = true;
        liquiditySlippage = 300;
        liquidityEnabled = true;
        minLiquidityAmount = 0.1 ether;
        autoFinalizationEnabled = true;
        stageUnlockRate = 10;
        marketDisAmount = 1500000 ether;
        feeTotal = 8000;
        maxInsideNum = 1;
        userLPShare = 8000;
        devLPShare = 2000;
        vestingDelay = 7 days;
        vestingRate = 10;
    }

    constructor() {}

    modifier onlyManager() {
        require(managerList[msg.sender], "Ownable: caller is not the manager");
        _;
    }

    function setManager(address _address, bool isManager) public onlyOwner {
        managerList[_address] = isManager;
    }

    function setVerify(address _addr, bool verify) external payable onlyOwner {
        preSaleStruct memory _p = preSaleAddress[_addr];
        uint256 _pNum = _p.preSaleCount;
        require(_pNum != 0 && _p.hasUnlockAmount == 0, "Not presaled");

        _p.verify = verify;
        if (verify == false) {
            _p.preSaleCount = 0;
            require(msg.value >= (_pNum * preSaleEthAmount), "Not enough");
            _transferETH(_addr, (_pNum * preSaleEthAmount));
        }
        preSaleAddress[_addr] = _p;
    }

    function setCoinAddress(address _coin) external onlyOwner {
        coinAddress = _coin;
        IPancakeFactory factory = IPancakeFactory(router.factory());
        lpAddress = factory.getPair(router.WETH(), coinAddress);
    }

    function setFeeRate(uint256 _feeRate) external onlyOwner {
        require(_feeRate < 10000, "rate error");
        feeTotal = _feeRate;
    }

    function setCoinAmount(uint256 _coinAmount) external onlyOwner {
        coinAmount = _coinAmount;
    }

    /**
     * @dev 设置LP分配参数
     * @param _userShare 用户分配比例 (基于10000)
     * @param _devShare 开发团队分配比例 (基于10000)
     * @param _devReceiver 开发团队接收地址
     * @param _enabled 是否启用LP分配功能
     */
    function setLPDistribution(
        uint256 _userShare,
        uint256 _devShare,
        address _devReceiver,
        bool _enabled
    ) external onlyOwner {
        require(
            _userShare + _devShare == LP_SHARE_BASE,
            "Invalid shares total"
        );
        require(_userShare > 0, "User share must be > 0");
        require(_devShare >= 0, "Dev share must be >= 0");

        if (_enabled && _devShare > 0) {
            require(_devReceiver != address(0), "Invalid dev receiver");
            require(
                _devReceiver != address(this),
                "Cannot be contract address"
            );
        }

        userLPShare = _userShare;
        devLPShare = _devShare;
        devLPReceiver = _devReceiver;
        lpDistributionEnabled = _enabled;

        emit LPDistributionSet(_userShare, _devShare, _devReceiver, _enabled);
    }

    /**
     * @dev 设置Vesting释放配置（基于LGE参数）
     * @param _vestingDelay 释放延迟（7-90天）
     * @param _vestingRate 释放比例（5-20%）
     * @param _enabled 是否启用vesting功能
     */
    function setVestingConfig(
        uint256 _vestingDelay,
        uint256 _vestingRate,
        bool _enabled
    ) external onlyOwner {
        require(
            _vestingDelay >= 7 days && _vestingDelay <= 90 days,
            "Vesting delay must be 7-90 days"
        );
        require(
            _vestingRate >= 5 && _vestingRate <= 20,
            "Vesting rate must be 5-20%"
        );

        vestingDelay = _vestingDelay;
        vestingRate = _vestingRate;
        vestingEnabled = _enabled;

        if (_enabled && lastVestingTime == 0) {
            lastVestingTime = block.timestamp;
        }

        emit VestingConfigSet(_vestingDelay, _vestingRate, _enabled);
    }

    /**
     * @dev 设置Backing资产支撑配置（基于LGE参数）
     * @param _backingShare 资产支撑份额（0-50%）
     * @param _backingReceiver 资产支撑接收地址
     */
    function setBackingConfig(
        uint256 _backingShare,
        address _backingReceiver
    ) external onlyOwner {
        require(_backingShare <= 50, "Backing share must be <=50%");

        if (_backingShare > 0) {
            require(_backingReceiver != address(0), "Invalid backing receiver");
            require(
                _backingReceiver != address(this),
                "Cannot be contract address"
            );
        }

        backingShare = _backingShare;
        backingReceiver = _backingReceiver;

        emit BackingConfigSet(_backingShare, _backingReceiver);
    }

    /**
     * @dev 设置LGE基础配置（基于LGE参数）
     * @param _startTime 预售开始时间
     * @param _hardcap 硬顶限制
     * @param _maxBuyPerWallet 每个钱包最大购买量
     */
    function setLGEConfig(
        uint256 _startTime,
        uint256 _hardcap,
        uint256 _maxBuyPerWallet
    ) external onlyOwner {
        // require(_startTime >= block.timestamp + 0 minutes, "Start time must be at least  minutes from now,TEST");
        require(_maxBuyPerWallet > 0, "Max buy per wallet must be > 0");
        require(_hardcap > 0, "Hardcap must be > 0");

        startTime = _startTime;
        hardcap = _hardcap;
        maxBuyPerWallet = _maxBuyPerWallet;

        emit LGEConfigSet(_startTime, _hardcap, _maxBuyPerWallet);
    }

    function setPresaleStatus(uint256 _presaleStatus) external onlyOwner {
        require(
            _presaleStatus == presaleStatus + 1,
            "Can only advance to next status"
        );
        require(_presaleStatus <= 5, "Invalid status value");
        presaleStatus = _presaleStatus;
    }

    function setMarketDisAmount(uint256 _dis) external onlyOwner {
        marketDisAmount = _dis;
    }

    function setMaxInsideNum(uint256 _maxInsideNum) external onlyOwner {
        maxInsideNum = _maxInsideNum;
    }

    /**
     * @dev 动态获取代币总供应量
     * @return 代币总供应量，如果获取失败则返回默认值
     */
    function getTotalSupply() public view returns (uint256) {
        // 检查代币地址是否已设置
        if (coinAddress == address(0)) {
            return 0; // 默认值，用于代币地址未设置的情况
        }

        // 尝试获取代币合约的实际总供应量
        try IERC20(coinAddress).totalSupply() returns (uint256 totalSupply) {
            require(totalSupply > 0, "Invalid total supply");
            return totalSupply;
        } catch {
            return 0;
        }
    }

    function setPoolData(
        uint256 _single,
        uint256 _trade,
        uint256 _total,
        uint256 _max,
        uint256 _coin,
        uint256 _rate
    ) public onlyOwner {
        preSaleEthAmount = _single;
        tadeEthAmount = _trade;
        maxTotalNum = _total;
        preSaleMaxNum = _max;
        coinAmount = _coin;
        stageUnlockRate = _rate;
    }

    function getMarketPrice()
        public
        view
        returns (uint256 tokenPrice, uint256 marketCap)
    {
        if (lpAddress == address(0)) return (0, 0);

        uint256 _bnbAmount = address(lpAddress).balance; // LP池中的BNB
        uint256 _coin = IERC20(coinAddress).balanceOf(lpAddress); // LP池中的TOKEN

        if (_coin == 0) return (0, 0);

        // 计算单个TOKEN的BNB价格（以wei为单位）
        tokenPrice = (_bnbAmount * 1e18) / _coin;

        // 计算总市值（以BNB为单位）
        uint256 totalSupply = getTotalSupply();
        marketCap = (tokenPrice * totalSupply) / 1e18;

        return (tokenPrice, marketCap);
    }

    function getInsidePrice() public view returns (uint256) {
        return (allTradeAmount / allTradeBNB);
    }

    function advanceStage() external onlyOwner {
        (, uint256 marketCap) = getMarketPrice(); // 获取当前市值
        uint256 dynamicThreshold = getMarketDisAmountInBNB(); // 动态阈值

        if (marketCap - lastMarketAmount >= dynamicThreshold) {
            require(nowStage < 1000 / stageUnlockRate, "max");
            nowStage++;
            // lastMarketAmount 与 marketCap 都是 BNB（wei）单位，不能累加 Token 数量。
            lastMarketAmount = lastMarketAmount + dynamicThreshold;
        }
    }

    // 修改函数
    function getBNBPrice() public view returns (uint256) {
        // 获取BNB-USDT交易对地址
        address bnbUsdtPair = IPancakeFactory(PANCAKE_FACTORY).getPair(
            WBNB,
            USDT
        );

        // 如果交易对不存在，返回默认价格
        if (bnbUsdtPair == address(0)) {
            return 600 * 1e18; // 默认600 USDT
        }

        // 获取交易对中的储备量
        uint256 bnbReserve = IERC20(WBNB).balanceOf(bnbUsdtPair);
        uint256 usdtReserve = IERC20(USDT).balanceOf(bnbUsdtPair);

        // 如果BNB储备为0，返回默认价格
        if (bnbReserve == 0) {
            return 600 * 1e18; // 默认600 USDT
        }

        // 计算1 BNB = ? USDT
        return (usdtReserve * 1e18) / bnbReserve;
    }

    function getMarketCapInUSDT() public view returns (uint256) {
        // 获取当前代币价格（BNB计价）
        (, uint256 marketCapInBNB) = getMarketPrice();

        // 获取BNB的USDT价格
        uint256 bnbPrice = getBNBPrice();

        if (bnbPrice == 0) return 0;

        // 转换为USDT计价的市值
        return (marketCapInBNB * bnbPrice) / 1e18;
    }

    function getMarketDisAmountInBNB() public view returns (uint256) {
        uint256 targetUSDT = 1500000 * 1e18; // 150万USDT目标
        uint256 bnbPrice = getBNBPrice();

        if (bnbPrice == 0) return 2500 * 1e18; // 默认2500 BNB

        // 将USDT目标转换为BNB市值
        return (targetUSDT * 1e18) / bnbPrice;
    }

    function unlock() external {
        require(presaleStatus >= 3, "In presale");
        require(coinAmount != 0, "Not lp");
        preSaleStruct memory _p = preSaleAddress[msg.sender];
        require(_p.verify == true && msg.sender == _p.user, "Not verified");
        require(
            _p.preSaleCount != 0 && _p.hasUnlockAmount < coinAmount,
            "Not presaled"
        );
        uint256 _dis = (nowStage - _p.stage);
        uint256 _unlockAmount = (coinAmount * _dis * stageUnlockRate) / 1000;

        IPancakePair(lpAddress).approve(address(router), _unlockAmount);
        (uint256 amount, uint256 amountBNB) = router.removeLiquidityETH(
            coinAddress,
            _unlockAmount,
            0,
            0,
            address(this),
            block.timestamp
        );

        require(amount != 0 && amountBNB != 0, "Error");

        // 代币部分仍然销毁（这是合理的流动性移除机制）
        TransferHelper.safeTransfer(coinAddress, address(0xdead), amount);

        // BNB分配逻辑：集成LGE的backing机制
        uint256 remainingBNB = amountBNB;

        // 第一步：分配backing资金（如果启用）
        if (backingShare > 0 && backingReceiver != address(0)) {
            uint256 backingAmount = (amountBNB * backingShare) / 100;
            if (backingAmount > 0) {
                _transferETH(backingReceiver, backingAmount);
                totalBackingAllocated += backingAmount;
                remainingBNB -= backingAmount;

                emit BackingFundsAllocated(
                    backingAmount,
                    backingReceiver,
                    block.timestamp
                );
            }
        }

        // 第二步：分配剩余BNB（LP分配逻辑）
        if (
            lpDistributionEnabled &&
            devLPShare > 0 &&
            devLPReceiver != address(0)
        ) {
            // 按比例分配剩余BNB
            uint256 userAmount = (remainingBNB * userLPShare) / LP_SHARE_BASE;
            uint256 devAmount = (remainingBNB * devLPShare) / LP_SHARE_BASE;

            // 确保分配总额不超过可用金额（防止舍入误差）
            if (userAmount + devAmount > remainingBNB) {
                devAmount = remainingBNB - userAmount;
            }

            // 分别转账
            if (userAmount > 0) {
                _transferETH(msg.sender, userAmount);
            }
            if (devAmount > 0) {
                _transferETH(devLPReceiver, devAmount);
            }

            emit LPDistributed(
                msg.sender,
                userAmount,
                devAmount,
                devLPReceiver,
                block.timestamp
            );
        } else {
            // 如果未启用LP分配或配置无效，剩余BNB全部给用户（保持向后兼容）
            if (remainingBNB > 0) {
                _transferETH(msg.sender, remainingBNB);
            }
            emit LPDistributed(
                msg.sender,
                remainingBNB,
                0,
                address(0),
                block.timestamp
            );
        }

        _p.stage = nowStage;
        _p.hasUnlockAmount = _p.hasUnlockAmount + _unlockAmount;
        preSaleAddress[msg.sender] = _p;

        emit Unlock(msg.sender, coinAmount, _unlockAmount, block.timestamp);
    }

    receive() external payable {}

    fallback() external payable {}

    /**
     * @dev 统一的ETH转账函数
     * @param to 接收地址
     * @param amount 转账金额
     */
    function _transferETH(address to, uint256 amount) private {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        payable(to).transfer(amount);
    }

    /**
     * @dev 计算代币余额变化
     * @param token 代币地址
     * @param account 账户地址
     * @param beforeBalance 操作前余额
     * @return 余额变化量
     */
    function _getBalanceChange(
        address token,
        address account,
        uint256 beforeBalance
    ) private view returns (uint256) {
        uint256 afterBalance = IERC20(token).balanceOf(account);
        return afterBalance > beforeBalance ? afterBalance - beforeBalance : 0;
    }

    /**
     * @dev 统一的ETH到代币交换函数
     * @param token 目标代币地址
     * @param amount ETH数量
     * @param to 接收地址
     * @return amountOut 实际获得的代币数量
     */
    function _swapETHToToken(
        address token,
        uint256 amount,
        address to
    ) private returns (uint256 amountOut) {
        // 构建交换路径: ETH -> Token (直接交换)
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = token;

        // 记录交换前余额
        uint256 beforeBalance = IERC20(token).balanceOf(to);

        // 执行交换
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: amount
        }(0, path, to, block.timestamp);

        // 计算实际获得的代币数量
        amountOut = _getBalanceChange(token, to, beforeBalance);
    }

    function preSale() external payable {
        preSaleStruct memory _p = preSaleAddress[msg.sender];
        uint256 _pNum = _p.preSaleCount;
        uint256 _copies = msg.value / preSaleEthAmount;

        // 预售未开始或无效支付，直接转给平台方
        if (presaleStatus == 0 || _copies == 0) {
            _transferETH(owner(), msg.value);
            return;
        }

        // 预售已结束或达到上限，直接转给平台方
        if (presaleStatus >= 2 || totalNum >= maxTotalNum) {
            _transferETH(owner(), msg.value);
            return;
        }

        // 有效的预售购买
        if (
            (_pNum + _copies) <= preSaleMaxNum &&
            (totalNum + _copies) <= maxTotalNum
        ) {
            // BNB累积机制：全部累积，不收取手续费
            // 全部BNB累积到合约中
            accumulatedBNB += msg.value;
            totalPresaleBNB += msg.value;

            emit BNBAccumulated(msg.sender, msg.value, accumulatedBNB);

            // 更新用户预售信息
            if (_p.user == address(0)) {
                _p.user = msg.sender;
                _p.preSaleCount = _copies;
                _p.verify = true;
                addressIndex[lastIndex] = msg.sender;
                lastIndex++;
            } else {
                _p.preSaleCount = (_pNum + _copies);
            }
            preSaleAddress[msg.sender] = _p;
            totalNum = (totalNum + _copies);

            emit Minted(msg.sender, _pNum + _copies, msg.value);
        } else {
            // 超出限制，直接转给平台方
            _transferETH(owner(), msg.value);
        }
    }

    function trade() external payable {
        require(presaleStatus == 3, "Cant trade");
        require(msg.value != 0, "Zero");

        uint256 _pNum = tradeCount[msg.sender];
        uint256 _copies = msg.value / tadeEthAmount;

        if (canTrade[msg.sender] == false) {
            preSaleStruct memory _p = preSaleAddress[msg.sender];
            require(_p.preSaleCount != 0 && _p.verify == true, "No verify");
        }

        if (_copies == 0 || (_copies + _pNum) > maxInsideNum) {
            revert("Cant trade");
        }

        // 直接用全部 BNB 进行一次交换
        uint256 _cAmount = _swapETHToToken(
            coinAddress,
            msg.value,
            address(this)
        );
        require(_cAmount != 0, "Error, no swap");

        // 统一使用内部交易模式，代币保留在合约中
        allTradeAmount = allTradeAmount + _cAmount;
        allTradeBNB = (allTradeBNB + msg.value);
        tradeCount[msg.sender] = _copies + _pNum;
    }

    function tradeUnlock() external {
        require(presaleStatus >= 4, "Not in unlock phase");
        uint256 _pNum = tradeCount[msg.sender];
        require(_pNum != 0, "Not trade inside");

        uint256 _amount = _pNum * getInsidePrice() * tadeEthAmount;
        require(_amount != 0, "Price zero");
        tradeCount[msg.sender] = 0;

        TransferHelper.safeTransfer(coinAddress, msg.sender, _amount);
    }

    function getPresaleUnit() external view returns (uint256) {
        return preSaleEthAmount;
    }

    function getTradeUnit() external view returns (uint256) {
        return tadeEthAmount;
    }

    function getPoolData()
        external
        view
        returns (
            uint256 presaleEthAmount_,
            uint256 tradeEthAmount_,
            uint256 maxTotalNum_,
            uint256 presaleMaxNum_,
            uint256 coinAmount_,
            uint256 stageUnlockRate_
        )
    {
        return (
            preSaleEthAmount,
            tadeEthAmount,
            maxTotalNum,
            preSaleMaxNum,
            coinAmount,
            stageUnlockRate
        );
    }

    function sellToken(uint256 _amount) external {
        require(_amount != 0 && presaleStatus == 5, "Error: transfer failed");
        uint256 beforeBalance = IERC20(coinAddress).balanceOf(address(this));
        TransferHelper.safeTransferFrom(
            coinAddress,
            msg.sender,
            address(this),
            _amount
        );

        uint256 _outAmount = _getBalanceChange(
            coinAddress,
            address(this),
            beforeBalance
        );
        require(_outAmount != 0, "Error: transfer failed");
        uint256 fee = (_outAmount * feeTotal) / 10000;

        // 获取代币合约的手续费接收地址
        address feeRecipient = StagedCustomToken(payable(coinAddress))
            .feeRecipient();
        require(feeRecipient != address(0), "Invalid fee recipient");
        TransferHelper.safeTransfer(coinAddress, feeRecipient, fee);
        _outAmount -= fee;

        IERC20(coinAddress).approve(address(router), _outAmount);
        address[] memory path = new address[](2);
        path[0] = coinAddress;
        path[1] = router.WETH();

        uint256 beforeBNBBalance = address(this).balance;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            _outAmount,
            1,
            path,
            address(this),
            block.timestamp
        );
        uint256 amountOut = address(this).balance - beforeBNBBalance;

        if (amountOut > 0) {
            _transferETH(msg.sender, amountOut);
        }
    }

    // === BNB累积机制管理函数 ===

    /**
     * @dev 设置BNB累积开关
     * @param _enabled 是否启用BNB累积
     */
    function setBNBAccumulation(bool _enabled) external onlyOwner {
        bool oldEnabled = bnbAccumulationEnabled;
        bnbAccumulationEnabled = _enabled;
        emit BNBAccumulationToggled(oldEnabled, _enabled);
    }

    /**
     * @dev 查询BNB累积状态
     * @return accumulatedAmount 累积的BNB数量
     * @return presaleAmount 预售阶段累积的BNB
     * @return isEnabled 是否启用累积
     */
    function getBNBAccumulationStatus()
        external
        view
        returns (
            uint256 accumulatedAmount,
            uint256 presaleAmount,
            bool isEnabled
        )
    {
        return (accumulatedBNB, totalPresaleBNB, bnbAccumulationEnabled);
    }

    /**
     * @dev 查询合约BNB余额
     * @return 合约当前BNB余额
     */
    function getContractBNBBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @dev 设置流动性参数
     * @param _slippage 滑点保护 (basis points, 300 = 3%)
     * @param _minAmount 最小流动性金额
     * @param _enabled 是否启用流动性功能
     */
    function setLiquidityConfig(
        uint256 _slippage,
        uint256 _minAmount,
        bool _enabled
    ) external onlyOwner {
        require(_slippage <= 1000, "Slippage too high"); // 最大10%
        require(_minAmount > 0, "Invalid min amount");

        liquiditySlippage = _slippage;
        minLiquidityAmount = _minAmount;
        liquidityEnabled = _enabled;

        emit LiquidityConfigUpdated(_slippage, _minAmount, _enabled);
    }

    /**
     * @dev 查询流动性状态和配置
     */
    function getLiquidityStatus()
        external
        view
        returns (
            uint256 accumulatedBNBAmount,
            uint256 processedBNBAmount,
            uint256 contractBNBBalance,
            uint256 slippage,
            uint256 minAmount,
            bool enabled
        )
    {
        return (
            accumulatedBNB,
            processedBNB,
            address(this).balance,
            liquiditySlippage,
            minLiquidityAmount,
            liquidityEnabled
        );
    }

    /**
     * @dev 紧急提取BNB（仅在紧急情况下使用）
     * @param amount 提取数量 (0表示全部)
     * @param to 接收地址
     */
    function emergencyWithdrawBNB(
        uint256 amount,
        address to
    ) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(!liquidityEnabled, "Disable liquidity first");

        uint256 withdrawAmount = amount == 0 ? address(this).balance : amount;
        require(withdrawAmount > 0, "No BNB to withdraw");
        require(
            address(this).balance >= withdrawAmount,
            "Insufficient balance"
        );

        // 更新累积状态
        if (withdrawAmount <= accumulatedBNB) {
            accumulatedBNB -= withdrawAmount;
        } else {
            accumulatedBNB = 0;
        }

        _transferETH(to, withdrawAmount);
        emit EmergencyWithdraw("BNB", withdrawAmount, to);
    }

    /**
     * @dev 紧急提取代币（仅在紧急情况下使用）
     * @param amount 提取数量 (0表示全部)
     * @param to 接收地址
     */
    function emergencyWithdrawToken(
        uint256 amount,
        address to
    ) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        require(coinAddress != address(0), "Token not set");

        uint256 contractBalance = IERC20(coinAddress).balanceOf(address(this));
        uint256 withdrawAmount = amount == 0 ? contractBalance : amount;
        require(withdrawAmount > 0, "No tokens to withdraw");
        require(
            contractBalance >= withdrawAmount,
            "Insufficient token balance"
        );

        TransferHelper.safeTransfer(coinAddress, to, withdrawAmount);
        emit EmergencyWithdraw("TOKEN", withdrawAmount, to);
    }

    // === 预售完成整合流程 ===

    /**
     * @dev 验证工厂合约授权状态
     * @return hasAuthorization 是否有授权
     * @return authorizedAmount 授权数量
     * @return contractBalance 合约当前代币余额
     */
    function validateFactoryAuthorization()
        public
        view
        returns (
            bool hasAuthorization,
            uint256 authorizedAmount,
            uint256 contractBalance
        )
    {
        if (factoryAddress == address(0) || coinAddress == address(0)) {
            return (false, 0, 0);
        }

        authorizedAmount = IERC20(coinAddress).allowance(
            factoryAddress,
            address(this)
        );
        contractBalance = IERC20(coinAddress).balanceOf(address(this));
        hasAuthorization = authorizedAmount > 0;
    }

    /**
     * @dev 从工厂合约获取授权的代币
     * @return receivedAmount 实际获得的代币数量
     */
    function receiveTokensFromFactory()
        internal
        returns (uint256 receivedAmount)
    {
        (
            bool hasAuth,
            uint256 authorizedAmount,

        ) = validateFactoryAuthorization();
        require(hasAuth, "No factory authorization");
        require(authorizedAmount > 0, "No tokens authorized");

        // 记录转账前余额
        uint256 beforeBalance = IERC20(coinAddress).balanceOf(address(this));

        // 从工厂合约转移代币到预售合约
        TransferHelper.safeTransferFrom(
            coinAddress,
            factoryAddress,
            address(this),
            authorizedAmount
        );

        // 计算实际获得的代币数量
        receivedAmount = _getBalanceChange(
            coinAddress,
            address(this),
            beforeBalance
        );
        require(receivedAmount > 0, "No tokens received");

        emit TokensReceivedFromFactory(receivedAmount, factoryAddress);
    }

    /**
     * @dev 检查BNB/TOKEN池子是否存在
     * @return 池子是否存在
     */
    function _checkBNBPoolExists() internal view returns (bool) {
        if (coinAddress == address(0)) {
            return false;
        }

        try
            IPancakeFactory(router.factory()).getPair(
                router.WETH(),
                coinAddress
            )
        returns (address pairAddress) {
            return pairAddress != address(0);
        } catch {
            return false;
        }
    }

    // 智能选择系统已移除，简化为BNB模式

    // 智能选择配置函数已移除

    // 手动设置流动性类型函数已移除

    // 智能选择系统已删除，简化为BNB模式

    /**
     * @dev 预售完成后的统一处理函数
     * 整合BNB转换、代币获取、流动性添加的完整流程
     */
    function finalizePresaleAndAddLiquidity() external onlyOwner nonReentrant {
        require(!presaleFinalized, "Presale already finalized");
        require(presaleStatus >= 2, "Presale not ended yet");
        require(autoFinalizationEnabled, "Auto finalization disabled");
        require(accumulatedBNB > 0, "No BNB to process");
        require(factoryAddress != address(0), "Factory address not set");
        require(coinAddress != address(0), "Token address not set");
        require(lpTokenReceiver != address(0), "LP receiver not set");

        emit PresaleFinalizationStarted(accumulatedBNB, block.timestamp);

        // 直接使用BNB流动性模式
        try this._executeFinalizationSteps() {
            presaleFinalized = true;
            presaleStatus = 5; // 设置为完成状态

            emit PresaleFinalizationCompleted(
                finalizedTokenAmount,
                liquidityBNBAmount,
                totalLPTokens,
                lpTokenReceiver,
                block.timestamp
            );
        } catch Error(string memory reason) {
            emit PresaleFinalizationFailed(reason, 0);
            revert(string(abi.encodePacked("Finalization failed: ", reason)));
        } catch (bytes memory /*lowLevelData*/) {
            emit PresaleFinalizationFailed("Low level error", 0);
            revert("Finalization failed with low level error");
        }
    }

    /**
     * @dev 计算BNB流动性参数
     * @param bnbAmount 可用的BNB数量
     * @param tokenAmount 可用的代币数量
     * @return tokenForLP 用于流动性的代币数量
     * @return bnbForLP 用于流动性的BNB数量
     */
    function calculateBNBLiquidityParams(
        uint256 bnbAmount,
        uint256 tokenAmount
    ) internal pure returns (uint256 tokenForLP, uint256 bnbForLP) {
        // 使用100%的BNB用于流动性，不保留给团队
        bnbForLP = bnbAmount;

        // 使用100%的代币用于流动性
        tokenForLP = tokenAmount;

        return (tokenForLP, bnbForLP);
    }

    /**
     * @dev 执行完成流程的具体步骤（内部函数，支持try-catch）
     */
    function _executeFinalizationSteps() external {
        require(msg.sender == address(this), "Internal function only");

        // 步骤1: 从工厂获取代币
        uint256 tokensReceived = receiveTokensFromFactory();
        require(tokensReceived > 0, "Token reception failed");

        // 简化为纯BNB流动性模式
        uint256 bnbAmount = accumulatedBNB;

        // 计算BNB流动性参数
        (
            uint256 tokenAmount,
            uint256 bnbAmountForLP
        ) = calculateBNBLiquidityParams(bnbAmount, tokensReceived);

        // 配置BNB流动性参数
        liquidityTokenAmount = tokenAmount;
        liquidityBNBAmount = bnbAmountForLP;
        finalizedTokenAmount = tokenAmount;

        // 添加BNB流动性
        _addBNBLiquidityInternal();
    }

    /**
     * @dev 内部BNB流动性添加函数
     */
    function _addBNBLiquidityInternal() internal {
        require(!liquidityAdded, "Liquidity already added");
        
        require(liquidityTokenAmount > 0, "Token amount not configured");
        require(liquidityBNBAmount > 0, "BNB amount not configured");

        uint256 tokenAmount = liquidityTokenAmount;
        uint256 bnbAmount = liquidityBNBAmount;

        // 计算滑点保护参数
        uint256 tokenAmountMin = (tokenAmount * (10000 - slippageProtection)) /
            10000;
        uint256 bnbAmountMin = (bnbAmount * (10000 - slippageProtection)) /
            10000;

        // 授权路由器使用代币（精确授权）
        _safeApprove(coinAddress, address(router), tokenAmount);

        // 添加BNB流动性（带错误处理）
        try
            router.addLiquidityETH{value: bnbAmount}(
                coinAddress, // token
                tokenAmount, // amountTokenDesired
                tokenAmountMin, // amountTokenMin (滑点保护)
                bnbAmountMin, // amountETHMin (滑点保护)
                lpTokenReceiver, // to (LP代币接收者)
                block.timestamp + 300 // deadline (5分钟)
            )
        returns (uint amountToken, uint amountETH, uint liquidity) {
            // 更新状态
            liquidityAdded = true;
            totalLPTokens = liquidity;

            // 更新累积BNB（减去用于流动性的部分）
            accumulatedBNB -= bnbAmount;

            // 发射成功事件
            emit BNBLiquidityAdded(
                amountToken,
                amountETH,
                liquidity,
                lpTokenReceiver
            );

            // 尝试自动放弃Token权限
            _tryRenounceTokenOwnership();
        } catch Error(string memory reason) {
            _handleLiquidityFailure(reason);
        } catch (bytes memory) {
            _handleLiquidityFailure(
                "BNB liquidity addition failed with low level error"
            );
        }
    }

    /**
     * @dev 设置自动完成开关
     * @param _enabled 是否启用自动完成
     */
    function setAutoFinalization(bool _enabled) external onlyOwner {
        autoFinalizationEnabled = _enabled;
    }

    /**
     * @dev 查询预售完成状态
     */
    function getFinalizationStatus()
        external
        view
        returns (
            bool isFinalized,
            bool autoEnabled,
            uint256 tokenAmount,
            uint256 bnbAmount,
            bool liquidityAdded_,
            uint256 lpTokens
        )
    {
        return (
            presaleFinalized,
            autoFinalizationEnabled,
            finalizedTokenAmount,
            liquidityBNBAmount,
            liquidityAdded,
            totalLPTokens
        );
    }

    // === LP分配查询功能 ===

    /**
     * @dev 查询LP分配配置信息
     * @return userShare 用户分配比例
     * @return devShare 开发团队分配比例
     * @return devReceiver 开发团队接收地址
     * @return enabled 是否启用LP分配功能
     * @return shareBase 分配比例基数
     */
    function getLPDistributionConfig()
        external
        view
        returns (
            uint256 userShare,
            uint256 devShare,
            address devReceiver,
            bool enabled,
            uint256 shareBase
        )
    {
        return (
            userLPShare,
            devLPShare,
            devLPReceiver,
            lpDistributionEnabled,
            LP_SHARE_BASE
        );
    }

    /**
     * @dev 计算用户可领取的vested LP数量（基于LGE vesting机制）
     * @param user 用户地址
     * @return vestedAmount 可领取的vested数量
     */
    function calculateVestedAmount(
        address user
    ) public view returns (uint256 vestedAmount) {
        if (!vestingEnabled || lastVestingTime == 0) {
            return 0;
        }

        preSaleStruct memory _p = preSaleAddress[user];
        if (_p.verify != true || _p.preSaleCount == 0) {
            return 0;
        }

        // 计算经过的vesting周期数
        uint256 elapsedTime = block.timestamp - lastVestingTime;
        uint256 vestingPeriods = elapsedTime / vestingDelay;

        if (vestingPeriods == 0) {
            return 0;
        }

        // 计算用户的总LP份额
        uint256 userTotalLP = _p.preSaleCount; // 用户的预售数量对应的LP

        // 计算每个周期可释放的数量
        uint256 releasePerPeriod = (userTotalLP * vestingRate) / 100;

        // 计算总可释放数量
        uint256 totalVestable = releasePerPeriod * vestingPeriods;

        // 减去已领取的数量
        uint256 alreadyClaimed = userVestedClaimed[user];

        if (totalVestable > alreadyClaimed) {
            vestedAmount = totalVestable - alreadyClaimed;

            // 确保不超过用户的总LP份额
            if (alreadyClaimed + vestedAmount > userTotalLP) {
                vestedAmount = userTotalLP - alreadyClaimed;
            }
        }

        return vestedAmount;
    }

    /**
     * @dev 用户领取vested LP（基于LGE vesting机制）
     */
    function claimVestedLP() external {
        require(vestingEnabled, "Vesting not enabled");
        require(presaleStatus >= 3, "Presale not completed");

        uint256 vestedAmount = calculateVestedAmount(msg.sender);
        require(vestedAmount > 0, "No vested LP available");

        // 更新用户已领取数量
        userVestedClaimed[msg.sender] += vestedAmount;
        totalVestedAmount += vestedAmount;

        // 转移LP代币给用户
        // 注意：这里需要根据实际的LP代币合约来实现转移
        // 暂时使用ETH转移作为示例
        uint256 ethEquivalent = (vestedAmount * address(this).balance) /
            coinAmount;
        if (ethEquivalent > 0) {
            _transferETH(msg.sender, ethEquivalent);
        }

        emit VestedLPClaimed(msg.sender, vestedAmount, block.timestamp);
    }

    /**
     * @dev 预览LP分配结果
     * @param bnbAmount BNB总量
     * @return userAmount 用户将获得的BNB数量
     * @return devAmount 开发团队将获得的BNB数量
     */
    function previewLPDistribution(
        uint256 bnbAmount
    ) external view returns (uint256 userAmount, uint256 devAmount) {
        if (
            lpDistributionEnabled &&
            devLPShare > 0 &&
            devLPReceiver != address(0)
        ) {
            userAmount = (bnbAmount * userLPShare) / LP_SHARE_BASE;
            devAmount = (bnbAmount * devLPShare) / LP_SHARE_BASE;

            // 确保分配总额不超过可用金额
            if (userAmount + devAmount > bnbAmount) {
                devAmount = bnbAmount - userAmount;
            }
        } else {
            userAmount = bnbAmount;
            devAmount = 0;
        }
    }

    /**
     * @dev 查询LGE配置信息
     * @return vestingDelay_ 释放延迟
     * @return vestingRate_ 释放比例
     * @return vestingEnabled_ 是否启用vesting
     * @return backingShare_ 资产支撑份额
     * @return backingReceiver_ 资产支撑接收地址
     * @return startTime_ 预售开始时间
     * @return hardcap_ 硬顶限制
     * @return maxBuyPerWallet_ 每个钱包最大购买量
     */
    function getLGEConfig()
        external
        view
        returns (
            uint256 vestingDelay_,
            uint256 vestingRate_,
            bool vestingEnabled_,
            uint256 backingShare_,
            address backingReceiver_,
            uint256 startTime_,
            uint256 hardcap_,
            uint256 maxBuyPerWallet_
        )
    {
        return (
            vestingDelay,
            vestingRate,
            vestingEnabled,
            backingShare,
            backingReceiver,
            startTime,
            hardcap,
            maxBuyPerWallet
        );
    }

    /**
     * @dev 查询用户的vesting状态
     * @param user 用户地址
     * @return totalLP 用户总LP份额
     * @return vestedAvailable 可领取的vested数量
     * @return alreadyClaimed 已领取数量
     * @return nextVestingTime 下次vesting时间
     */
    function getUserVestingStatus(
        address user
    )
        external
        view
        returns (
            uint256 totalLP,
            uint256 vestedAvailable,
            uint256 alreadyClaimed,
            uint256 nextVestingTime
        )
    {
        preSaleStruct memory _p = preSaleAddress[user];
        totalLP = _p.preSaleCount;
        vestedAvailable = calculateVestedAmount(user);
        alreadyClaimed = userVestedClaimed[user];

        if (vestingEnabled && lastVestingTime > 0) {
            nextVestingTime = lastVestingTime + vestingDelay;
        }

        return (totalLP, vestedAvailable, alreadyClaimed, nextVestingTime);
    }

    // === 流动性管理功能 ===

    /**
     * @dev 设置工厂合约地址
     * @param _factoryAddress 工厂合约地址
     */
    function setFactoryAddress(address _factoryAddress) external onlyOwner {
        require(_factoryAddress != address(0), "Invalid factory address");
        address oldFactory = factoryAddress;
        factoryAddress = _factoryAddress;
        emit FactoryAddressSet(oldFactory, _factoryAddress);
    }

    /**
     * @dev 配置BNB流动性参数
     * @param _tokenAmount 代币数量
     * @param _bnbAmount BNB数量
     * @param _slippage 滑点保护 (basis points, 500 = 5%)
     * @param _lpReceiver LP代币接收地址
     */
    function configureLiquidity(
    uint256 _tokenAmount,
    uint256 _bnbAmount,
    uint256 _slippage,
    address _lpReceiver
) external onlyOwner {
    require(_slippage <= 1000, "Slippage too high");
    require(_lpReceiver != address(0), "Invalid LP receiver");

            // 🔧 自动转移代币：如果代币数量为0，从工厂转移代币到预售合约
        if (_tokenAmount == 0) {
            uint256 factoryAllowance = 0;
            if (factoryAddress != address(0) && coinAddress != address(0)) {
                factoryAllowance = IERC20(coinAddress).allowance(factoryAddress, address(this));
            }
            require(factoryAllowance > 0, "No tokens available from factory");
            
            // 实际转移代币到预售合约
            uint256 beforeBalance = IERC20(coinAddress).balanceOf(address(this));
            TransferHelper.safeTransferFrom(
                coinAddress,
                factoryAddress,
                address(this),
                factoryAllowance
            );
            uint256 afterBalance = IERC20(coinAddress).balanceOf(address(this));
            _tokenAmount = afterBalance - beforeBalance;
            
            require(_tokenAmount > 0, "Failed to receive tokens from factory");
        }

    // �� 最小化修改：如果BNB数量为0，使用当前合约余额
    if (_bnbAmount == 0) {
        _bnbAmount = address(this).balance;
        require(_bnbAmount > 0, "No BNB available");
    }

    // 验证参数
    require(_tokenAmount > 0, "Invalid token amount");
    require(_bnbAmount > 0, "Invalid BNB amount");

    liquidityTokenAmount = _tokenAmount;
    liquidityBNBAmount = _bnbAmount;
    slippageProtection = _slippage;
    lpTokenReceiver = _lpReceiver;

    emit LiquidityConfigured(_tokenAmount, _bnbAmount, _slippage, _lpReceiver);
}

    /**
     * @dev 安全授权函数 - 先撤销再授权
     * @param token 代币地址
     * @param spender 被授权地址
     * @param amount 授权数量
     */
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        // 先撤销现有授权
        TransferHelper.safeApprove(token, spender, 0);
        // 再设置新的授权
        if (amount > 0) {
            TransferHelper.safeApprove(token, spender, amount);
        }
    }

    /**
     * @dev 处理流动性添加失败的情况
     * @param reason 失败原因
     */
    function _handleLiquidityFailure(string memory reason) internal {
        // 撤销所有授权
        _safeApprove(coinAddress, address(router), 0);

        // 发射失败事件
        emit LiquidityFailed(reason, liquidityTokenAmount, liquidityBNBAmount);
    }

    /**
     * @dev 查询工厂合约对预售合约的代币授权额度
     * @return 剩余授权额度
     */
    function getFactoryAllowance() external view returns (uint256) {
        if (factoryAddress == address(0) || coinAddress == address(0)) {
            return 0;
        }
        return IERC20(coinAddress).allowance(factoryAddress, address(this));
    }

    /**
     * @dev 查询合约当前的代币余额
     * @return tokenBalance 项目代币余额
     * @return bnbBalance BNB余额
     */
    function getContractBalances()
        external
        view
        returns (uint256 tokenBalance, uint256 bnbBalance)
    {
        tokenBalance = coinAddress != address(0)
            ? IERC20(coinAddress).balanceOf(address(this))
            : 0;
        bnbBalance = address(this).balance;
    }

    /**
     * @dev 查询BNB流动性配置信息
     */
    function getLiquidityConfig()
        external
        view
        returns (
            uint256 tokenAmount,
            uint256 bnbAmount,
            uint256 slippage,
            address lpReceiver,
            bool added,
            uint256 lpTokens
        )
    {
        return (
            liquidityTokenAmount,
            liquidityBNBAmount,
            slippageProtection,
            lpTokenReceiver,
            liquidityAdded,
            totalLPTokens
        );
    }

    /**
     * @dev 尝试自动放弃Token权限（内部函数）
     * 在流动性添加成功后调用
     */
    function _tryRenounceTokenOwnership() internal {
        if (coinAddress == address(0)) return;

        // 先设置预售合约地址
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = coinAddress.call(
            abi.encodeWithSignature(
                "setPresaleContract(address)",
                address(this)
            )
        );
        success; // 静默忽略返回值

        // 然后调用权限放弃函数
        // solhint-disable-next-line avoid-low-level-calls
        (success, ) = coinAddress.call(
            abi.encodeWithSignature("renounceOwnershipByPresale()")
        );
        success; // 静默忽略返回值

        // 静默处理，不影响主流程
    }
}