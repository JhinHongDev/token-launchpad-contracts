// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {
    TaxProcessor,
    AlreadyInitialized,
    NotDeployer,
    TaxTokenRequired,
    RouterRequired,
    FeeReceiverRequired,
    NotTaxToken
} from "src/TaxProcessor.sol";
import {TaxProcessorInitParams} from "src/lib/interfaces/ITaxProcessor.sol";

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

/// @notice 模拟路由：1:1 兑换（输出铸造到 path 末位代币）；可注入兑换失败
contract MockSwapRouter {
    address public weth;
    bool public failSwap;

    constructor(address _weth) {
        weth = _weth;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function setFailSwap(bool v) external {
        failSwap = v;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256,
        address[] calldata path,
        address to,
        uint256
    ) external {
        if (failSwap) revert("mock: swap failed");
        // 1:1 模拟兑换：拉取 path[0]，铸 path 末位代币给接收方
        MockERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(path[path.length - 1]).mint(to, amountIn);
    }
}

/// @notice 可解包/包装原生币的模拟 WBNB
contract MockWBNB is MockERC20 {
    constructor() MockERC20("WBNB", "WBNB") {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }
}

/// @notice 无 receive/fallback 的收款合约：拒收原生 BNB（测试 WBNB 兜底路径）
contract NoReceiveReceiver {}

contract TaxProcessorTest is Test {
    MockERC20 taxToken;
    MockWBNB wbnb;
    MockSwapRouter router;
    TaxProcessor tp;

    address feeReceiver = address(0xfee1);

    function setUp() public {
        taxToken = new MockERC20("Tax", "TAX");
        wbnb = new MockWBNB();
        router = new MockSwapRouter(address(wbnb));
        tp = new TaxProcessor();

        // MockWBNB 凭空铸出 WBNB，需预注 native 偿付 withdraw 解包
        vm.deal(address(wbnb), 1_000_000 ether);

        tp.initialize(_params(0));

        taxToken.mint(address(taxToken), 1000000 ether); // 模拟 V3：税在代币合约自己手里
        vm.prank(address(taxToken));
        taxToken.approve(address(tp), type(uint256).max); // 模拟 V3 的 _processTax 无限授权
    }

    function _params(uint256 expectedOut) internal view returns (TaxProcessorInitParams memory) {
        return TaxProcessorInitParams({
            quoteToken: address(wbnb),
            router: address(router),
            feeReceiver: feeReceiver,
            marketAddress: address(0),
            dividendAddress: address(0),
            taxToken: address(taxToken),
            feeRate: 0,
            marketBps: 0,
            deflationBps: 0,
            lpBps: 0,
            dividendBps: 0,
            dividendToken: address(0),
            commissionReceiver: address(0),
            commissionBps: 0,
            converter: address(0),
            liqExpectedOutputAmount: expectedOut
        });
    }

    /// @notice 为新 processor 实例补充模拟 V3 的无限授权
    function _authorize(TaxProcessor processor) internal {
        vm.prank(address(taxToken));
        taxToken.approve(address(processor), type(uint256).max);
    }

    // -------------------------------------------------------------------------
    // 主路径：swap → 原生 BNB → 收款人
    // -------------------------------------------------------------------------

    function test_ForwardsNativeToReceiver() public {
        vm.prank(address(taxToken)); // 模拟 V3 代币回调
        int8 direction = tp.processTaxTokens(10000 ether);

        assertEq(direction, 0, "no reference -> no direction");
        assertEq(feeReceiver.balance, 10000 ether, "receiver got native BNB");
        assertEq(wbnb.balanceOf(address(tp)), 0, "no WBNB dust left");
        assertEq(address(tp).balance, 0, "no native dust left");
        assertEq(taxToken.balanceOf(address(tp)), 0, "all tax tokens swapped");
        assertEq(tp.totalQuoteSentToReceiver(), 10000 ether);

        // 第二轮：累计器与余额持续叠加（清算即派发，无残留分账）
        vm.prank(address(taxToken));
        tp.processTaxTokens(5000 ether);
        assertEq(feeReceiver.balance, 15000 ether);
        assertEq(tp.totalQuoteSentToReceiver(), 15000 ether);
    }

    function test_SwapFailureForwardsTokensToReceiver() public {
        router.setFailSwap(true);

        vm.prank(address(taxToken));
        int8 direction = tp.processTaxTokens(10000 ether);

        // 兑换失败兜底：税代币原形态直转收款人，不锁资金
        assertEq(taxToken.balanceOf(feeReceiver), 10000 ether);
        assertEq(feeReceiver.balance, 0);
        assertEq(tp.totalQuoteSentToReceiver(), 0);
        assertEq(direction, 0, "no reference -> no direction");
    }

    function test_ReceiverRejectsNativeFallsBackToWBNB() public {
        NoReceiveReceiver rejecter = new NoReceiveReceiver();

        TaxProcessor tp2 = new TaxProcessor();
        TaxProcessorInitParams memory p = _params(0);
        p.feeReceiver = address(rejecter);
        tp2.initialize(p);
        _authorize(tp2);

        vm.prank(address(taxToken));
        tp2.processTaxTokens(10000 ether);

        // 原生转账被拒 → 包回 WBNB 走 ERC20，资金不锁死
        assertEq(wbnb.balanceOf(address(rejecter)), 10000 ether, "WBNB ERC20 fallback");
        assertEq(address(tp2).balance, 0, "no native stuck");
        assertEq(wbnb.balanceOf(address(tp2)), 0, "no WBNB stuck");
        assertEq(tp2.totalQuoteSentToReceiver(), 10000 ether);
    }

    function test_QuoteTokenNotWethForwardsERC20() public {
        MockERC20 usdt = new MockERC20("USDT", "USDT");
        MockSwapRouter router2 = new MockSwapRouter(address(wbnb));

        TaxProcessor tp2 = new TaxProcessor();
        TaxProcessorInitParams memory p = _params(0);
        p.quoteToken = address(usdt);
        p.router = address(router2);
        tp2.initialize(p);
        _authorize(tp2);

        vm.prank(address(taxToken));
        tp2.processTaxTokens(10000 ether);

        // path: taxToken → WBNB → USDT，1:1 输出以 USDT 形态 ERC20 直转
        assertEq(usdt.balanceOf(feeReceiver), 10000 ether);
        assertEq(feeReceiver.balance, 0, "no native for non-weth quote");
    }

    // -------------------------------------------------------------------------
    // 方向信号（动态清算阈值）
    // -------------------------------------------------------------------------

    function test_DirectionSignal() public {
        // 参考低于输出（out=10000 > 5000）→ 价格强 → -1
        TaxProcessor tp2 = new TaxProcessor();
        tp2.initialize(_params(5000 ether));
        _authorize(tp2);
        vm.prank(address(taxToken));
        assertEq(tp2.processTaxTokens(10000 ether), -1, "out above reference -> decrease threshold");

        // 参考高于输出（out=10000 < 20000）→ 价格弱 → +1
        TaxProcessor tp3 = new TaxProcessor();
        tp3.initialize(_params(20000 ether));
        _authorize(tp3);
        vm.prank(address(taxToken));
        assertEq(tp3.processTaxTokens(10000 ether), 1, "out below reference -> increase threshold");
    }

    // -------------------------------------------------------------------------
    // BondingCurve 兼容存根与 no-op dispatch
    // -------------------------------------------------------------------------

    function test_ProcessBondingCurveTaxForwardsQuote() public {
        wbnb.mint(address(taxToken), 500 ether); // BondingCurve 税以 quote 形态持有
        vm.prank(address(taxToken));
        wbnb.approve(address(tp), type(uint256).max);

        vm.prank(address(taxToken));
        tp.processBondingCurveTax(500 ether);

        assertEq(feeReceiver.balance, 500 ether, "quote forwarded as native");
        assertEq(tp.totalQuoteSentToReceiver(), 500 ether);
    }

    function test_DispatchIsNoop() public {
        // 清算即派发：dispatch 恒为 no-op，任何人可调用且无副作用
        tp.dispatch();
        assertEq(feeReceiver.balance, 0);
    }

    function test_ZeroAmountNoop() public {
        vm.prank(address(taxToken));
        assertEq(tp.processTaxTokens(0), 0);
    }

    // -------------------------------------------------------------------------
    // 权限与初始化校验
    // -------------------------------------------------------------------------

    function test_RevertWhen_TaxTokenZero() public {
        TaxProcessor tp2 = new TaxProcessor();
        TaxProcessorInitParams memory p = _params(0);
        p.taxToken = address(0);
        vm.expectRevert(TaxTokenRequired.selector);
        tp2.initialize(p);
    }

    function test_RevertWhen_RouterZero() public {
        TaxProcessor tp2 = new TaxProcessor();
        TaxProcessorInitParams memory p = _params(0);
        p.router = address(0);
        vm.expectRevert(RouterRequired.selector);
        tp2.initialize(p);
    }

    function test_RevertWhen_FeeReceiverZero() public {
        TaxProcessor tp2 = new TaxProcessor();
        TaxProcessorInitParams memory p = _params(0);
        p.feeReceiver = address(0);
        vm.expectRevert(FeeReceiverRequired.selector);
        tp2.initialize(p);
    }

    function test_RevertWhen_AlreadyInitialized() public {
        vm.expectRevert(AlreadyInitialized.selector);
        tp.initialize(_params(0));
    }

    function test_RevertWhen_NotDeployer() public {
        TaxProcessor tp2 = new TaxProcessor();
        vm.prank(address(0xBEEF));
        vm.expectRevert(NotDeployer.selector);
        tp2.initialize(_params(0));
    }

    function test_OnlyTaxToken() public {
        vm.expectRevert(NotTaxToken.selector);
        tp.processTaxTokens(1 ether); // 非税代币地址调用

        vm.expectRevert(NotTaxToken.selector);
        tp.processBondingCurveTax(1 ether);
    }
}
