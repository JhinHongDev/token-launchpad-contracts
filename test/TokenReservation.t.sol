// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {Clones} from "src/Clones.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {
    CoordinatorFactory,
    NotReserver,
    InvalidSalt,
    InsufficientReservationFee,
    AddressAlreadyReserved,
    AddressAlreadyDeployed,
    ZeroCreationFee,
    FactoryDisabled
} from "src/CoordinatorFactory.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {PRESALE} from "src/Presale.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";

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

/// @title CA 预留与五连 8 靓号确定性部署测试
/// @dev 套路约束（避坑）：
///      1) 动态金额一律先读入缓存变量再进 {value: ...}——花括号表达式的 staticcall 会吃掉
///         紧随其后的 vm.expectRevert 预期；
///      2) 事件断言走 vm.recordLogs 全量扫描，不做"镜像 emit 紧贴 target call"的位置敏感匹配。
contract TokenReservationTest is Test {
    uint256 constant SUPPLY = 1e9 ether;
    // 低 20 bit == 最后五个十六进制位；0x88888 即五连 8
    uint160 constant VANITY_88888 = 0x88888;
    bytes32 constant RESERVE_TOPIC =
        keccak256("TokenAddressReserved(address,address,uint256)");

    MockRouterWithFactory router;
    MockPairFactory pairFactory;
    TokenFactory tokenFactory;
    PresaleFactory presaleFactory;
    CoordinatorFactory coordinator;

    uint256 cFee; // 创建费缓存
    uint256 rFee; // 预留费缓存

    address creator = address(0xdeadbeef);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address nonAdmin = address(0xAAA1);

    function setUp() public {
        FlapTaxTokenV3 flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        pairFactory = new MockPairFactory();
        router = new MockRouterWithFactory(address(0xAABB), pairFactory);

        Dividend dividendImpl = new Dividend(address(0xAABB), address(0xdead));
        tokenFactory = new TokenFactory(address(flapImpl), address(router), address(0));
        PRESALE presaleTemplate = new PRESALE();
        presaleFactory = new PresaleFactory(address(presaleTemplate), address(0));
        coordinator =
            new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router), address(dividendImpl));

        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        cFee = coordinator.creationFee();
        rFee = coordinator.reservationFee();

        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 10 ether);
        vm.prank(creator);
        coordinator.createToken{value: cFee}(_tokenConfig(), bytes32(0));
    }

    // ---------------------------------------------------------------------------
    // 公式与确定性
    // ---------------------------------------------------------------------------

    /// @notice 与库函数一致的 OZ 公式本地复刻（abi 路径），用于交叉验证与单点查表
    function _predictLocal(bytes32 salt) internal view returns (address) {
        return Clones.predictDeterministicAddress(tokenFactory.flapImplementation(), salt, address(tokenFactory));
    }

    /// @notice 与 OpenZeppelin 手推公式一致的第三方复刻（hex 拼接路径），作为公式级对照
    function _predictHexFormula(bytes32 salt, address factoryAddr) internal view returns (address out) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            bytes20(tokenFactory.flapImplementation()),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), bytes20(factoryAddr), salt, keccak256(initCode)));
        out = address(uint160(uint256(h)));
    }

    function test_Predict_FormulaParityAcrossThreePaths() public {
        bytes32 s = keccak256("formula-check");
        address viaView = tokenFactory.predictTokenAddress(s);
        address viaLibDirect = Clones.predictDeterministicAddress(tokenFactory.flapImplementation(), s, address(tokenFactory));
        address viaManualHex = _predictHexFormula(s, address(tokenFactory));
        console2.log("viaView      :", viaView);
        console2.log("viaLibDirect :", viaLibDirect);
        console2.log("viaManualHex :", viaManualHex);
        assertTrue(viaView == viaLibDirect && viaLibDirect == viaManualHex, "three paths must agree");
    }

    function test_DeterministicDeploymentLandsOnPredictedAddress() public {
        bytes32 s = keccak256("t1");
        address predicted = tokenFactory.predictTokenAddress(s);

        vm.recordLogs();
        vm.prank(creator);
        coordinator.createToken{value: cFee}(_tokenConfig(), s);

        // 从 TokenCreated 事件直取事件侧的代币地址（绕开注册表索引假设）
        Vm.Log[] memory entries = vm.getRecordedLogs();
        address evtToken;
        for (uint256 i = 0; i < entries.length; i++) {
            if (
                entries[i].emitter == address(tokenFactory) && entries[i].topics.length >= 2
                    && entries[i].topics[0] == keccak256("TokenCreated(address,address,address,address)")
            ) {
                evtToken = address(uint160(uint256(entries[i].topics[1])));
                break;
            }
        }

        console2.log("pred    :", predicted);
        console2.log("evtTok  :", evtToken);
        console2.log("registry:", coordinator.getTokenPresalePairsByCreator(creator, 0, 2)[1].tokenAddress);
        console2.log("count   :", coordinator.getTotalTokenCount());

        assertEq(coordinator.getTotalTokenCount(), 2, "default + salted");
        address created = coordinator.getTokenPresalePairsByCreator(creator, 0, 2)[1].tokenAddress;
        console2.log("equality created==predicted:", created == predicted);
        assertEq(evtToken, predicted);
        assertTrue(coordinator.tokenExists(predicted));
        assertEq(IERC20Lite(predicted).balanceOf(coordinator.getTokenPresale(predicted)), SUPPLY);
    }

    function test_ZeroSaltKeepsLegacyRandomPath() public {
        vm.prank(creator);
        coordinator.createToken{value: cFee}(_tokenConfig(), bytes32(0));

        assertEq(coordinator.getTotalTokenCount(), 2);
        address newest = coordinator.getTokenPresalePairsByCreator(creator, 0, 2)[1].tokenAddress;
        assertTrue(coordinator.tokenExists(newest));
        assertTrue(newest != tokenFactory.predictTokenAddress(bytes32(0)));
    }

    // ---------------------------------------------------------------------------
    // 防重：同盐二次部署整笔回滚
    // ---------------------------------------------------------------------------

    function test_RevertWhen_DuplicateSaltRedeploy() public {
        bytes32 s = keccak256("dup");
        vm.deal(bob, 1 ether);

        vm.prank(bob);
        coordinator.createToken{value: cFee}(_tokenConfig(), s);

        uint256 balanceBefore = bob.balance;
        uint256 supplyBefore = coordinator.getTotalTokenCount();
        vm.prank(bob);
        vm.expectRevert(Clones.CloneFailed.selector);
        coordinator.createToken{value: cFee}(_tokenConfig(), s);
        assertEq(bob.balance, balanceBefore, "rollback keeps payer whole");
        assertEq(coordinator.getTotalTokenCount(), supplyBefore);
    }

    // ---------------------------------------------------------------------------
    // 档位 1：普通盐预留 → 发币闭环
    // ---------------------------------------------------------------------------

    /// @notice 从 recordLogs 中提取最近的 TokenAddressReserved 日志参数
    function _lastReservedEvent()
        internal
        view
        returns (bool found, address tokenAddr, address reserver, uint256 feeAmt)
    {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = entries.length; i > 0; i--) {
            if (entries[i - 1].emitter != address(coordinator)) continue;
            if (entries[i - 1].topics.length < 3 || entries[i - 1].topics[0] != RESERVE_TOPIC) continue;
            tokenAddr = address(uint160(uint256(entries[i - 1].topics[1])));
            reserver = address(uint160(uint256(entries[i - 1].topics[2])));
            feeAmt = abi.decode(entries[i - 1].data, (uint256));
            found = true;
            break;
        }
    }

    function test_Tier1_PlainSaltReserveThenDeploy() public {
        bytes32 s = keccak256("plain-ca");
        address predicted = tokenFactory.predictTokenAddress(s);

        vm.recordLogs();
        uint256 before = alice.balance;
        vm.prank(alice);
        coordinator.reserveTokenAddress{value: rFee}(s);

        assertEq(alice.balance, before - rFee);
        assertEq(coordinator.tokenAddressReserver(predicted), alice);

        (bool found, address evtToken,, uint256 evtFee) = _lastReservedEvent();
        assertTrue(found, "reserve event must be recorded");
        assertEq(evtToken, predicted);
        assertEq(evtFee, rFee);

        // 发币兑现：仅付创建费，地址精确落在预约位
        vm.prank(alice);
        coordinator.createToken{value: cFee}(_tokenConfig(), s);
        assertEq(coordinator.getTokenPresalePairsByCreator(alice, 0, 1)[0].tokenAddress, predicted);
    }

    // ---------------------------------------------------------------------------
    // 预留校验矩阵
    // ---------------------------------------------------------------------------

    function test_Reserve_Matrix() public {
        // salt 为零拒绝
        vm.prank(alice);
        vm.expectRevert(InvalidSalt.selector);
        coordinator.reserveTokenAddress{value: rFee}(bytes32(0));

        // 费用不足拒绝
        bytes32 s = keccak256("short-pay");
        vm.startPrank(alice);
        vm.expectRevert(InsufficientReservationFee.selector);
        coordinator.reserveTokenAddress{value: rFee - 1}(s);
        // 正常预留后重复预留拒绝
        coordinator.reserveTokenAddress{value: rFee}(s);
        vm.expectRevert(AddressAlreadyReserved.selector);
        coordinator.reserveTokenAddress{value: rFee}(s);
        vm.stopPrank();

        // 多付超额原路退还，事件金额记实收费而非付款额
        uint256 before = bob.balance;
        bytes32 s2 = keccak256("overpay");
        vm.recordLogs();
        vm.prank(bob);
        coordinator.reserveTokenAddress{value: rFee + 0.05 ether}(s2);
        assertEq(bob.balance, before - rFee);
        (bool foundOverpay, address evtToken2, address evtReserver2, uint256 evtFee2) = _lastReservedEvent();
        assertTrue(foundOverpay);
        assertEq(evtToken2, tokenFactory.predictTokenAddress(s2));
        assertEq(evtReserver2, bob);
        assertEq(evtFee2, rFee, "event must record actual fee, not overpaid amount");

        // 已有代码的预测地址不可再预留
        vm.prank(creator);
        coordinator.createToken{value: cFee}(_tokenConfig(), keccak256("deployed-first"));
        address deployed = tokenFactory.predictTokenAddress(keccak256("deployed-first"));
        assertTrue(deployed.code.length != 0);
        vm.prank(bob);
        vm.expectRevert(AddressAlreadyDeployed.selector);
        coordinator.reserveTokenAddress{value: rFee}(keccak256("deployed-first"));
    }

    // ---------------------------------------------------------------------------
    // 权限：他人持已预留盐发币被拒；未预留盐对所有人开放
    // ---------------------------------------------------------------------------

    function test_NotReserver_BlockedWhileUnreservedAllowed() public {
        bytes32 locked = keccak256("owned-by-alice");

        vm.prank(alice);
        coordinator.reserveTokenAddress{value: rFee}(locked);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(NotReserver.selector);
        coordinator.createToken{value: cFee}(_tokenConfig(), locked);

        // 未预留的盐任何人可用
        bytes32 open = keccak256("open-salt");
        vm.prank(bob);
        coordinator.createToken{value: cFee}(_tokenConfig(), open);
        assertEq(
            coordinator.getTokenPresalePairsByCreator(bob, 0, 1)[0].tokenAddress,
            tokenFactory.predictTokenAddress(open)
        );
    }

    // ---------------------------------------------------------------------------
    // 档位 2：五连 8 靓号搜索 → 预留 → 落位（前端可行性证明）
    // ---------------------------------------------------------------------------

    /// @dev 固定 scratch 的汇编搜索器：单轮仅 1 次 keccak(85B)，无逐轮内存分配
    function _findVanity88888() internal view returns (bytes32 saltHit, bool found) {
        address factoryAddr = address(tokenFactory);
        address impl = tokenFactory.flapImplementation();
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            let ich := keccak256(ptr, 0x37)

            let i := 1
            for {} lt(i, 8000000) {} {
                mstore(add(ptr, 21), i) // 盐槽位复用（bytes32(i)）
                mstore(ptr, shl(248, 0xff))
                mstore(add(ptr, 1), shl(96, factoryAddr))
                mstore(add(ptr, 53), ich)
                let h := keccak256(ptr, 85)
                // 地址 = h 低 20 字节，顶 5 位 hex = h 的 bit[140:160]
                if eq(and(shr(140, h), 0xFFFFF), 0x88888) {
                    saltHit := i
                    found := true
                    break
                }
                i := add(i, 1)
            }
        }
    }

    function test_Vanity88888_SearchReserveAndDeploy() public {
        (bytes32 vanitySalt, bool found) = _findVanity88888();
        assertTrue(found, "vanity salt should exist within budget");
        assertTrue(vanitySalt != bytes32(0));

        address predicted = tokenFactory.predictTokenAddress(vanitySalt);
        // 靓号 = 地址开头 5 位 hex（高 20 bit），非低位掩码
        assertEq(uint160(predicted) >> 140, VANITY_88888);

        // 完整用户旅程：搜到 → 预留 → 发币落位同一靓号地址
        vm.prank(alice);
        coordinator.reserveTokenAddress{value: rFee}(vanitySalt);
        vm.prank(alice);
        coordinator.createToken{value: cFee}(_tokenConfig(), vanitySalt);
        assertEq(coordinator.getTokenPresalePairsByCreator(alice, 0, 1)[0].tokenAddress, predicted);
    }

    // ---------------------------------------------------------------------------
    // 管理接口
    // ---------------------------------------------------------------------------

    function test_SetReservationFee_AdminOnlyAndZeroRejected() public {
        vm.prank(nonAdmin);
        vm.expectRevert(); // AccessControl 缺角色
        coordinator.setReservationFee(0.02 ether);

        vm.expectRevert(ZeroCreationFee.selector);
        coordinator.setReservationFee(0);

        coordinator.setReservationFee(0.02 ether);
        assertEq(coordinator.reservationFee(), 0.02 ether);
    }

    /// @notice 工厂禁用 = 停止一切付费服务，预留同步不可用；重新启用后恢复
    function test_ReserveBlockedWhenFactoryDisabled() public {
        bytes32 s = keccak256("disabled-window");

        coordinator.setFactoryEnabled(false);
        vm.prank(alice);
        vm.expectRevert(FactoryDisabled.selector);
        coordinator.reserveTokenAddress{value: rFee}(s);
        assertEq(coordinator.tokenAddressReserver(tokenFactory.predictTokenAddress(s)), address(0), "no state side-effect");

        coordinator.setFactoryEnabled(true);
        vm.prank(alice);
        coordinator.reserveTokenAddress{value: rFee}(s);
        assertEq(coordinator.tokenAddressReserver(tokenFactory.predictTokenAddress(s)), alice);
    }

    receive() external payable {}

    // ---------------------------------------------------------------------------
    // 夹具
    // ---------------------------------------------------------------------------

    function _tokenConfig() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            name: "TeamToken",
            symbol: "TT",
            meta: "ipfs://QmTestMeta",
            buyTax: 300,
            sellTax: 500,
            feeRecipient: address(0xfee1),
            marketAddress: address(0x9999),
            taxDuration: 7 days,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0,
            marketBps: 4000,
            deflationBps: 2000,
            dividendBps: 2000,
            lpBps: 2000,
            minHolderBalance: 0
        });
    }
}
