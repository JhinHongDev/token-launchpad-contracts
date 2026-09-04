// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {PRESALE, SoftCapExceedsHardcap, InvalidStatus} from "src/Presale.sol";
import {CoordinatorFactory, InvalidAllocation} from "src/CoordinatorFactory.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {PresaleFactory, PresaleConfig} from "src/PresaleFactory.sol";
import {MockRouterWithFactory, MockPairFactory, IERC20Lite, VanitySaltFinder} from "./TokenReservation.t.sol";

/// @title 管理员可配置分配比例 + softCap ≤ hardcap 校验测试
/// @dev 覆盖面：
///      1) 默认 30/20/50 行为不变（回归保障）
///      2) 管理员调整比例：getter/事件/新币生效/极端 bps（wei 级余数兜底）
///      3) 旧币隔离：比例在 setupPresale 时刻冻结，后续调整不追溯
///      4) 新比例端到端：认购 → launch 加池 → vesting claim 全链路
///      5) 配置校验：单项为 0 / 和 ≠ 10000 / 非管理员 一律 revert
///      6) softCap ≤ hardcap：死组合拦截 / 等值合法 / hardcap=0 不限
contract AllocationAdminTest is Test {
    uint256 constant SUPPLY = 1e9 ether;

    FlapTaxTokenV3 flapImpl;
    MockRouterWithFactory router;
    TokenFactory tokenFactory;
    PresaleFactory presaleFactory;
    CoordinatorFactory coordinator;

    address creator = address(0xC7EA);
    address alice = address(0xA11CE);
    address tokenA;
    PRESALE saleA;

    // 结构性镜像合约事件，供 vm.expectEmit 按 topic 匹配
    event AllocationUpdated(uint256 creatorBps, uint256 poolBps, uint256 presaleBps);
    event PresaleSetup(
        address indexed token, address indexed presale, uint256 creatorShare, uint256 poolShare, uint256 presaleShare
    );

    function setUp() public {
        flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        MockPairFactory pairFactory = new MockPairFactory();
        router = new MockRouterWithFactory(address(0xAABB), pairFactory);

        tokenFactory = new TokenFactory(address(flapImpl), address(router), address(0));
        PRESALE template = new PRESALE();
        presaleFactory = new PresaleFactory(address(template), address(0));
        coordinator = new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));

        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        vm.deal(creator, 100 ether);
        vm.deal(alice, 10 ether);

        // 币A：默认比例（30/20/50）配置的基准币
        tokenA = _createToken();
        saleA = PRESALE(payable(coordinator.getTokenPresale(tokenA)));
        vm.prank(creator);
        coordinator.setupPresale(tokenA, _cfg(0.5 ether, 0));
    }

    // ---------------------------------------------------------------------------
    // 默认行为（回归保障：不调 setter 时与历史版本完全一致）
    // ---------------------------------------------------------------------------

    function test_DefaultAllocationIs30_20_50() public view {
        assertEq(coordinator.creatorBps(), 3000);
        assertEq(coordinator.poolBps(), 2000);
        assertEq(coordinator.presaleBps(), 5000);
    }

    function test_DefaultSharesWrittenToPresale() public view {
        assertEq(saleA.creatorShare(), SUPPLY * 3000 / 10_000, "creator 30%");
        assertEq(saleA.poolShare(), SUPPLY * 2000 / 10_000, "pool 20%");
        assertEq(saleA.presaleShare(), SUPPLY * 5000 / 10_000, "presale 50%");
        assertEq(saleA.maxPresaleTokens(), SUPPLY * 5000 / 10_000, "max presale = presale share");
    }

    // ---------------------------------------------------------------------------
    // 管理员调整比例
    // ---------------------------------------------------------------------------

    function test_SetAllocationUpdatesAndGetters() public {
        vm.expectEmit(false, false, false, true, address(coordinator));
        emit AllocationUpdated(4000, 2000, 4000);
        coordinator.setAllocation(4000, 2000, 4000);

        assertEq(coordinator.creatorBps(), 4000);
        assertEq(coordinator.poolBps(), 2000);
        assertEq(coordinator.presaleBps(), 4000);
    }

    function test_NewAllocationAppliesToNewTokens() public {
        coordinator.setAllocation(4000, 2000, 4000);

        address tokenB = _createToken();
        PRESALE saleB = PRESALE(payable(coordinator.getTokenPresale(tokenB)));

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit PresaleSetup(
            tokenB, address(saleB), SUPPLY * 4000 / 10_000, SUPPLY * 2000 / 10_000, SUPPLY * 4000 / 10_000
        );
        vm.prank(creator);
        coordinator.setupPresale(tokenB, _cfg(0.5 ether, 0));

        assertEq(saleB.creatorShare(), SUPPLY * 4000 / 10_000, "creator 40%");
        assertEq(saleB.poolShare(), SUPPLY * 2000 / 10_000, "pool 20%");
        assertEq(saleB.presaleShare(), SUPPLY * 4000 / 10_000, "presale 40%");
        assertEq(saleB.maxPresaleTokens(), SUPPLY * 4000 / 10_000, "max presale follows new share");
    }

    function test_ExtremeBpsValidWithRemainderSafety() public {
        // 9990/5/5：合法极端组合；supply=1e27 整除 10^4，三份额精确无残差
        coordinator.setAllocation(9990, 5, 5);

        address tokenB = _createToken();
        PRESALE saleB = PRESALE(payable(coordinator.getTokenPresale(tokenB)));
        vm.prank(creator);
        coordinator.setupPresale(tokenB, _cfg(0.5 ether, 0));

        uint256 creatorShare = SUPPLY * 9990 / 10_000;
        uint256 poolShare = SUPPLY * 5 / 10_000;
        assertEq(saleB.creatorShare(), creatorShare);
        assertEq(saleB.poolShare(), poolShare);
        // 余数兜底写法：三份额之和恒等于 supply，杜绝任何死锁残留
        assertEq(saleB.creatorShare() + saleB.poolShare() + saleB.presaleShare(), SUPPLY, "shares always sum to supply");
    }

    // ---------------------------------------------------------------------------
    // 旧币隔离：份额在 setupPresale 时刻冻结
    // ---------------------------------------------------------------------------

    function test_OldTokenKeepsFrozenShares() public {
        coordinator.setAllocation(4000, 2000, 4000);

        // 币A 仍保持配置时刻的 30/20/50
        assertEq(saleA.creatorShare(), SUPPLY * 3000 / 10_000, "frozen creator share");
        assertEq(saleA.poolShare(), SUPPLY * 2000 / 10_000, "frozen pool share");
        assertEq(saleA.presaleShare(), SUPPLY * 5000 / 10_000, "frozen presale share");
    }

    // ---------------------------------------------------------------------------
    // 新比例端到端：认购 → launch 加池 → vesting claim
    // ---------------------------------------------------------------------------

    function test_NewAllocationEndToEndLaunch() public {
        coordinator.setAllocation(4000, 2000, 4000);

        address tokenB = _createToken();
        PRESALE saleB = PRESALE(payable(coordinator.getTokenPresale(tokenB)));
        vm.prank(creator);
        coordinator.setupPresale(tokenB, _cfg(0.5 ether, 0));

        // 认购 1 BNB → 达软顶 → 开盘
        vm.prank(creator);
        saleB.openPresale();
        vm.prank(alice);
        saleB.subscribe{value: 1 ether}();
        vm.prank(creator);
        saleB.endPresale();
        vm.prank(creator);
        saleB.launch();

        assertEq(saleB.presaleStatus(), 3);
        assertEq(saleB.liquidityAdded(), true);
        // 加池量 = 新 poolShare（20%），MockRouter 持仓即加池凭证
        assertEq(IERC20Lite(tokenB).balanceOf(address(router)), SUPPLY * 2000 / 10_000, "pool 20% added");

        // 一个周期后创建者按新 creatorShare（40%）领取首期 10%
        skip(7 days);
        vm.prank(creator);
        saleB.claim();
        assertEq(saleB.claimedTokens(creator), SUPPLY * 4000 / 10_000 * 10 / 100, "first period 10% of 40%");
    }

    // ---------------------------------------------------------------------------
    // 配置校验：非法组合一律拦截
    // ---------------------------------------------------------------------------

    function test_RevertWhen_AnyBpsZero() public {
        vm.expectRevert(InvalidAllocation.selector);
        coordinator.setAllocation(0, 2000, 8000);

        vm.expectRevert(InvalidAllocation.selector);
        coordinator.setAllocation(3000, 0, 7000);

        vm.expectRevert(InvalidAllocation.selector);
        coordinator.setAllocation(3000, 2000, 0);
    }

    function test_RevertWhen_SumNot10000() public {
        vm.expectRevert(InvalidAllocation.selector);
        coordinator.setAllocation(3000, 2000, 4999); // 9999

        vm.expectRevert(InvalidAllocation.selector);
        coordinator.setAllocation(3000, 2000, 5001); // 10001
    }

    function test_RevertWhen_NotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(); // AccessControl string revert（OZ 4.9.3）
        coordinator.setAllocation(4000, 2000, 4000);

        // 管理员参数未被污染
        assertEq(coordinator.creatorBps(), 3000);
    }

    // ---------------------------------------------------------------------------
    // softCap ≤ hardcap：注定失败的死组合在源头拦截
    // ---------------------------------------------------------------------------

    function test_RevertWhen_SoftCapExceedsHardcap() public {
        address tokenB = _createToken();
        vm.prank(creator);
        vm.expectRevert(SoftCapExceedsHardcap.selector);
        coordinator.setupPresale(tokenB, _cfg(1 ether, 0.5 ether)); // softCap > hardcap
    }

    function test_RevertWhen_SoftCapExceedsHardcapByOneWei() public {
        address tokenB = _createToken();
        vm.prank(creator);
        vm.expectRevert(SoftCapExceedsHardcap.selector);
        coordinator.setupPresale(tokenB, _cfg(0.5 ether + 1, 0.5 ether)); // 1 wei 越界也算
    }

    function test_SoftCapEqualsHardcap_LaunchOK() public {
        address tokenB = _createToken();
        PRESALE saleB = PRESALE(payable(coordinator.getTokenPresale(tokenB)));
        vm.prank(creator);
        coordinator.setupPresale(tokenB, _cfg(0.5 ether, 0.5 ether)); // 等值：合法

        // 走通完整生命周期（认购恰好达双顶 → 同笔自动结算进 2 → 开盘）
        vm.prank(creator);
        saleB.openPresale();
        vm.prank(alice);
        saleB.subscribe{value: 0.5 ether}();
        assertEq(saleB.presaleStatus(), 2, "reached both caps auto-settled");
        vm.prank(creator);
        vm.expectRevert(InvalidStatus.selector); // 状态 2 下 endPresale 已不可再调
        saleB.endPresale();
        vm.prank(creator);
        saleB.launch();
        assertEq(saleB.presaleStatus(), 3);
    }

    function test_SoftCapUnlimitedWhenHardcapZero() public {
        address tokenB = _createToken();
        PRESALE saleB = PRESALE(payable(coordinator.getTokenPresale(tokenB)));
        // hardcap = 0（不限）时任意 softCap 合法——币A 的配置就是该组合
        vm.prank(creator);
        coordinator.setupPresale(tokenB, _cfg(50 ether, 0));

        assertEq(saleB.softCap(), 50 ether);
        assertEq(saleB.hardcap(), 0);
    }

    // ---------------------------------------------------------------------------
    // 夹具
    // ---------------------------------------------------------------------------

    uint256 private _saltSeq;

    function _createToken() internal returns (address token) {
        // 序号派生标签保证每次新盐：同标签会同盐，同测试内二创必撞 CloneFailed（EIP-684）；
        // 搜盐在 prank 之前完成（内部含外部调用，prank 后调用会被吞，见 TokenReservation.t 套路约束）
        bytes32 salt = _vanitySalt(string.concat("alloc-", vm.toString(_saltSeq++)));
        vm.prank(creator);
        (token,) = coordinator.createToken{value: 1 ether}(_tokenConfig(), salt);
    }

    /// @dev 按标签派生种子搜索尾号 8888 盐
    function _vanitySalt(string memory tag) internal view returns (bytes32) {
        (bytes32 s, bool found) = VanitySaltFinder.find(
            address(tokenFactory), tokenFactory.flapImplementation(), uint256(keccak256(bytes(tag)))
        );
        assertTrue(found, "vanity salt should exist within budget");
        return s;
    }

    function _tokenConfig() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            name: "AllocationTest",
            symbol: "ALC",
            meta: "ipfs://QmAllocTest",
            buyTax: 300,
            sellTax: 500,
            feeRecipient: address(0xfee1),
            taxDuration: 7 days,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0
        });
    }

    /// @param softCap 认购成功线
    /// @param hardcap 募资硬顶（0 = 不限）
    function _cfg(uint256 softCap, uint256 hardcap) internal pure returns (PresaleConfig memory) {
        return PresaleConfig({
            presaleTokenPrice: 1e15,
            maxBuyPerWallet: 1e5 ether,
            hardcap: hardcap,
            minLiquidityAmount: 0.1 ether,
            softCap: softCap,
            startTime: 0,
            duration: 30 days,
            vestingDelay: 7 days,
            vestingRate: 10,
            slippage: 0,
            creatorBuyTokens: 0
        });
    }
}
