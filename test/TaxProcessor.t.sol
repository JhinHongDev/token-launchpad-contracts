// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {TaxProcessor, InvalidBps, NotTaxToken} from "src/TaxProcessor.sol";
import {TaxProcessorInitParams, PackedFeeConfig} from "src/lib/interfaces/ITaxProcessor.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice 模拟路由：1:1 兑换；addLiquidity 全额拉币并记录 LP 接收方
contract MockSwapRouter {
    address public weth;
    address public lastLPReceiver;
    uint256 public lpMinted;

    constructor(address _weth) {
        weth = _weth;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external {
        // 1:1 模拟兑换：拉取 taxToken，铸 quote 给接收方
        MockERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(path[1]).mint(to, amountIn);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external returns (uint256, uint256, uint256) {
        if (failAddLiquidity) {
            revert("mock: addLiquidity failed");
        }
        MockERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        MockERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);
        lastLPReceiver = to;
        lpMinted += 1e18;
        return (amountADesired, amountBDesired, 1e18);
    }

    /// @notice 可让加池失败（测试 try/catch 回退路径）
    bool public failAddLiquidity;

    function setFailAddLiquidity(bool v) external {
        failAddLiquidity = v;
    }
}

/// @notice 可解包的原生币模拟 WBNB（供 Dividend unwraps 路径测试）
contract MockWBNB is MockERC20 {
    constructor() MockERC20("WBNB", "WBNB") {}

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

contract TaxProcessorTest is Test {
    MockERC20 taxToken;
    MockERC20 wbnb;
    MockSwapRouter router;
    TaxProcessor tp;
    Dividend dividendImpl;

    address feeReceiver = address(0xfee1);
    address marketReceiver = address(0x9999);

    function setUp() public {
        taxToken = new MockERC20("Tax", "TAX");
        wbnb = new MockERC20("WBNB", "WBNB");
        router = new MockSwapRouter(address(wbnb));
        tp = new TaxProcessor();
        dividendImpl = new Dividend(address(wbnb), address(0xdead));

        tp.initialize(_params(address(0), 0)); // 默认无 Dividend 实例

        taxToken.mint(address(taxToken), 1000000 ether); // 模拟 V3：税在代币合约自己手里
        vm.prank(address(taxToken));
        taxToken.approve(address(tp), type(uint256).max); // 模拟 V3 的 _processTax 无限授权
    }

    /// @notice EIP-1167 克隆 Dividend 实现（实现合约构造器已禁用初始化器，必须克隆使用）
    function _cloneDividend() internal returns (address instance) {
        address impl = address(dividendImpl);
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender, tx.origin, gasleft()));
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "clone failed");
    }

    function _params(address dividendAddr, uint256 expectedOut) internal view returns (TaxProcessorInitParams memory) {
        return TaxProcessorInitParams({
            quoteToken: address(wbnb),
            router: address(router),
            feeReceiver: feeReceiver,
            marketAddress: marketReceiver,
            dividendAddress: dividendAddr,
            taxToken: address(taxToken),
            feeRate: 0, // 平台不抽成
            marketBps: 4000, // 创作者钱包 40%
            deflationBps: 2000, // 销毁 20%
            lpBps: 2000, // 流动性 20%
            dividendBps: 2000, // 分红 20%
            dividendToken: address(0),
            commissionReceiver: address(0),
            commissionBps: 0,
            converter: address(0),
            liqExpectedOutputAmount: expectedOut
        });
    }

    function test_ProcessTaxSplit() public {
        vm.prank(address(taxToken)); // 模拟 V3 代币回调
        int8 direction = tp.processTaxTokens(10000 ether);

        assertEq(direction, 0, "no reference -> no direction");

        // 平铺四通道：burn 20%=2000 销毁；market 40%=4000 / lp 20%=2000 / dividend 20%=2000
        // 首期 lp 无积累 quote 不配对，随其他通道全部 swap：swapIn=8000 → 1:1 → out 8000
        assertEq(tp.marketQuoteBalance(), 4000 ether);
        assertEq(tp.pendingDividendQuoteTokenBalance(), 2000 ether);
        assertEq(tp.lpQuoteBalance(), 2000 ether, "lp quote credited for next-round pairing");
        assertEq(tp.feeQuoteBalance(), 0);
        // 销毁通道已烧
        assertEq(taxToken.balanceOf(address(0xdead)), 2000 ether);
        // 代币全部换出，processor 不留库存
        assertEq(taxToken.balanceOf(address(tp)), 0);
    }

    function test_LPRollingPairsOnSecondRound() public {
        // 第一期：lp 份额无 quote 配对 → 全部 swap，收益回填 lpQuoteBalance
        vm.prank(address(taxToken));
        tp.processTaxTokens(10000 ether);
        assertEq(tp.lpQuoteBalance(), 2000 ether);

        // 第二期：本期 lp 2000 与上期积累 2000 配对加池，LP 死锁 0xdead
        vm.prank(address(taxToken));
        tp.processTaxTokens(10000 ether);

        assertEq(router.lastLPReceiver(), address(0xdead), unicode"LP 凭证死锁黑洞");
        assertEq(tp.totalTokenAddedToLiquidity(), 2000 ether);
        assertEq(tp.totalQuoteAddedToLiquidity(), 2000 ether);
        // 配对消耗完旧积累；本期 lp 已全部用于配对 → 无新增回填
        assertEq(tp.lpQuoteBalance(), 0);

        // 两期累计派发桶：market 各 4000，dividend 各 2000
        assertEq(tp.marketQuoteBalance(), 8000 ether);
        assertEq(tp.pendingDividendQuoteTokenBalance(), 4000 ether);
    }

    function test_LPPairingFailureFallsBackToSwap() public {
        vm.prank(address(taxToken));
        tp.processTaxTokens(10000 ether); // 积累 lpQuoteBalance = 2000
        router.setFailAddLiquidity(true);

        vm.prank(address(taxToken));
        tp.processTaxTokens(10000 ether); // 配对失败 → 本期 lp 全走 swap

        // 加池未发生
        assertEq(tp.totalTokenAddedToLiquidity(), 0);
        // 旧积累保留待重试 + 本期 lp 收益回填
        assertEq(tp.lpQuoteBalance(), 4000 ether);
        assertEq(tp.marketQuoteBalance(), 8000 ether);
    }

    function test_DispatchWithoutDividendContract() public {
        vm.prank(address(taxToken));
        tp.processTaxTokens(10000 ether);

        uint256 marketBalBefore = wbnb.balanceOf(marketReceiver);
        tp.dispatch();

        assertEq(wbnb.balanceOf(marketReceiver), marketBalBefore + 4000 ether); // 创作者钱包
        assertEq(wbnb.balanceOf(feeReceiver), 2000 ether); // 分红无实例 → 归 feeReceiver 兜底
        assertEq(tp.marketQuoteBalance(), 0);
        assertEq(tp.pendingDividendQuoteTokenBalance(), 0);
        assertEq(tp.totalQuoteSentToMarketing(), 4000 ether);
    }

    function test_DispatchDepositsIntoDividend() public {
        // Dividend 是"实现 + 克隆"模式：构造器禁用初始化器，直接 new 出的实例不可初始化
        Dividend dividend = Dividend(payable(_cloneDividend()));
        dividend.initialize(address(wbnb), address(taxToken), 0);
        address alice = address(0xa11ce);
        vm.prank(address(taxToken));
        dividend.setShare(alice, 1000 ether);

        tp = new TaxProcessor();
        tp.initialize(_params(address(dividend), 0));
        vm.prank(address(taxToken));
        taxToken.approve(address(tp), type(uint256).max); // 模拟 V3 对新 processor 的无限授权

        vm.prank(address(taxToken));
        tp.processTaxTokens(10000 ether);
        assertEq(tp.pendingDividendQuoteTokenBalance(), 2000 ether);

        tp.dispatch(); // 分红 2000 存入 Dividend，alice 为唯一份额人全额归属

        assertEq(wbnb.balanceOf(address(dividend)), 2000 ether);
        assertEq(dividend.withdrawableDividends(alice), 2000 ether);
        assertEq(tp.totalDividendTokenSent(), 2000 ether);
        assertEq(tp.pendingDividendQuoteTokenBalance(), 0);
    }

    function test_DividendDepositNoShareholdersFallsBackToFee() public {
        // 无任何份额人的 Dividend：deposit 返回 false → 资金兜底转 feeReceiver
        Dividend dividend = Dividend(payable(_cloneDividend()));
        dividend.initialize(address(wbnb), address(taxToken), 0);

        tp = new TaxProcessor();
        tp.initialize(_params(address(dividend), 0));
        vm.prank(address(taxToken));
        taxToken.approve(address(tp), type(uint256).max); // 模拟 V3 对新 processor 的无限授权

        vm.prank(address(taxToken));
        tp.processTaxTokens(10000 ether);
        tp.dispatch();

        assertEq(wbnb.balanceOf(address(dividend)), 0);
        assertEq(wbnb.balanceOf(feeReceiver), 2000 ether);
        assertTrue(tp.pendingDividendQuoteTokenBalance() == 0);
    }

    function test_DirectionSignal() public {
        TaxProcessor tp2 = new TaxProcessor();
        tp2.initialize(_params(address(0), 5000 ether)); // 参考 5000 < out 8000 → 价格强 → -1

        vm.prank(address(taxToken));
        taxToken.approve(address(tp2), type(uint256).max); // 模拟 V3 对新 processor 的授权
        vm.prank(address(taxToken));
        int8 direction = tp2.processTaxTokens(10000 ether);
        assertEq(direction, -1, "out above reference -> decrease threshold");
    }

    function test_RevertWhen_ChannelSumNotTenThousand() public {
        TaxProcessor tp2 = new TaxProcessor();
        TaxProcessorInitParams memory p = _params(address(0), 0);
        p.marketBps = 3000; // 合计 9000 ≠ 10000
        vm.expectRevert(InvalidBps.selector);
        tp2.initialize(p);
    }

    function test_RevertWhen_FeeRateTooHigh() public {
        TaxProcessor tp2 = new TaxProcessor();
        TaxProcessorInitParams memory p = _params(address(0), 0);
        p.feeRate = 10001;
        vm.expectRevert(InvalidBps.selector);
        tp2.initialize(p);
    }

    function test_OnlyTaxToken() public {
        vm.expectRevert(NotTaxToken.selector);
        tp.processTaxTokens(1 ether); // 非税代币地址调用

        vm.expectRevert(NotTaxToken.selector);
        tp.addLiquidityForTax(1 ether, 1 ether); // 外部随机地址不可触发加池
    }
}
