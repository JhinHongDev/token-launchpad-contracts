// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {PRESALE, PresaleSoldOut, NothingToClaim, InvalidStatus, ZeroMinLiquidity} from "src/Presale.sol";
import {
    CoordinatorFactory,
    NotTokenCreator,
    InvalidMaxBuyPerWallet,
    AlreadyConfigured
} from "src/CoordinatorFactory.sol";
import {TokenFactory, TokenConfig, BuyFeeTooHigh, SellFeeTooHigh} from "src/TokenFactory.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {PackedFeeConfig} from "src/lib/interfaces/ITaxProcessor.sol";
import {PresaleFactory, PresaleConfig} from "src/PresaleFactory.sol";

contract MockPairFactory {
    address public pair;

    function createPair(address, address) external returns (address) {
        return pair;
    }
}

contract MockRouterWithFactory {
    address public weth;
    MockPairFactory public pairFactory;

    constructor(address _weth, MockPairFactory _f) {
        weth = _weth;
        pairFactory = _f;
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function factory() external view returns (address) {
        return address(pairFactory);
    }

    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address to, uint256)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        IERC20Lite(token).transferFrom(msg.sender, to, amountTokenDesired);
        return (amountTokenDesired, msg.value, 1e18);
    }
}

interface IERC20Lite {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract CoordinatorTest is Test {
    uint256 constant SUPPLY = 1e9 ether;

    // 结构性镜像合约事件，供 vm.expectEmit 按 topic 匹配
    event PresaleFailed(uint256 raisedBNB, uint256 softCap);

    FlapTaxTokenV3 flapImpl;
    MockRouterWithFactory router;
    MockPairFactory pairFactory;
    TokenFactory tokenFactory;
    PresaleFactory presaleFactory;
    CoordinatorFactory coordinator;

    address creator = address(0xdeadbeef);
    address feeReceiver = address(0xfee1);

    function setUp() public {
        flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        pairFactory = new MockPairFactory();
        pairFactory.pair();
        router = new MockRouterWithFactory(address(0xAABB), pairFactory);

        tokenFactory = new TokenFactory(address(flapImpl), address(router), address(0));
        PRESALE template = new PRESALE();
        presaleFactory = new PresaleFactory(address(template), address(0));
        coordinator = new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));

        // 测试合约是工厂 admin，直接授予 Coordinator 角色
        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        vm.deal(creator, 100 ether);
        vm.prank(creator);
        coordinator.createToken{value: 1 ether}(_tokenConfig(), bytes32(0));
    }

    function test_CreateTokenOnlyNoPresaleSetup() public {
        // createToken 后：代币在托管仓、token 所有权在托管仓（迁移编排前提）、预售未配置
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address presale = coordinator.getTokenPresale(token);
        assertTrue(presale != address(0));

        assertEq(IERC20Lite(token).balanceOf(presale), SUPPLY);
        assertEq(FlapTaxTokenV3(token).owner(), presale); // token owner = 托管仓
        assertEq(PRESALE(payable(presale)).creator(), address(0)); // 未配置预售
        (bool enabled,,,,,) = PRESALE(payable(presale)).getLaunchStatus();
        assertEq(enabled, false);
        assertEq(PRESALE(payable(presale)).presaleStatus(), 0);
    }

    /// @dev 纯发币模式端到端：createToken（不 setupPresale）→ claimAllTokens 领取即上线
    function test_NoPresaleClaimMigratesAndUnlocks() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address presale = coordinator.getTokenPresale(token);
        PRESALE p = PRESALE(payable(presale));

        vm.prank(creator);
        p.claimAllTokens();

        // 一笔交易内：迁移三步 + renounce + 全量代币发放全部完成
        assertEq(uint8(FlapTaxTokenV3(token).state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer));
        assertEq(FlapTaxTokenV3(token).owner(), address(0)); // token 所有权已放弃
        assertTrue(p.tokensClaimed());
        assertEq(IERC20Lite(token).balanceOf(presale), 0); // 托管仓清空
        assertEq(IERC20Lite(token).balanceOf(creator), SUPPLY); // 创建者持有全量
    }

    function test_SetupPresaleThenFullFlow() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address presale = coordinator.getTokenPresale(token);

        PresaleConfig memory cfg = _presaleConfig();

        vm.prank(creator);
        coordinator.setupPresale(token, cfg);

        // token 所有权在 createToken 时已交托管仓（供 launch 编排）
        assertEq(FlapTaxTokenV3(token).owner(), presale);
        assertEq(PRESALE(payable(presale)).presaleEnabled(), true);

        // 认购 → 开盘 → 领取 全链跑通
        address alice = address(0x1234);
        vm.deal(alice, 10 ether);

        vm.prank(creator);
        PRESALE(payable(presale)).openPresale();
        vm.prank(alice);
        PRESALE(payable(presale)).subscribe{value: 1 ether}();

        vm.prank(creator);
        PRESALE(payable(presale)).endPresale();

        vm.prank(creator);
        PRESALE(payable(presale)).launch();

        assertEq(uint8(FlapTaxTokenV3(token).state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer));
        assertEq(FlapTaxTokenV3(token).owner(), address(0)); // 已 renounce

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(alice);
        PRESALE(payable(presale)).claim();
        assertEq(IERC20Lite(token).balanceOf(alice), 100 ether);
    }

    function test_SetupPresaleFixedShares() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address presale = coordinator.getTokenPresale(token);

        vm.prank(creator);
        coordinator.setupPresale(token, _presaleConfig());

        // 份额合约写死：30% 创建者 / 20% 底池 / 50% 预售
        assertEq(PRESALE(payable(presale)).creatorShare(), SUPPLY * 30 / 100);
        assertEq(PRESALE(payable(presale)).poolShare(), SUPPLY * 20 / 100);
        assertEq(PRESALE(payable(presale)).presaleShare(), SUPPLY * 50 / 100);
    }

    function test_SaleLimitCappedAtPresaleShare() public {
        // 防护：认购上限恒等于 50% 份额，无法售出超范围代币
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address presale = coordinator.getTokenPresale(token);

        vm.prank(creator);
        coordinator.setupPresale(token, _presaleConfig());
        assertEq(PRESALE(payable(presale)).maxPresaleTokens(), SUPPLY * 50 / 100);

        vm.prank(creator);
        PRESALE(payable(presale)).openPresale();

        // 直接一次性买满 50% + 1 枚 → 超上限 revert
        address whale = address(0x9f9f);
        uint256 overflow = SUPPLY * 50 / 100 + 1e18;
        uint256 bnbNeeded = (overflow * 1e15) / 1e18; // price = 1e15 BNB/token
        vm.deal(whale, bnbNeeded);
        vm.prank(whale);
        vm.expectRevert(PresaleSoldOut.selector);
        PRESALE(payable(presale)).subscribe{value: bnbNeeded}();
    }

    function test_SetupPresaleOnlyCreator() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;

        vm.expectRevert(NotTokenCreator.selector);
        coordinator.setupPresale(token, _presaleConfig()); // 非创建者调用
    }

    function test_RevertWhen_DuplicateSetupPresale() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        PresaleConfig memory cfg = _presaleConfig();

        vm.prank(creator);
        coordinator.setupPresale(token, cfg);

        vm.prank(creator);
        vm.expectRevert(AlreadyConfigured.selector);
        coordinator.setupPresale(token, cfg); // 条款一次性配置
    }

    /// @notice 失败发行闭环：未达软顶收官 → 散户精确退款 → 创建者回收代币
    function test_FailedSale_RefundAndReclaimClosedLoop() public {
        address tok = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address sale = coordinator.getTokenPresale(tok);

        PresaleConfig memory cfg = _presaleConfig();
        cfg.softCap = 5 ether; // 高于常规募集量，制造失败场景

        vm.startPrank(creator);
        coordinator.setupPresale(tok, cfg);
        PRESALE(payable(sale)).openPresale();
        vm.stopPrank();

        address alice = address(0x1234);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        PRESALE(payable(sale)).subscribe{value: 1 ether}();

        vm.expectEmit(false, false, false, true, sale);
        emit PresaleFailed(1 ether, 5 ether);
        vm.prank(creator);
        PRESALE(payable(sale)).endPresale();
        assertEq(PRESALE(payable(sale)).presaleStatus(), PRESALE(payable(sale)).STATUS_FAILED());

        // 失败态封锁开盘
        vm.prank(creator);
        vm.expectRevert(InvalidStatus.selector);
        PRESALE(payable(sale)).launch();

        // 散户精确退款、幂等防重领
        uint256 before = alice.balance;
        vm.prank(alice);
        PRESALE(payable(sale)).refund();
        assertEq(alice.balance, before + 1 ether);
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        PRESALE(payable(sale)).refund();

        // 创建者回收托管代币（散户从未取得过代币）
        vm.prank(creator);
        PRESALE(payable(sale)).reclaimTokens();
        assertEq(IERC20Lite(tok).balanceOf(sale), 0);
        assertEq(IERC20Lite(tok).balanceOf(creator), SUPPLY);
    }

    // ---------------------------------------------------------------------------
    // 新增：单通道税金接线 / 退款 / 税率上限 / maxBuy 校验
    // ---------------------------------------------------------------------------

    function test_RefundsExcessCreationFee() public {
        uint256 balanceBefore = creator.balance;
        vm.prank(creator);
        coordinator.createToken{value: 1 ether}(_tokenConfig(), bytes32(0));
        // 仅扣 0.005 创建费，多付全额退还
        assertEq(creator.balance, balanceBefore - 0.005 ether);
    }

    function test_TaxProcessorSingleReceiverWiring() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address processor = FlapTaxTokenV3(token).taxProcessor();

        // 唯一收款人接线：feeRecipient（发币时固定，运行期不可变）
        assertEq(TaxProcessor(payable(processor)).feeReceiver(), feeReceiver);
        assertEq(TaxProcessor(payable(processor)).taxToken(), token);
        assertEq(TaxProcessor(payable(processor)).router(), address(router));
        assertEq(TaxProcessor(payable(processor)).getQuoteToken(), address(0xAABB)); // WBNB

        // 单通道：无 Dividend、无四通道配置
        assertEq(TaxProcessor(payable(processor)).dividendAddress(), address(0));
        assertEq(FlapTaxTokenV3(token).dividendContract(), address(0));
        PackedFeeConfig memory cfg = TaxProcessor(payable(processor)).feeConfig();
        assertEq(cfg.marketBps, 0);
        assertEq(cfg.deflationBps, 0);
        assertEq(cfg.lpBps, 0);
        assertEq(cfg.dividendBps, 0);
        assertEq(cfg.feeRate, 0);

        // meta 元数据已透传
        assertEq(FlapTaxTokenV3(token).metaURI(), "ipfs://QmTestMeta");
    }

    function test_RevertWhen_TaxAboveTenPercent() public {
        TokenConfig memory cfg = _tokenConfig();
        cfg.buyTax = 1001; // > 10%
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(BuyFeeTooHigh.selector);
        coordinator.createToken{value: 1 ether}(cfg, bytes32(0));

        TokenConfig memory cfg2 = _tokenConfig();
        cfg2.sellTax = 1001;
        vm.prank(creator);
        vm.expectRevert(SellFeeTooHigh.selector);
        coordinator.createToken{value: 1 ether}(cfg2, bytes32(0));
    }

    function test_ZeroAntiFarmerDurationAllowed() public {
        TokenConfig memory cfg = _tokenConfig();
        cfg.antiFarmerDuration = 0; // 支持用户不设防夹期
        vm.prank(creator);
        (address token,) = coordinator.createToken{value: 1 ether}(cfg, bytes32(0));
        assertEq(FlapTaxTokenV3(token).antiFarmerDuration(), 0);
    }

    function test_RevertWhen_MaxBuyPerWalletZero() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        PresaleConfig memory cfg = _presaleConfig();
        cfg.maxBuyPerWallet = 0;
        vm.prank(creator);
        vm.expectRevert(InvalidMaxBuyPerWallet.selector);
        coordinator.setupPresale(token, cfg);
    }

    /// @dev 回归：minLiquidityAmount=0 且 softCap=0 的双 0 组合 = status 2 死角
    ///      （endPresale 必"达标"、launch 加池 0 BNB 恒 revert、状态 2 无退款通道），
    ///      编排层前置拦截，发币表单事故在 setupPresale 提交时即报错
    function test_RevertWhen_SetupPresaleWithZeroMinLiquidity() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        PresaleConfig memory cfg = _presaleConfig();
        cfg.minLiquidityAmount = 0;
        cfg.softCap = 0; // 双 0 死角组合
        vm.prank(creator);
        vm.expectRevert(ZeroMinLiquidity.selector);
        coordinator.setupPresale(token, cfg);
    }

    /// @dev 回归变体：minLiquidityAmount=0、softCap>0 同样拦截（setSoftCap 的 softCap >= 0 恒真，
    ///      0 值加池下限本身就是非法配置；归一规则 = 加池下限必须为正）
    function test_RevertWhen_SetupPresaleWithZeroMinLiquidityNonzeroSoftCap() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        PresaleConfig memory cfg = _presaleConfig();
        cfg.minLiquidityAmount = 0; // softCap 保持 0.5 ether
        vm.prank(creator);
        vm.expectRevert(ZeroMinLiquidity.selector);
        coordinator.setupPresale(token, cfg);
    }

    function _tokenConfig() internal view returns (TokenConfig memory) {
        return TokenConfig({
            name: "TeamToken",
            symbol: "TT",
            meta: "ipfs://QmTestMeta",
            buyTax: 300,
            sellTax: 500,
            feeRecipient: feeReceiver,
            taxDuration: 7 days,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0
        });
    }

    function _presaleConfig() internal view returns (PresaleConfig memory) {
        return PresaleConfig({
            presaleTokenPrice: 1e15,
            maxBuyPerWallet: 1e8 ether,
            hardcap: 0,
            minLiquidityAmount: 0.1 ether,
            softCap: 0.5 ether, // 常规路径募集 1 BNB > 软顶；失败路径用例会单独抬高
            startTime: 0,
            vestingDelay: 7 days,
            vestingRate: 10,
            slippage: 0,
            creatorBuyTokens: 0
        });
    }
}
