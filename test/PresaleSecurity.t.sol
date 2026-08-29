// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {CoordinatorFactory, PresaleConfig} from "src/CoordinatorFactory.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {PRESALE, PresaleNotOpen, PresaleDisabled, TokensAlreadyClaimed, SoftCapTooLow} from "src/Presale.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {MockRouterWithFactory, MockPairFactory, IERC20Lite} from "./TokenReservation.t.sol";

/// @title 预售安全回归测试：封锁“绕过协调器直调 PRESALE 原生函数”的两条攻击路径
/// @dev 攻击面：创建者即 PRESALE owner，可越过协调器直调配置类函数。
///      回归点 1：claimAllTokens（抽干托管仓）后不可再 configureLaunch 重开预售 → 防 exit scam
///      回归点 2：openPresale 终检 softCap >= minLiquidityAmount → 防配置顺序绕过导致 status 2 死锁
contract PresaleSecurityTest is Test {
    uint256 constant SUPPLY = 1e9 ether;

    MockRouterWithFactory router;
    TokenFactory tokenFactory;
    CoordinatorFactory coordinator;
    PRESALE presale;
    address token;

    address creator = address(0xC1);
    address victim = address(0xBEEF);

    function setUp() public {
        FlapTaxTokenV3 flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        MockPairFactory pairFactory = new MockPairFactory();
        router = new MockRouterWithFactory(address(0xAABB), pairFactory);
        tokenFactory = new TokenFactory(address(flapImpl), address(router), address(0));
        PresaleFactory presaleFactory = new PresaleFactory(address(new PRESALE()), address(0));
        coordinator = new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));
        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        vm.deal(creator, 100 ether);
        vm.deal(victim, 100 ether);
        // 花括号 value 表达式内的 staticcall 会吞掉 vm.prank，先缓存费率（见 TokenReservation.t 注释）
        uint256 fee = coordinator.creationFee();
        vm.prank(creator);
        (token, presale) = _create(fee);
    }

    function _create(uint256 fee) internal returns (address, PRESALE) {
        (address t, address p) = coordinator.createToken{value: fee}(_tokenConfig(), bytes32(0));
        return (t, PRESALE(payable(p)));
    }

    /// 回归 1：抽干托管仓后重配置预售必须被拒（原 exit scam：领走 100% 代币后开预售募资，
    /// 认购款永久锁死/被创建者经 LP 套现）
    function test_RevertWhen_ReconfigurePresaleAfterDrainingEscrow() public {
        vm.prank(creator);
        presale.claimAllTokens(); // 纯发币模式：一次性领走 100% 代币
        assertEq(IERC20Lite(token).balanceOf(address(presale)), 0, "escrow drained");

        vm.prank(creator);
        vm.expectRevert(TokensAlreadyClaimed.selector);
        presale.configureLaunch(true, creator, 3e8 ether, 2e8 ether, 5e8 ether);

        // 闸口封锁后下游全链路不可达：开盘/认购均拒绝，受害者无从入场
        vm.prank(creator);
        vm.expectRevert(PresaleDisabled.selector);
        presale.openPresale();
        vm.prank(victim);
        vm.expectRevert(PresaleNotOpen.selector);
        presale.subscribe{value: 1 ether}();
        assertEq(address(presale).balance, 0, "no funds can enter");
    }

    /// 回归 2：setPresaleTerms 抬高 minLiquidityAmount 破坏 softCap 不变量后，openPresale 必须被拒
    /// （原攻击：softCap=0.1 已设，terms 把 minLiquidity 抬到 5 ETH，散户认购 3 ETH 后
    ///   status 2 死角——launch 永远 InsufficientBNB、refund 仅 FAILED 态，资金无人可取）
    function test_RevertWhen_OpenPresaleWithBrokenSoftCapInvariant() public {
        vm.prank(creator);
        coordinator.setupPresale(token, _presaleConfig()); // 正常路径：softCap(0.1) == minLiquidity(0.1)

        // 绕过协调器直调 setPresaleTerms 抬高 minLiquidityAmount（不变量被破坏的根源路径）
        vm.prank(creator);
        presale.setPresaleTerms(1e15, 5e8 ether, 1e8 ether, 0, 5 ether, 0);

        vm.prank(creator);
        vm.expectRevert(SoftCapTooLow.selector); // 开盘终检拦截
        presale.openPresale();

        // 状态停在 0，认购不可达 → 无资金可入死角
        vm.prank(victim);
        vm.expectRevert(PresaleNotOpen.selector);
        presale.subscribe{value: 3 ether}();
        assertEq(address(presale).balance, 0, "no funds can enter");
    }

    // ── 夹具 ──

    function _presaleConfig() internal pure returns (PresaleConfig memory) {
        return PresaleConfig({
            presaleTokenPrice: 1e15,
            maxBuyPerWallet: 1e8 ether,
            hardcap: 0,
            minLiquidityAmount: 0.1 ether,
            softCap: 0.1 ether,
            startTime: 0,
            vestingDelay: 7 days,
            vestingRate: 10,
            slippage: 0
        });
    }

    function _tokenConfig() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            name: "SecToken",
            symbol: "SEC",
            meta: "ipfs://QmSec",
            buyTax: 300,
            sellTax: 500,
            feeRecipient: address(0xfee1),
            taxDuration: 7 days,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0
        });
    }
}
