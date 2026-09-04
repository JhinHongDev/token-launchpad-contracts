// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {PRESALE} from "src/Presale.sol";
import {CoordinatorFactory, InvalidSalt, InvalidVanitySuffix, NotReserver} from "src/CoordinatorFactory.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {PresaleFactory, PresaleConfig} from "src/PresaleFactory.sol";
import {Clones} from "src/Clones.sol";
import {MockRouterWithFactory, MockPairFactory, IERC20Lite, VanitySaltFinder} from "./TokenReservation.t.sol";

/// @title 全平台尾号 8888 靓号地址专项测试
/// @dev 覆盖面：
///      1) 主路径：8888 盐免费创建（仅 creationFee），地址尾号精确断言，全流程接线与历史一致
///      2) 校验闸门：salt=0 → InvalidSalt；非 8888 盐 → InvalidVanitySuffix（创建与预留双路径）
///      3) 预留兼容：预留的也是 8888 地址 —— 他人预留 NotReserver、本人放行、非 8888 不可预留
///      4) 防重复：同盐二创 CloneFailed（EIP-684 整笔回滚，付款方无损）
///      5) 组合端到端：8888 币 → setupPresale → 认购 → launch → vesting claim
contract Vanity8888Test is Test {
    uint256 constant SUPPLY = 1e9 ether;
    uint160 constant SUFFIX = 0x8888;

    FlapTaxTokenV3 flapImpl;
    MockRouterWithFactory router;
    TokenFactory tokenFactory;
    PresaleFactory presaleFactory;
    CoordinatorFactory coordinator;

    address creator = address(0xC7EA);
    address alice = address(0xA11CE);

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
        vm.deal(alice, 100 ether);
    }

    // ---------------------------------------------------------------------------
    // 主路径：8888 盐免费创建（仅付 creationFee）
    // ---------------------------------------------------------------------------

    function test_VanitySaltCreatesSuffix8888Address() public {
        bytes32 salt = _vanitySalt("main");
        address predicted = tokenFactory.predictTokenAddress(salt);
        assertEq(uint160(predicted) & 0xFFFF, SUFFIX, "fixture must be vanity");

        uint256 balanceBefore = creator.balance;
        vm.prank(creator);
        (address token, address presale) = coordinator.createToken{value: 1 ether}(cfgToken(), salt);

        // 地址精确落位预言位且尾号 8888
        assertEq(token, predicted);
        assertEq(uint160(token) & 0xFFFF, SUFFIX, "token address must end with 8888");

        // 免预约费：仅扣 0.005 creationFee，多付退还
        assertEq(creator.balance, balanceBefore - 0.005 ether, "only creationFee charged");

        // 全流程接线与历史一致：全量入托管仓、所有权交托管仓、注册完整
        assertEq(IERC20Lite(token).balanceOf(presale), SUPPLY);
        assertEq(FlapTaxTokenV3(token).owner(), presale);
        assertTrue(coordinator.tokenExists(token));
        assertEq(coordinator.getTokenCreator(token), creator);
    }

    // ---------------------------------------------------------------------------
    // 校验闸门
    // ---------------------------------------------------------------------------

    function test_RevertWhen_ZeroSalt() public {
        vm.prank(creator);
        vm.expectRevert(InvalidSalt.selector);
        coordinator.createToken{value: 0.005 ether}(cfgToken(), bytes32(0));
    }

    function test_RevertWhen_NonVanitySaltOnCreate() public {
        bytes32 plain = keccak256("plain-salt");
        assertTrue(uint160(tokenFactory.predictTokenAddress(plain)) & 0xFFFF != SUFFIX, "fixture must be non-vanity");

        vm.prank(creator);
        vm.expectRevert(InvalidVanitySuffix.selector);
        coordinator.createToken{value: 0.005 ether}(cfgToken(), plain);
    }

    function test_RevertWhen_NonVanitySaltOnReserve() public {
        bytes32 plain = keccak256("plain-reserve");
        assertTrue(uint160(tokenFactory.predictTokenAddress(plain)) & 0xFFFF != SUFFIX, "fixture must be non-vanity");

        vm.prank(alice);
        vm.expectRevert(InvalidVanitySuffix.selector);
        coordinator.reserveTokenAddress{value: 0.01 ether}(plain);
    }

    // ---------------------------------------------------------------------------
    // 预留兼容：预留的同样是 8888 地址（预先创建）
    // ---------------------------------------------------------------------------

    function test_ReservedVanitySalt_OnlyReserverCanDeploy() public {
        bytes32 salt = _vanitySalt("reserved");
        address predicted = tokenFactory.predictTokenAddress(salt);

        // alice 付费预留 8888 地址
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        coordinator.reserveTokenAddress{value: 0.01 ether}(salt);
        assertEq(alice.balance, aliceBefore - 0.01 ether, "reservation fee charged");
        assertEq(coordinator.tokenAddressReserver(predicted), alice);

        // 他人兑现被拒
        vm.prank(creator);
        vm.expectRevert(NotReserver.selector);
        coordinator.createToken{value: 0.005 ether}(cfgToken(), salt);

        // 本人兑现放行，地址精确落位
        vm.prank(alice);
        (address token,) = coordinator.createToken{value: 0.005 ether}(cfgToken(), salt);
        assertEq(token, predicted);
        assertEq(uint160(token) & 0xFFFF, SUFFIX);
    }

    // ---------------------------------------------------------------------------
    // 防重复：同盐二创整笔回滚（EIP-684）
    // ---------------------------------------------------------------------------

    function test_RevertWhen_DuplicateSaltRedeploy() public {
        bytes32 salt = _vanitySalt("dup");
        vm.prank(creator);
        coordinator.createToken{value: 0.005 ether}(cfgToken(), salt);

        uint256 balanceBefore = creator.balance;
        uint256 countBefore = coordinator.getTotalTokenCount();
        vm.prank(creator);
        vm.expectRevert(Clones.CloneFailed.selector);
        coordinator.createToken{value: 0.005 ether}(cfgToken(), salt);
        assertEq(creator.balance, balanceBefore, "rollback keeps payer whole");
        assertEq(coordinator.getTotalTokenCount(), countBefore);
    }

    // ---------------------------------------------------------------------------
    // 组合端到端：8888 币完整生命周期
    // ---------------------------------------------------------------------------

    function test_VanityTokenEndToEndPresaleLaunch() public {
        bytes32 salt = _vanitySalt("e2e");
        vm.prank(creator);
        (address token, address presale) = coordinator.createToken{value: 0.005 ether}(cfgToken(), salt);
        PRESALE sale = PRESALE(payable(presale));

        vm.prank(creator);
        coordinator.setupPresale(token, cfgPresale());

        vm.prank(creator);
        sale.openPresale();
        vm.prank(alice);
        sale.subscribe{value: 0.2 ether}();
        vm.prank(creator);
        sale.endPresale();
        vm.prank(creator);
        sale.launch();

        assertEq(sale.presaleStatus(), 3);
        assertEq(uint256(FlapTaxTokenV3(token).state()), 2);
        assertEq(FlapTaxTokenV3(token).owner(), address(0), "renounced after launch");
        assertEq(uint160(token) & 0xFFFF, SUFFIX, "still ends with 8888");

        // 一个周期后按份额领取
        skip(7 days);
        vm.prank(creator);
        sale.claim();
        assertEq(sale.claimedTokens(creator), SUPPLY * 3000 / 10_000 * 10 / 100, "first period 10% of 30%");
    }

    // ---------------------------------------------------------------------------
    // 夹具
    // ---------------------------------------------------------------------------

    /// @dev 按标签派生种子搜索尾号 8888 盐（标签分散起点，跨测试不撞盐）
    function _vanitySalt(string memory tag) internal view returns (bytes32) {
        (bytes32 s, bool found) = VanitySaltFinder.find(
            address(tokenFactory), tokenFactory.flapImplementation(), uint256(keccak256(bytes(tag)))
        );
        assertTrue(found, "vanity salt should exist within budget");
        return s;
    }

    /// @dev 盐与地址的交叉验证（library 公式 vs 合约视图，防两边公式漂移）
    function test_SaltFinderAgreesWithOnChainPredict() public {
        bytes32 salt = _vanitySalt("cross-check");
        address viaView = tokenFactory.predictTokenAddress(salt);
        address viaLib =
            Clones.predictDeterministicAddress(tokenFactory.flapImplementation(), salt, address(tokenFactory));
        assertEq(viaView, viaLib);
        assertEq(uint160(viaView) & 0xFFFF, SUFFIX);
    }

    function cfgToken() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            name: "VanityToken",
            symbol: "VNT",
            meta: "ipfs://QmVanity",
            buyTax: 300,
            sellTax: 500,
            feeRecipient: address(0xfee1),
            taxDuration: 7 days,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0
        });
    }

    function cfgPresale() internal pure returns (PresaleConfig memory) {
        return PresaleConfig({
            presaleTokenPrice: 1e15,
            maxBuyPerWallet: 1e5 ether,
            hardcap: 0,
            minLiquidityAmount: 0.1 ether,
            softCap: 0.1 ether,
            startTime: 0,
            duration: 30 days,
            vestingDelay: 7 days,
            vestingRate: 10,
            slippage: 0,
            creatorBuyTokens: 0
        });
    }
}
