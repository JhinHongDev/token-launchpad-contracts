// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {
    PRESALE,
    CreatorBuyTooLarge,
    ZeroCreatorBuyValue,
    CreatorBuyLocked,
    NothingToClaim,
    InvalidStatus
} from "src/Presale.sol";
import {CoordinatorFactory, CreatorBuyTokensWithoutFunding} from "src/CoordinatorFactory.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {PresaleFactory, PresaleConfig} from "src/PresaleFactory.sol";
import {MockRouterWithFactory, MockPairFactory, IERC20Lite, VanitySaltFinder} from "./TokenReservation.t.sol";

/// @title 创建者代币购买（Creator Buy）测试
/// @dev 核心链路：setupPresale{value} 注资 → 认购 → endPresale → launch 内
///      （加池后、税启动前的 Migrating 免税窗口）原子买入 → 代币即时到账 creator。
///      mock 汇率恒 20 万枚/BNB，精确断言即隐含验证免税（有税则到账必然少于换出额）。
contract CreatorBuyTest is Test {
    uint256 constant SUPPLY = 1e9 ether;
    uint256 constant POOL_SHARE = SUPPLY * 20 / 100; // 20% 底池份额 = 2 亿枚
    uint256 constant MAX_BUY = POOL_SHARE * 25 / 100; // poolShare × 25% = 5000 万枚上限

    // 结构性镜像合约事件，供 vm.expectEmit 按 topic 匹配
    event LaunchFinalized(uint256 bnbAmount, uint256 tokenAmount, uint256 timestamp);
    event CreatorBuyExecuted(uint256 bnbSpent, uint256 tokensBought);
    event CreatorBuyRefunded(address indexed to, uint256 amount);

    FlapTaxTokenV3 flapImpl;
    MockRouterWithFactory router;
    TokenFactory tokenFactory;
    PresaleFactory presaleFactory;
    CoordinatorFactory coordinator;

    address creator = address(0xdeadbeef);
    address alice = address(0x1234);
    address tokenAddr;
    PRESALE sale;

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

        bytes32 salt = _vanitySalt("creatorbuy-default");
        vm.prank(creator);
        coordinator.createToken{value: 1 ether}(_tokenConfig(), salt);

        // 缓存实例：vm.prank 会被下一次调用（含视图调用）消耗，
        // pranked 语句的参数里不可再嵌套外部调用
        tokenAddr = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        sale = PRESALE(payable(coordinator.getTokenPresale(tokenAddr)));
    }

    /// @dev 按标签派生种子搜索尾号 8888 盐
    function _vanitySalt(string memory tag) internal view returns (bytes32) {
        (bytes32 s, bool found) = VanitySaltFinder.find(
            address(tokenFactory), tokenFactory.flapImplementation(), uint256(keccak256(bytes(tag)))
        );
        assertTrue(found, "vanity salt should exist within budget");
        return s;
    }

    // -------------------------------------------------------------------------
    // 主路径
    // -------------------------------------------------------------------------

    function test_NoFunding_LaunchUnchanged() public {
        _runToPreLaunch(0, 0, 0.5 ether);

        // 不注资：launch 行为与历史一致；事件携带真实募集额（修复原实现恒发 0 的问题）
        vm.expectEmit(false, false, false, true, address(sale));
        emit LaunchFinalized(1 ether, POOL_SHARE, block.timestamp);
        _launch();

        assertEq(sale.creatorBuyBnb(), 0);
        assertEq(IERC20Lite(tokenAddr).balanceOf(creator), 0, "no bought tokens");
        assertEq(sale.presaleStatus(), 3);
    }

    function test_QuoteModeFullFlow() public {
        uint256 bnbBefore = creator.balance;
        _runToPreLaunch(0.1 ether, 0, 0.5 ether);

        vm.expectEmit(false, false, false, true, address(sale));
        emit CreatorBuyExecuted(0.1 ether, 2e4 ether);
        _launch();

        // 免税窗口买入：0.1 BNB × 20万/BNB 汇率 = 2 万枚，精确到账即证明无税
        assertEq(IERC20Lite(tokenAddr).balanceOf(creator), 2e4 ether);
        assertEq(creator.balance, bnbBefore - 0.1 ether, "spent exactly the funding");
        assertEq(sale.creatorBuyBnb(), 0);

        // 即时到账：开盘后立即可转账（不进 vesting）
        vm.prank(creator);
        IERC20Lite(tokenAddr).transfer(alice, 1e3 ether);
        assertEq(IERC20Lite(tokenAddr).balanceOf(alice), 1e3 ether);
    }

    function test_TokenModeExactAmountPlusRefund() public {
        uint256 bnbBefore = creator.balance;
        _runToPreLaunch(1 ether, 5e3 ether, 0.5 ether);

        // 目标 5000 枚：成本 0.025 BNB，注资 1 BNB，找零 0.975 BNB 自动退回
        vm.expectEmit(true, true, true, true, address(sale));
        emit CreatorBuyRefunded(creator, 0.975 ether);
        _launch();

        assertEq(IERC20Lite(tokenAddr).balanceOf(creator), 5e3 ether, "exact token amount");
        assertEq(creator.balance, bnbBefore - 0.025 ether, "only actual cost deducted");
        assertEq(sale.creatorBuyBnb(), 0);
    }

    // -------------------------------------------------------------------------
    // 上限与裁剪
    // -------------------------------------------------------------------------

    function test_QuoteModeCapPartialBuy() public {
        uint256 bnbBefore = creator.balance;
        _runToLaunch(1 ether, 0, 0.5 ether);

        // 上限 = 池 BNB × 2500/7500 = 1/3 BNB；超出部分退回
        uint256 poolBnb = 1 ether; // alice 认购额即加池 BNB
        uint256 maxSpend = (poolBnb * 2500) / 7500;
        uint256 expectedTokens = (maxSpend * router.swapRate()) / 1e18;
        assertEq(IERC20Lite(tokenAddr).balanceOf(creator), expectedTokens);
        assertEq(creator.balance, bnbBefore - maxSpend, "spend capped at poolBnb/3");
        assertEq(sale.creatorBuyBnb(), 0);
    }

    function test_RevertWhen_TargetExceedsCap() public {
        PresaleConfig memory cfg = _cfgWith(MAX_BUY + 1, 0.5 ether); // 5 万 + 1 wei
        uint256 val = 1 ether;
        vm.prank(creator);
        vm.expectRevert(CreatorBuyTooLarge.selector);
        coordinator.setupPresale{value: val}(tokenAddr, cfg);
    }

    function test_RevertWhen_TokensWithoutFunding() public {
        vm.prank(creator);
        vm.expectRevert(CreatorBuyTokensWithoutFunding.selector);
        coordinator.setupPresale(tokenAddr, _cfgWith(1e3 ether, 0.5 ether));
    }

    // -------------------------------------------------------------------------
    // 失败兜底：退币且开盘继续
    // -------------------------------------------------------------------------

    function test_SwapFailureRefundsAndLaunchProceeds() public {
        router.setFailSwap(true);
        uint256 bnbBefore = creator.balance;
        _runToPreLaunch(0.1 ether, 0, 0.5 ether);

        vm.expectEmit(true, true, true, true, address(sale));
        emit CreatorBuyRefunded(creator, 0.1 ether);
        _launch();

        assertEq(sale.presaleStatus(), 3, "launch not blocked");
        assertEq(IERC20Lite(tokenAddr).balanceOf(creator), 0);
        assertEq(creator.balance, bnbBefore, "full refund");
    }

    function test_TokenModeInsufficientFundingRefunds() public {
        // 目标 5000 枚成本 0.025 BNB，仅注资 0.01 → swap 失败 → 全额退币开盘继续
        uint256 bnbBefore = creator.balance;
        _runToLaunch(0.01 ether, 5e3 ether, 0.5 ether);

        assertEq(sale.presaleStatus(), 3);
        assertEq(IERC20Lite(tokenAddr).balanceOf(creator), 0);
        assertEq(creator.balance, bnbBefore, "full refund");
    }

    // -------------------------------------------------------------------------
    // 注资管理：更新 / 撤回 / FAILED 退出
    // -------------------------------------------------------------------------

    function test_FundingViaCoordinatorReachesPresale() public {
        vm.prank(creator);
        coordinator.setupPresale{value: 0.3 ether}(tokenAddr, _cfgWith(1e3 ether, 0.5 ether));

        assertEq(sale.creatorBuyBnb(), 0.3 ether);
        assertEq(sale.creatorBuyTokens(), 1e3 ether);
    }

    function test_RefundPreviousOnRefund() public {
        vm.prank(creator);
        coordinator.setupPresale{value: 0.1 ether}(tokenAddr, _cfgWith(0, 0.5 ether));

        uint256 bnbBefore = creator.balance;
        vm.prank(creator);
        sale.fundCreatorBuy{value: 0.2 ether}(0);

        assertEq(creator.balance, bnbBefore - 0.2 ether + 0.1 ether, "old funding refunded");
        assertEq(sale.creatorBuyBnb(), 0.2 ether);
        assertEq(sale.creatorBuyTokens(), 0);
    }

    function test_WithdrawBeforeLaunch() public {
        vm.prank(creator);
        coordinator.setupPresale{value: 0.1 ether}(tokenAddr, _cfgWith(2e3 ether, 0.5 ether));

        uint256 bnbBefore = creator.balance;
        vm.prank(creator);
        sale.withdrawCreatorBuy();

        assertEq(creator.balance, bnbBefore + 0.1 ether);
        assertEq(sale.creatorBuyBnb(), 0);
        assertEq(sale.creatorBuyTokens(), 0);

        // 撤回后照常开盘（无注资路径）
        _launchFlow();
        _launch();
        assertEq(sale.presaleStatus(), 3);
        assertEq(IERC20Lite(tokenAddr).balanceOf(creator), 0);
    }

    function test_RevertWhen_WithdrawNothing() public {
        vm.expectRevert(NothingToClaim.selector);
        vm.prank(creator);
        sale.withdrawCreatorBuy();
    }

    function test_RevertWhen_LockedAfterLaunch() public {
        _runToLaunch(0.1 ether, 0, 0.5 ether);

        uint256 val = 0.1 ether;
        vm.prank(creator);
        vm.expectRevert(CreatorBuyLocked.selector);
        sale.fundCreatorBuy{value: val}(0);

        vm.prank(creator);
        vm.expectRevert(CreatorBuyLocked.selector);
        sale.withdrawCreatorBuy();
    }

    function test_FailedPresaleCreatorWithdrawPlusSubscriberRefund() public {
        vm.prank(creator);
        coordinator.setupPresale{value: 0.1 ether}(tokenAddr, _cfgWith(0, 5 ether)); // 软顶抬高制造失败

        vm.prank(creator);
        sale.openPresale();
        vm.prank(alice);
        sale.subscribe{value: 1 ether}();
        vm.prank(creator);
        sale.endPresale();
        assertEq(sale.presaleStatus(), sale.STATUS_FAILED());

        // 散户退认购款 + 创建者退购买注资，互不干扰
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        sale.refund();
        assertEq(alice.balance, aliceBefore + 1 ether);

        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        sale.withdrawCreatorBuy();
        assertEq(creator.balance, creatorBefore + 0.1 ether);
    }

    // -------------------------------------------------------------------------
    // 权限
    // -------------------------------------------------------------------------

    function test_RevertWhen_UnauthorizedFunder() public {
        vm.prank(creator);
        coordinator.setupPresale{value: 0.1 ether}(tokenAddr, _cfgWith(0, 0.5 ether));

        address attacker = address(0xBAD);
        vm.deal(attacker, 1 ether);
        uint256 val = 0.1 ether;
        vm.prank(attacker);
        vm.expectRevert(InvalidStatus.selector); // onlyOwnerOrConfigurator
        sale.fundCreatorBuy{value: val}(0);

        vm.prank(attacker);
        vm.expectRevert(); // onlyOwner（OZ Ownable 错误）
        sale.withdrawCreatorBuy();
    }

    function test_RevertWhen_ZeroValueFunding() public {
        uint256 val = 0;
        vm.prank(creator);
        vm.expectRevert(ZeroCreatorBuyValue.selector);
        sale.fundCreatorBuy{value: val}(0);
    }

    // -------------------------------------------------------------------------
    // 夹具与流程
    // -------------------------------------------------------------------------

    function _tokenConfig() internal view returns (TokenConfig memory) {
        return TokenConfig({
            name: "TeamToken",
            symbol: "TT",
            meta: "ipfs://QmTestMeta",
            buyTax: 300,
            sellTax: 500,
            feeRecipient: address(0xfee1),
            taxDuration: 7 days,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0
        });
    }

    function _presaleConfig(uint256 softCap) internal pure returns (PresaleConfig memory) {
        return PresaleConfig({
            presaleTokenPrice: 1e15,
            maxBuyPerWallet: 1e5 ether,
            hardcap: 0,
            minLiquidityAmount: 0.1 ether,
            softCap: softCap,
            startTime: 0,
            vestingDelay: 7 days,
            vestingRate: 10,
            slippage: 0,
            creatorBuyTokens: 0
        });
    }

    function _cfgWith(uint256 target, uint256 softCap) internal pure returns (PresaleConfig memory) {
        PresaleConfig memory cfg = _presaleConfig(softCap);
        cfg.creatorBuyTokens = target;
        return cfg;
    }

    /// @dev 标准全流程：注资 setupPresale → 认购 1 BNB → 收官 → 开盘
    function _runToLaunch(uint256 fundValue, uint256 target, uint256 softCap) internal {
        _runToPreLaunch(fundValue, target, softCap);
        _launch();
    }

    /// @dev 从零跑到"待开盘"（status 2）：事件断言需紧贴 launch 调用，故在此拆断
    function _runToPreLaunch(uint256 fundValue, uint256 target, uint256 softCap) internal {
        vm.prank(creator);
        if (fundValue > 0) {
            coordinator.setupPresale{value: fundValue}(tokenAddr, _cfgWith(target, softCap));
        } else {
            coordinator.setupPresale(tokenAddr, _cfgWith(target, softCap));
        }
        _launchFlow();
    }

    /// @dev 从"已 setupPresale"状态跑到开盘（开认购 → 认购 1 BNB → 收官 → 待开盘；
    ///      token 所有权已由 createToken 交托管仓，launch 直接可编排）
    function _launchFlow() internal {
        vm.prank(creator);
        sale.openPresale();
        vm.prank(alice);
        sale.subscribe{value: 1 ether}();
        vm.prank(creator);
        sale.endPresale(); // 停在待开盘（status 2），launch 由调用方显式触发以贴近事件断言
    }

    function _launch() internal {
        vm.prank(creator);
        sale.launch();
    }
}
