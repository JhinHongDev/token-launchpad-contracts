// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {
    PRESALE,
    NothingToClaim,
    NoTokensToClaim,
    SoftCapTooLow,
    InvalidStatus,
    PresaleNotOpen,
    NotLaunched,
    NotAfterLaunch
} from "src/Presale.sol";

contract MockRouter {
    address public weth;

    function WETH() external view returns (address) {
        return weth;
    }

    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        // 真实路由从调用方(PRESALE)拉取代币，LP 侧直接给接收方(0xdead)
        FlapTaxTokenV3(token).transferFrom(msg.sender, to, amountTokenDesired);
        return (amountTokenDesired, msg.value, 1e18);
    }
}

contract DummyTaxProcessor {}

/// @dev 故意消耗远超 2300 gas 的原生币接收方：
///      验证 withdrawRemainingBNB 走低层 call，owner 为高耗气合约钱包时不被旧 .transfer 语义卡死
contract GreedyReceiver {
    uint256 public load;
    uint256 public received;

    receive() external payable {
        received += msg.value;
        for (uint256 i = 0; i < 200; i++) {
            load += i; // 单槽热写 ×200，明显超出 2300 gas 津贴
        }
    }

    function initializePresale(PRESALE p, address router) external {
        p.initialize(address(this), router);
    }

    /// 统一以自身身份执行 PRESALE 的 onlyOwner 调用
    function exec(address target, bytes memory data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "exec failed");
        return ret;
    }
}

/// @title 软顶失败结算与配置冻结单元测试
contract PresaleSoftCapTest is Test {
    uint256 constant SUPPLY = 1e9 ether;

    MockRouter router;
    FlapTaxTokenV3 token;
    PRESALE presale;
    address pair = address(0x1111);
    uint256 creatorShare = SUPPLY * 30 / 100;
    uint256 poolShare = SUPPLY * 20 / 100;
    uint256 presaleShare = SUPPLY * 50 / 100;

    uint256 private _cloneNonce;

    // 结构性镜像合约事件，供 vm.expectEmit 按 topic 匹配（签名一致即可命中）
    event PresaleFailed(uint256 raisedBNB, uint256 softCap);
    event Refunded(address indexed user, uint256 amount);

    function setUp() public {
        router = new MockRouter();
        vm.deal(address(this), 1000 ether);
        token = _freshToken();

        presale = new PRESALE();
        presale.initialize(address(this), address(router));
        presale.configureLaunch(true, address(this), creatorShare, poolShare, presaleShare);
        presale.setPresaleTerms(1e15, presaleShare, 1e8 ether, 0, 0.1 ether, 0); // 0.001 BNB/token
        presale.setVestingConfig(7 days, 10);
        presale.setCoinAndPair(address(token), pair);

        // 模拟 Coordinator：全量代币转给 PRESALE + token 所有权移交
        token.transfer(address(presale), SUPPLY);
        token.transferOwnership(address(presale));
    }

    // ---------------------------------------------------------------------------
    // softCap 配置
    // ---------------------------------------------------------------------------

    function test_DefaultSoftCapMatchesMinLiquidity() public view {
        assertEq(presale.softCap(), 0.1 ether);
    }

    function test_RevertWhen_SoftCapBelowMinLiquidity() public {
        vm.expectRevert(SoftCapTooLow.selector);
        presale.setSoftCap(0.05 ether);
    }

    function test_SetSoftCapWithinPhaseOnly() public {
        presale.setSoftCap(0.6 ether);
        assertEq(presale.softCap(), 0.6 ether);

        presale.openPresale();
        vm.expectRevert(InvalidStatus.selector);
        presale.setSoftCap(2 ether); // 开售后条款冻结
    }

    // ---------------------------------------------------------------------------
    // 缴款账本
    // ---------------------------------------------------------------------------

    function test_ContributionsLedgerAccumulatesPerWallet() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        presale.openPresale();
        vm.startPrank(alice);
        presale.subscribe{value: 0.4 ether}();
        presale.subscribe{value: 0.25 ether}();
        vm.stopPrank();
        vm.prank(bob);
        presale.subscribe{value: 0.3 ether}();

        assertEq(presale.contributions(alice), 0.65 ether);
        assertEq(presale.contributions(bob), 0.3 ether);
        assertEq(presale.accumulatedBNB(), 0.95 ether);
        // 代币份额与缴款一一对应（价格 1e15）
        assertEq(presale.subscribedTokens(alice), (0.65 ether * 1e18) / 1e15);
    }

    // ---------------------------------------------------------------------------
    // 失败收官：状态、事件、全面封锁
    // ---------------------------------------------------------------------------

    function test_EndBelowSoftCap_FailsAndLocksEverything() public {
        address alice = address(0xA11CE);
        vm.deal(alice, 10 ether);

        presale.setSoftCap(2 ether);
        presale.openPresale();
        vm.prank(alice);
        presale.subscribe{value: 1 ether}();

        vm.expectEmit(false, false, false, true, address(presale));
        emit PresaleFailed(1 ether, 2 ether);
        presale.endPresale();

        assertEq(presale.presaleStatus(), presale.STATUS_FAILED());

        // 全功能封锁
        vm.expectRevert(InvalidStatus.selector);
        presale.openPresale();
        vm.expectRevert(PresaleNotOpen.selector);
        presale.subscribe{value: 0.1 ether}();
        vm.expectRevert(InvalidStatus.selector);
        presale.endPresale();
        vm.prank(alice);
        vm.expectRevert(NotLaunched.selector);
        presale.claim();
        vm.expectRevert(InvalidStatus.selector);
        presale.launch();
        vm.expectRevert(NotAfterLaunch.selector);
        presale.withdrawUnsoldTokens();
        vm.expectRevert(NotAfterLaunch.selector);
        presale.withdrawRemainingBNB();
        // 无缴款者退款为空
        vm.expectRevert(NothingToClaim.selector);
        presale.refund();
    }

    // ---------------------------------------------------------------------------
    // refund：精确金额、幂等
    // ---------------------------------------------------------------------------

    function test_RefundExactAmountsAndIdempotent() public {
        address alice = address(0xA11CE);
        address bob = address(0xB0B);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        presale.setSoftCap(2 ether);
        presale.openPresale();
        vm.startPrank(alice);
        presale.subscribe{value: 0.4 ether}();
        presale.subscribe{value: 0.35 ether}();
        vm.stopPrank();
        vm.prank(bob);
        presale.subscribe{value: 0.3 ether}();

        vm.expectEmit(false, false, false, true, address(presale));
        emit PresaleFailed(1.05 ether, 2 ether);
        presale.endPresale();

        uint256 before = alice.balance;
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(presale));
        emit Refunded(alice, 0.75 ether);
        presale.refund();
        assertEq(alice.balance, before + 0.75 ether);
        assertEq(presale.contributions(alice), 0);

        // 幂等防重领
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        presale.refund();
        // bob 记账不受影响
        assertEq(presale.contributions(bob), 0.3 ether);
    }

    // ---------------------------------------------------------------------------
    // reclaimTokens：代币全额回收、仅 Failed 态
    // ---------------------------------------------------------------------------

    function test_ReclaimTokensFullBalanceOnceAfterFailure() public {
        address alice = address(0xA11CE);
        vm.deal(alice, 10 ether);

        presale.setSoftCap(2 ether);
        presale.openPresale();
        vm.prank(alice);
        presale.subscribe{value: 1 ether}();
        presale.endPresale();
        assertEq(token.balanceOf(address(presale)), SUPPLY);

        uint256 before = token.balanceOf(address(this));
        presale.reclaimTokens();
        assertEq(token.balanceOf(address(this)), before + SUPPLY);
        assertEq(token.balanceOf(address(presale)), 0);

        vm.expectRevert(NoTokensToClaim.selector);
        presale.reclaimTokens();
    }

    function test_ReclaimBlockedBeforeFailureState() public {
        vm.expectRevert(InvalidStatus.selector);
        presale.reclaimTokens(); // 配置期即拦截（并非只在事后）
    }

    // ---------------------------------------------------------------------------
    // 开售后条款冻结
    // ---------------------------------------------------------------------------

    function test_ConfigFrozenOnceOpened() public {
        presale.openPresale();

        vm.expectRevert(InvalidStatus.selector);
        presale.configureLaunch(true, address(this), creatorShare, poolShare, presaleShare);
        vm.expectRevert(InvalidStatus.selector);
        presale.setPresaleTerms(1e15, presaleShare, 1e8 ether, 0, 0.1 ether, 0);
        vm.expectRevert(InvalidStatus.selector);
        presale.setVestingConfig(7 days, 10);
        vm.expectRevert(InvalidStatus.selector);
        presale.setSlippageProtection(500);
        vm.expectRevert(InvalidStatus.selector);
        presale.setConfigurator(address(0xBEEF));
    }

    // ---------------------------------------------------------------------------
    // 合约钱包 owner 的残留 BNB 提取（call 语义，无 2300 gas 卡点）
    // ---------------------------------------------------------------------------

    function test_WithdrawRemainingBNBGreedyContractWallet() public {
        GreedyReceiver greedy = new GreedyReceiver();

        PRESALE p = new PRESALE();
        greedy.initializePresale(p, address(router)); // owner = 高耗气合约钱包
        assertTrue(p.owner() == address(greedy));

        // 本用例专用新代币（setUp 实例的额度已注入默认托管仓，不可复用）
        FlapTaxTokenV3 t2 = _freshToken();

        bytes memory data =
            abi.encodeCall(PRESALE.configureLaunch, (true, address(greedy), creatorShare, poolShare, presaleShare));
        greedy.exec(address(p), data);
        data = abi.encodeCall(
            PRESALE.setPresaleTerms,
            (1e15, presaleShare, 1e8 ether, 0, 0.1 ether, 0) // price/caps/minLiq/start
        );
        greedy.exec(address(p), data);
        data = abi.encodeCall(PRESALE.setCoinAndPair, (address(t2), pair));
        greedy.exec(address(p), data);

        // 全量代币入仓 + 所有权移交托管仓
        t2.transfer(address(p), SUPPLY);
        t2.transferOwnership(address(p));

        data = abi.encodeCall(PRESALE.openPresale, ());
        greedy.exec(address(p), data);

        address alice = address(0xA11CE);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        p.subscribe{value: 0.2 ether}(); // ≥ 默认软顶 0.1

        data = abi.encodeCall(PRESALE.endPresale, ());
        greedy.exec(address(p), data);
        data = abi.encodeCall(PRESALE.launch, ());
        greedy.exec(address(p), data);

        // 直接注入残留 BNB 后提取：走 call 可送达高耗气接收方
        (bool ok,) = address(p).call{value: 0.02 ether}("");
        assertTrue(ok);
        data = abi.encodeCall(PRESALE.withdrawRemainingBNB, ());
        greedy.exec(address(p), data);
        assertEq(greedy.received(), 0.02 ether);
    }

    receive() external payable {}

    // ---------------------------------------------------------------------------
    // 夹具
    // ---------------------------------------------------------------------------

    function _freshToken() internal returns (FlapTaxTokenV3) {
        FlapTaxTokenV3 impl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        FlapTaxTokenV3 t = FlapTaxTokenV3(payable(_clone(address(impl))));

        address[] memory pools = new address[](1);
        pools[0] = pair;

        t.initialize(
            IFlapTaxTokenV3.InitParams({
                name: "TestToken",
                symbol: "TT",
                meta: "",
                buyTax: 300,
                sellTax: 500,
                taxProcessor: address(new DummyTaxProcessor()),
                dividendContract: address(0),
                quoteToken: address(router.weth()),
                liqExpectedOutputAmount: 0,
                taxDuration: 7 days,
                pools: pools,
                v2Router: address(router),
                antiFarmerDuration: 1 days
            })
        );
        return t;
    }

    /// @notice 盐值加入自增计数器，避免同测试内多次克隆撞 CREATE2 地址
    function _clone(address implementation) internal returns (address instance) {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, address(this), ++_cloneNonce));
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "clone failed");
    }
}
