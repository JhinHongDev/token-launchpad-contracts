// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransferHelper} from "src/TransferHelper.sol";
import {IPancakeRouter02} from "src/lib/interfaces/IPancakeRouter02.sol";
import {
    ITaxProcessor,
    TaxProcessorInitParams,
    PackedFeeConfig,
    PackedFeeConfigV2
} from "src/lib/interfaces/ITaxProcessor.sol";

// ---------------------------------------------------------------------------
// 自定义错误
// ---------------------------------------------------------------------------

error AlreadyInitialized();
error NotDeployer();
error TaxTokenRequired();
error RouterRequired();
error FeeReceiverRequired();
error InvalidBps();
error NotTaxToken();

/// @notice Launchpad 最小化 TaxProcessor：税代币 → 四通道拆分（创作者钱包/销毁/分红/流动性）
///         → swap 成 quote token(WBNB) → 分账累计，由 dispatch() 统一派发。
/// @dev 与 flap.sh 上游 TaxProcessorBase._processFeeToken/_processTokenDistribution 对齐的简化实现：
///      1. 平台不抽成（feeRate 由 Coordinator 固定传 0），四通道 bps 合计必须 = 10000
///      2. 销毁通道直转 0xdead
///      3. 流动性通道采用上游"整份额滚动"：本期 lp 份额优先配对累计 lpQuoteBalance 加池
///         （LP 死锁 0xdead），剩余 lp 代币随其他通道 swap，其 quote 收益按比例回填
///         lpQuoteBalance 供下期配对（自循环，无需额外资金来源）
///      4. 分红通道在 dispatch 时 approve + IDividend.deposit()；失败则保留余额下期重试
///      5. fee/market 派发保持 WBNB ERC20 转账（有意偏离上游的原生 BNB 模式：
///         上游依赖 _reconcileBalance 兜底失败转账的 ETH 残留，本最小化实现不引入该复杂度；
///         分红侧持有者最终经 Dividend.withdrawDividends 收到原生 BNB，产品体验不变）
///      V3 扩展位（dividendToken/converter/commission/swapRegistry）全部禁用。
contract TaxProcessor is ITaxProcessor {
    uint256 private constant BPS_DENOMINATOR = 10000;
    uint256 private constant DEADLINE_BUFFER = 300;
    address private constant BLACKHOLE = address(0xdead);

    address private immutable _deployer;
    bool private _initialized;

    address public immutable override swapRegistry; // address(0) — 本实现不使用 SwapRegistry

    address public override taxToken;
    address public override router;
    address public override feeReceiver;
    address public override marketAddress;
    address public override dividendAddress;
    address public override commissionReceiver;
    address public override converter;
    address public override dividendToken; // address(0) => 使用 quoteToken（V2 语义）
    address public quoteToken; // 存储值；isWeth 时 getQuoteToken 返回 WETH

    uint16 public override commissionBps;
    uint256 public override liqExpectedOutputAmount;

    uint16 private _feeRate;
    uint16 private _marketBps;
    uint16 private _deflationBps;
    uint16 private _lpBps;
    uint16 private _dividendBps;

    // 分账累计（quote 单位，等待 dispatch 派发；lpQuoteBalance 为流动性通道配对用 quote）
    uint256 public override feeQuoteBalance;
    uint256 public override marketQuoteBalance;
    uint256 public override lpQuoteBalance;
    uint256 public override pendingDividendQuoteTokenBalance;
    uint256 public override commissionQuoteBalance;

    // 累计派发计量
    uint256 public override totalDividendTokenSent;
    uint256 public override totalQuoteSentToDividend;
    uint256 public override totalQuoteAddedToLiquidity;
    uint256 public override totalTokenAddedToLiquidity;
    uint256 public override totalQuoteSentToMarketing;

    event Initialized(address indexed taxToken);
    event TaxProcessed(uint256 taxAmount, uint256 quoteOut, int8 direction);
    event FeeForwardedToReceiver(address indexed token, uint256 amount, address indexed receiver);
    event TokensBurned(uint256 amount);
    event LPAddFailed(uint256 tokenAmount, uint256 quoteAmount);
    event LiquidityAdded(uint256 tokenAmount, uint256 quoteAmount, uint256 liquidity);
    event DividendDepositFailed(uint256 amount);

    constructor() {
        _deployer = msg.sender;
        swapRegistry = address(0);
    }

    modifier onlyTaxToken() {
        // 放行本合约自身：processTaxTokens 经 this.addLiquidityForTax 外部自调用以隔离 try/catch
        if (msg.sender != taxToken && msg.sender != address(this)) revert NotTaxToken();
        _;
    }

    function initialize(TaxProcessorInitParams memory params) external override {
        if (_initialized) revert AlreadyInitialized();
        if (msg.sender != _deployer) revert NotDeployer();
        if (params.taxToken == address(0)) revert TaxTokenRequired();
        if (params.router == address(0)) revert RouterRequired();
        if (params.feeReceiver == address(0)) revert FeeReceiverRequired();
        if (params.feeRate > 10000) revert InvalidBps();
        // 四通道 + commission 合计必须恰好 10000（平台不抽成，费率零头不允许静默归入 fee）
        if (
            uint256(params.marketBps) + params.deflationBps + params.lpBps + params.dividendBps + params.commissionBps
                != 10000
        ) revert InvalidBps();

        _initialized = true;

        taxToken = params.taxToken;
        router = params.router;
        feeReceiver = params.feeReceiver;
        marketAddress = params.marketAddress;
        dividendAddress = params.dividendAddress;
        commissionReceiver = params.commissionReceiver;
        converter = params.converter;
        dividendToken = params.dividendToken;
        quoteToken = params.quoteToken;

        _feeRate = params.feeRate;
        _marketBps = params.marketBps;
        _deflationBps = params.deflationBps;
        _lpBps = params.lpBps;
        _dividendBps = params.dividendBps;
        commissionBps = params.commissionBps;
        liqExpectedOutputAmount = params.liqExpectedOutputAmount;

        emit Initialized(params.taxToken);
    }

    // ---------------------------------------------------------------------------
    // 核心：处理税
    // ---------------------------------------------------------------------------

    /// @notice 拉取税代币 → 四通道拆分 → 销毁/加池配对/swap → 分账累计
    /// @return direction 方向信号语义与 FlapTaxTokenV3._adjustLiquidationThreshold 一致：
    ///     > 0 → swap 输出低于参考（价格弱，提高阈值）
    ///     < 0 → swap 输出高于参考（价格强，降低阈值）
    ///     0   → 无参考值或相等
    function processTaxTokens(uint256 taxAmount) external override onlyTaxToken returns (int8) {
        if (taxAmount == 0) return 0;

        TransferHelper.safeTransferFrom(taxToken, msg.sender, address(this), taxAmount);

        // 平铺分配：各通道按【总税额】直接占比（表单语义：四通道凑齐 100%）。
        // 有意偏离上游嵌套算法（上游对销毁后余额再按比例拆分，导致名义占比失真）。
        uint256 feePart = (taxAmount * _feeRate) / BPS_DENOMINATOR;
        uint256 deflationPart = (taxAmount * _deflationBps) / BPS_DENOMINATOR;
        uint256 marketPart = (taxAmount * _marketBps) / BPS_DENOMINATOR;
        uint256 lpPart = (taxAmount * _lpBps) / BPS_DENOMINATOR;
        uint256 dividendPart = (taxAmount * _dividendBps) / BPS_DENOMINATOR;
        uint256 commissionPart = (taxAmount * commissionBps) / BPS_DENOMINATOR;
        // 整除零头并入 fee 通道（feeRate=0 时仅含舍入尘埃，dispatch 归入 feeReceiver）
        uint256 leftover = taxAmount - feePart - deflationPart - marketPart - lpPart - dividendPart - commissionPart;

        // 通缩部分直接销毁
        if (deflationPart > 0) {
            TransferHelper.safeTransfer(taxToken, BLACKHOLE, deflationPart);
            emit TokensBurned(deflationPart);
        }

        // ── 流动性通道（上游整份额滚动）：先尝试用本期 lp 代币配对已积累的 lp quote 加池 ──
        uint256 lpTaxToSwap = lpPart;
        if (lpPart > 0 && lpQuoteBalance > 0) {
            try this.addLiquidityForTax(lpPart, lpQuoteBalance) returns (
                uint256 actualTokenUsed, uint256 actualQuoteUsed
            ) {
                lpTaxToSwap = lpPart >= actualTokenUsed ? lpPart - actualTokenUsed : 0;
                lpQuoteBalance = lpQuoteBalance >= actualQuoteUsed ? lpQuoteBalance - actualQuoteUsed : 0;
            } catch {
                // 加池失败：保留两侧余额下期重试，本期 lp 全部走 swap 路径（不阻塞清算）
                emit LPAddFailed(lpPart, lpQuoteBalance);
            }
        }

        // 其余全部 swap 成 quote（fee/market/dividend/commission/整除零头/lp剩余）
        uint256 swapIn = feePart + marketPart + dividendPart + commissionPart + leftover + lpTaxToSwap;
        uint256 out = 0;
        if (swapIn > 0) {
            out = _swapToQuote(swapIn);
        }

        // 按各通道占 swapIn 的比例分账 quote 收益；舍入零头并入 fee，确保无未追踪 dust
        if (out > 0 && swapIn > 0) {
            uint256 feeShare = (out * feePart) / swapIn;
            uint256 marketShare = (out * marketPart) / swapIn;
            uint256 dividendShare = (out * dividendPart) / swapIn;
            uint256 commissionShare = (out * commissionPart) / swapIn;
            uint256 lpShare = lpTaxToSwap > 0 ? (out * lpTaxToSwap) / swapIn : 0;

            uint256 credited = feeShare + marketShare + dividendShare + commissionShare + lpShare;
            feeQuoteBalance += feeShare + (out - credited);
            marketQuoteBalance += marketShare;
            pendingDividendQuoteTokenBalance += dividendShare;
            commissionQuoteBalance += commissionShare;
            lpQuoteBalance += lpShare;
        }

        // 方向信号（弱化异常场景：swap 失败时 out==0，返回 +1 让其回升阈值→更少清算）
        int8 direction;
        if (liqExpectedOutputAmount != 0) {
            if (out > liqExpectedOutputAmount) direction = -1;
            else if (out < liqExpectedOutputAmount) direction = 1;
        }

        emit TaxProcessed(taxAmount, out, direction);
        return direction;
    }

    /// @notice 用税收 lp 份额与累计 lp quote 加池；LP 凭证死锁 0xdead
    /// @dev 供 processTaxTokens 经 this.xxx 外部调用以隔离 try/catch 的调用栈，
    ///      仅税代币（即本合约内部流程）可触发。
    /// @return actualTokenUsed 实际消耗的代币量
    /// @return actualQuoteUsed 实际消耗的 quote 量
    function addLiquidityForTax(uint256 tokenAmount, uint256 quoteAmount)
        external
        onlyTaxToken
        returns (uint256 actualTokenUsed, uint256 actualQuoteUsed)
    {
        TransferHelper.safeApprove(taxToken, router, tokenAmount);
        TransferHelper.safeApprove(getQuoteToken(), router, quoteAmount);

        (uint256 amountToken, uint256 amountQuote, uint256 liquidity) = IPancakeRouter02(router)
            .addLiquidity(
                taxToken, getQuoteToken(), tokenAmount, quoteAmount, 0, 0, BLACKHOLE, block.timestamp + DEADLINE_BUFFER
            );

        totalTokenAddedToLiquidity += amountToken;
        totalQuoteAddedToLiquidity += amountQuote;
        emit LiquidityAdded(amountToken, amountQuote, liquidity);

        return (amountToken, amountQuote);
    }

    /// @notice BondingCurve 阶段税（本项目不触发；保留接口兼容）
    function processBondingCurveTax(uint256 quoteAmount) external override onlyTaxToken {
        if (quoteAmount == 0) return;
        TransferHelper.safeTransferFrom(getQuoteToken(), msg.sender, address(this), quoteAmount);
        marketQuoteBalance += quoteAmount;
    }

    /// @notice 派发累计 quote 余额到各接收方；分红通道 deposit 进 Dividend 合约
    /// @dev 权限开放（任何人可触发派发，push 模型）；CEI：先清账再交互
    function dispatch() external override {
        if (feeQuoteBalance > 0 && feeReceiver != address(0)) {
            uint256 amount = feeQuoteBalance;
            feeQuoteBalance = 0;
            TransferHelper.safeTransfer(getQuoteToken(), feeReceiver, amount);
        }

        if (marketQuoteBalance > 0) {
            uint256 amount = marketQuoteBalance;
            marketQuoteBalance = 0;
            address to = marketAddress != address(0) ? marketAddress : feeReceiver;
            TransferHelper.safeTransfer(getQuoteToken(), to, amount);
            totalQuoteSentToMarketing += amount;
        }

        // ── 分红通道：存入 Dividend 合约按持仓分账 ──
        if (pendingDividendQuoteTokenBalance > 0) {
            uint256 amount = pendingDividendQuoteTokenBalance;
            pendingDividendQuoteTokenBalance = 0;
            _depositDividend(amount);
        }

        if (commissionQuoteBalance > 0) {
            uint256 amount = commissionQuoteBalance;
            commissionQuoteBalance = 0;
            address to = commissionReceiver != address(0) ? commissionReceiver : feeReceiver;
            TransferHelper.safeTransfer(getQuoteToken(), to, amount);
        }
    }

    /// @notice 将分红 quote 存入 Dividend 合约；无 Dividend 或存款失败时兜底转 feeReceiver
    /// @dev IDividend.deposit 在 totalShares==0（尚无达标持有人）时返回 false ——
    ///      此时资金转 feeReceiver 而非无限挂起（launchpad 场景无链下 keeper 重试机制）。
    ///      deposit 内部用 pull 模式（safeTransferFrom），需先授权。
    ///      兜底恒为 feeReceiver：绝不把资金裸转进 Dividend（不经 deposit 计账 = 无法被领取）。
    function _depositDividend(uint256 amount) internal {
        if (dividendAddress == address(0)) {
            TransferHelper.safeTransfer(getQuoteToken(), feeReceiver, amount);
            return;
        }

        TransferHelper.safeApprove(getQuoteToken(), dividendAddress, amount);
        try IDividend(dividendAddress).deposit(amount) returns (bool success) {
            if (success) {
                totalDividendTokenSent += amount;
                totalQuoteSentToDividend += amount;
                return;
            }
        } catch {
            // fall through 到兜底
        }
        // 存款失败/无份额：转 feeReceiver，不锁定资金
        TransferHelper.safeTransfer(getQuoteToken(), feeReceiver, amount);
        emit DividendDepositFailed(amount);
    }

    /// @notice 将税代币换成 quote token；失败时直接给 feeReceiver 兜底并记录事件
    function _swapToQuote(uint256 amountIn) internal returns (uint256 out) {
        address quote = getQuoteToken();
        address weth_ = weth();
        if (quote == address(0) || weth_ == address(0)) {
            TransferHelper.safeTransfer(taxToken, feeReceiver, amountIn);
            emit FeeForwardedToReceiver(taxToken, amountIn, feeReceiver);
            return 0;
        }

        address[] memory path;
        if (quote == weth_) {
            path = new address[](2);
            path[0] = taxToken;
            path[1] = weth_;
        } else {
            path = new address[](3);
            path[0] = taxToken;
            path[1] = weth_; // 经 WETH 中转（需 weth/quote 池存在）
            path[2] = quote;
        }

        uint256 before = IERC20(quote).balanceOf(address(this));
        TransferHelper.safeApprove(taxToken, router, amountIn);

        try IPancakeRouter02(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, 0, path, address(this), block.timestamp + DEADLINE_BUFFER
            ) {}
        catch {
            TransferHelper.safeTransfer(taxToken, feeReceiver, amountIn); // 兑换失败兜底，不锁定资金
            emit FeeForwardedToReceiver(taxToken, amountIn, feeReceiver);
            return 0;
        }

        out = IERC20(quote).balanceOf(address(this)) - before;
    }

    // ---------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------

    function isWeth() public view returns (bool) {
        return quoteToken == address(0) || quoteToken == weth();
    }

    function weth() public view override returns (address) {
        return router != address(0) ? IPancakeRouter02(router).WETH() : address(0);
    }

    function getQuoteToken() public view override returns (address) {
        return isWeth() ? weth() : quoteToken;
    }

    function flapBlackHole() external pure override returns (address) {
        return address(0xdead);
    }

    /// @notice 兼容视图：累计待派发的分红 quote
    function dividendQuoteBalance() external view override returns (uint256) {
        return pendingDividendQuoteTokenBalance;
    }

    /// @notice dividend token 侧余额（本实现不单独持有 dividend token，恒 0）
    function dividendTokenBalance() external view override returns (uint256) {
        return 0;
    }

    function requiresMEVProtection() external view override returns (bool) {
        return dividendToken != address(0) && dividendToken != quoteToken && dividendToken != taxToken;
    }

    function feeConfig() external view override returns (PackedFeeConfig memory) {
        return PackedFeeConfig({
            marketBps: _marketBps,
            deflationBps: _deflationBps,
            lpBps: _lpBps,
            dividendBps: _dividendBps,
            feeRate: _feeRate,
            isWeth: isWeth()
        });
    }

    function feeConfigV2() external view override returns (PackedFeeConfigV2 memory) {
        return PackedFeeConfigV2({
            marketBps: _marketBps,
            deflationBps: _deflationBps,
            lpBps: _lpBps,
            dividendBps: _dividendBps,
            feeRate: _feeRate,
            isWeth: isWeth(),
            commissionBps: commissionBps,
            dividendToken: dividendToken
        });
    }
}

    /// @notice Dividend 合约接口（仅本合约所需子集；完整定义见 src/lib/dividend/IDividend.sol）
    interface IDividend {
        function deposit(uint256 amount) external returns (bool success);
    }
