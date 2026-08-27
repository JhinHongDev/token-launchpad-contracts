// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {PRESALE, PresaleSoldOut} from "src/Presale.sol";
import {
    CoordinatorFactory,
    NotTokenCreator,
    InvalidAllocationBps,
    InvalidMaxBuyPerWallet
} from "src/CoordinatorFactory.sol";
import {TokenFactory, TokenConfig, BuyFeeTooHigh, SellFeeTooHigh} from "src/TokenFactory.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {PackedFeeConfig} from "src/lib/interfaces/ITaxProcessor.sol";
import {PresaleFactory, PresaleConfig} from "src/PresaleFactory.sol";
import {Clones} from "src/Clones.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";

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

        Dividend dividendImpl = new Dividend(address(0xAABB), address(0xdead));
        tokenFactory = new TokenFactory(address(flapImpl), address(router), address(0));
        PRESALE template = new PRESALE();
        presaleFactory = new PresaleFactory(address(template), address(0));
        coordinator = new CoordinatorFactory(
            address(tokenFactory), address(presaleFactory), address(router), address(dividendImpl)
        );

        // 测试合约是工厂 admin，直接授予 Coordinator 角色
        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        vm.deal(creator, 100 ether);
        vm.prank(creator);
        coordinator.createToken{value: 1 ether}(_tokenConfig());
    }

    function test_CreateTokenOnlyNoPresaleSetup() public {
        // createToken 后：代币在托管仓、所有权在创建者、预售未配置
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address presale = coordinator.getTokenPresale(token);
        assertTrue(presale != address(0));

        assertEq(IERC20Lite(token).balanceOf(presale), SUPPLY);
        assertEq(FlapTaxTokenV3(token).owner(), creator); // token owner = 创建者
        assertEq(PRESALE(payable(presale)).creator(), address(0)); // 未配置预售
        (bool enabled,,,,,) = PRESALE(payable(presale)).getLaunchStatus();
        assertEq(enabled, false);
        assertEq(PRESALE(payable(presale)).presaleStatus(), 0);
    }

    function test_SetupPresaleThenFullFlow() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address presale = coordinator.getTokenPresale(token);

        PresaleConfig memory cfg = _presaleConfig();

        vm.prank(creator);
        coordinator.setupPresale(token, cfg);

        // 创建者自行移交 token 所有权（setupPresale 只配置，不移交）
        vm.prank(creator);
        FlapTaxTokenV3(token).transferOwnership(presale);

        // token 所有权已移交托管仓（供 launch 编排）
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

    // ---------------------------------------------------------------------------
    // 新增：四通道 / 退款 / 税率上限 / Dividend 部署 / maxBuy 校验
    // ---------------------------------------------------------------------------

    function test_RefundsExcessCreationFee() public {
        uint256 balanceBefore = creator.balance;
        vm.prank(creator);
        coordinator.createToken{value: 1 ether}(_tokenConfig());
        // 仅扣 0.005 创建费，多付全额退还
        assertEq(creator.balance, balanceBefore - 0.005 ether);
    }

    function test_RevertWhen_AllocationSumWrong() public {
        TokenConfig memory cfg = _tokenConfig();
        cfg.marketBps = 5000; // 5000+2000+2000+2000 = 11000 ≠ 10000
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(InvalidAllocationBps.selector);
        coordinator.createToken{value: 1 ether}(cfg);
    }

    function test_RevertWhen_TaxAboveTenPercent() public {
        TokenConfig memory cfg = _tokenConfig();
        cfg.buyTax = 1001; // > 10%
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        vm.expectRevert(BuyFeeTooHigh.selector);
        coordinator.createToken{value: 1 ether}(cfg);

        TokenConfig memory cfg2 = _tokenConfig();
        cfg2.sellTax = 1001;
        vm.prank(creator);
        vm.expectRevert(SellFeeTooHigh.selector);
        coordinator.createToken{value: 1 ether}(cfg2);
    }

    function test_DeploysDividendWhenChannelOn() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address dividend = coordinator.tokenDividends(token);
        assertTrue(dividend != address(0), "dividend deployed");
        assertEq(Dividend(payable(dividend)).owner(), address(coordinator)); // 平台托管
        assertEq(Dividend(payable(dividend)).dividendToken(), address(0xAABB)); // WBNB
        assertEq(Dividend(payable(dividend)).taxToken(), token);

        // TaxProcessor 分红地址已接线
        address processor = FlapTaxTokenV3(token).taxProcessor();
        assertEq(TaxProcessor(processor).dividendAddress(), dividend);
        // 代币持仓同步合约已接线
        assertEq(FlapTaxTokenV3(token).dividendContract(), dividend);
        // meta 元数据已透传
        assertEq(FlapTaxTokenV3(token).metaURI(), "ipfs://QmTestMeta");
        // 四通道配置已透传
        PackedFeeConfig memory cfg = TaxProcessor(processor).feeConfig();
        assertEq(cfg.marketBps, 4000);
        assertEq(cfg.deflationBps, 2000);
        assertEq(cfg.lpBps, 2000);
        assertEq(cfg.dividendBps, 2000);
        assertEq(cfg.feeRate, 0); // 平台不抽成
    }

    function test_NoDividendWhenZeroBps() public {
        TokenConfig memory cfg = _tokenConfig();
        cfg.dividendBps = 0;
        cfg.marketBps = 6000; // 保持合计 10000
        vm.prank(creator);
        (address token,) = coordinator.createToken{value: 1 ether}(cfg);
        assertEq(coordinator.tokenDividends(token), address(0));
        assertEq(FlapTaxTokenV3(token).dividendContract(), address(0));
    }

    function test_ZeroAntiFarmerDurationAllowed() public {
        TokenConfig memory cfg = _tokenConfig();
        cfg.antiFarmerDuration = 0; // 支持用户不设防夹期
        vm.prank(creator);
        (address token,) = coordinator.createToken{value: 1 ether}(cfg);
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

    function test_DividendAdminPassthrough() public {
        address token = coordinator.getTokenPresalePairsByCreator(creator, 0, 1)[0].tokenAddress;
        address dividend = coordinator.tokenDividends(token);
        address holder = address(0x7777);

        vm.prank(address(this)); // 测试合约是 admin
        coordinator.dividendExcludeAddress(token, holder);
        assertTrue(Dividend(payable(dividend)).excludedFromDividends(holder));

        vm.prank(address(this));
        coordinator.dividendUnexcludeAddress(token, holder);
        assertFalse(Dividend(payable(dividend)).excludedFromDividends(holder));
    }

    function _tokenConfig() internal view returns (TokenConfig memory) {
        return TokenConfig({
            name: "TeamToken",
            symbol: "TT",
            meta: "ipfs://QmTestMeta",
            buyTax: 300,
            sellTax: 500,
            feeRecipient: feeReceiver,
            marketAddress: address(0x9999),
            taxDuration: 7 days,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0,
            marketBps: 4000, // 创作者/营销 40%
            deflationBps: 2000, // 销毁 20%
            dividendBps: 2000, // 分红 20%
            lpBps: 2000, // 流动性 20%
            minHolderBalance: 0
        });
    }

    function _presaleConfig() internal view returns (PresaleConfig memory) {
        return PresaleConfig({
            presaleTokenPrice: 1e15,
            maxBuyPerWallet: 1e8 ether,
            hardcap: 0,
            minLiquidityAmount: 0.1 ether,
            startTime: 0,
            vestingDelay: 7 days,
            vestingRate: 10,
            slippage: 0
        });
    }
}
