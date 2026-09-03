// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {Clones} from "src/Clones.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {
    CoordinatorFactory,
    NotReserver,
    InvalidSalt,
    InvalidVanitySuffix,
    InsufficientReservationFee,
    AddressAlreadyReserved,
    AddressAlreadyDeployed,
    ZeroCreationFee,
    FactoryDisabled
} from "src/CoordinatorFactory.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {PRESALE} from "src/Presale.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";

/// @dev 尾号 8888（低 16 bit）CREATE2 搜盐器：单轮 1 keccak(85B)、scratch 复用、无逐轮内存分配。
///      测试环境专用（生产端在前端 JS 搜索）；from 为起始种子，调用方以不同 tag 派生避免趋同撞盐。
library VanitySaltFinder {
    uint160 internal constant VANITY_SUFFIX = 0x8888;
    /// 期望 2^16 次命中，2^20 为远超 5σ 的保守上界
    uint256 internal constant MAX_TRIES = 1 << 20;

    function find(address factory, address impl, uint256 from) internal view returns (bytes32 salt, bool found) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            let ich := keccak256(ptr, 0x37)

            let i := from
            let end := add(from, 1048576)
            for {} lt(i, end) {} {
                // 写入顺序 = 布局顺序（ff → factory → salt → ich）：盐槽 [21,53) 与 factory 槽 [1,33)
                // 重叠 [21,33) 区段，盐必须后写，否则其高 12 字节被 factory 的左填充零覆盖
                mstore(ptr, shl(248, 0xff))
                mstore(add(ptr, 1), shl(96, factory))
                mstore(add(ptr, 21), i)
                mstore(add(ptr, 53), ich)
                let h := keccak256(ptr, 85)
                // 地址 = h 低 20 字节 → 地址尾号 8888 = h 低 16 bit
                if eq(and(h, 0xFFFF), 0x8888) {
                    salt := i
                    found := true
                    break
                }
                i := add(i, 1)
            }
        }
    }
}

contract MockPairFactory {
    address public pair;

    function createPair(address, address) external returns (address) {
        return pair;
    }
}

/// @dev 模拟 PancakeRouter02 子集：本合约同时扮演"池子"——加池时拉入的代币留存于此作为
///      可卖储备（LP 凭证恒 1e18 仅作返回值），swap 按固定汇率 swapRate（tokens per BNB）成交，
///      swapETHForExactTokens 复刻 PancakeSwap 找零行为（多余 ETH 退回调用方）
contract MockRouterWithFactory {
    address public weth;
    MockPairFactory public pairFactory;

    /// @notice 汇率：1 BNB 兑换的代币数量（wei），默认 2 亿枚/BNB（对齐开盘池 20% 份额形态）
    uint256 public swapRate = 200_000 ether;

    /// @notice 注入 swap 失败（测试 launch 的退币兜底路径）
    bool public failSwap;

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

    function setSwapRate(uint256 rate) external {
        swapRate = rate;
    }

    function setFailSwap(bool v) external {
        failSwap = v;
    }

    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address, uint256)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        // 代币留存本合约模拟池储备（LP 凭证为概念值）；msg.value（BNB 侧）同样留存
        IERC20Lite(token).transferFrom(msg.sender, address(this), amountTokenDesired);
        return (amountTokenDesired, msg.value, 1e18);
    }

    /// @notice quote 模式路由：BNB 全额换入，按固定汇率发币
    function swapExactETHForTokens(uint256, address[] calldata path, address to, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        if (failSwap) revert("mock: swap failed");
        uint256 out = (msg.value * swapRate) / 1e18;
        IERC20Lite(path[1]).transfer(to, out);
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = out;
    }

    /// @notice token 模式路由：精确数量发币，按汇率计算成本，找零退回调用方（复刻 PancakeSwap）
    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        if (failSwap) revert("mock: swap failed");
        uint256 cost = (amountOut * 1e18) / swapRate;
        if (cost == 0) cost = 1; // 向上取整语义：零成本视为最小单位
        require(msg.value >= cost, "mock: insufficient input");
        IERC20Lite(path[1]).transfer(to, amountOut);
        // PancakeSwap 行为：多余的 ETH 原路退回调用方
        (bool ok,) = msg.sender.call{value: msg.value - cost}("");
        require(ok, "mock: refund failed");
        amounts = new uint256[](2);
        amounts[0] = cost;
        amounts[1] = amountOut;
    }
}

interface IERC20Lite {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title CA 预留与尾号 8888 靓号确定性部署测试
/// @dev 套路约束（避坑）：
///      1) 动态金额一律先读入缓存变量再进 {value: ...}——花括号表达式的 staticcall 会吃掉
///         紧随其后的 vm.expectRevert 预期；
///      2) 事件断言走 vm.recordLogs 全量扫描，不做"镜像 emit 紧贴 target call"的位置敏感匹配。
contract TokenReservationTest is Test {
    uint256 constant SUPPLY = 1e9 ether;
    // 地址尾号 = 低 16 bit；0x8888 即尾号 8888（全平台强制，见 VANITY_SUFFIX 校验）
    uint160 constant VANITY_SUFFIX = 0x8888;
    bytes32 constant RESERVE_TOPIC = keccak256("TokenAddressReserved(address,address,uint256)");

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

        tokenFactory = new TokenFactory(address(flapImpl), address(router), address(0));
        PRESALE presaleTemplate = new PRESALE();
        presaleFactory = new PresaleFactory(address(presaleTemplate), address(0));
        coordinator = new CoordinatorFactory(address(tokenFactory), address(presaleFactory), address(router));

        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        cFee = coordinator.creationFee();
        rFee = coordinator.reservationFee();

        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 10 ether);
        // 盐先搜入局部变量再进调用：prank 之后的参数表达式里做外部调用会吞掉 prank（本文件"套路约束 1"）
        bytes32 defaultSalt = _vanitySalt("tr-default");
        vm.prank(creator);
        coordinator.createToken{value: cFee}(_tokenConfig(), defaultSalt);
    }

    /// @dev 按标签派生种子搜索尾号 8888 盐（标签不同 → 种子不同 → 天然分散不撞盐）
    function _vanitySalt(string memory tag) internal view returns (bytes32) {
        (bytes32 s, bool found) = VanitySaltFinder.find(
            address(tokenFactory), tokenFactory.flapImplementation(), uint256(keccak256(bytes(tag)))
        );
        assertTrue(found, "vanity salt should exist within budget");
        return s;
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
        address viaLibDirect =
            Clones.predictDeterministicAddress(tokenFactory.flapImplementation(), s, address(tokenFactory));
        address viaManualHex = _predictHexFormula(s, address(tokenFactory));
        console2.log("viaView      :", viaView);
        console2.log("viaLibDirect :", viaLibDirect);
        console2.log("viaManualHex :", viaManualHex);
        assertTrue(viaView == viaLibDirect && viaLibDirect == viaManualHex, "three paths must agree");
    }

    function test_DeterministicDeploymentLandsOnPredictedAddress() public {
        bytes32 s = _vanitySalt("t1");
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
                    && entries[i].topics[0] == keccak256("TokenCreated(address,address,address)")
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

    function test_RevertWhen_ZeroSalt() public {
        // 8888-only 体系：随机地址通道已废除，salt=0 一律拒绝
        vm.prank(creator);
        vm.expectRevert(InvalidSalt.selector);
        coordinator.createToken{value: cFee}(_tokenConfig(), bytes32(0));
    }

    function test_RevertWhen_NonVanitySalt() public {
        // 尾号非 8888 的盐：创建与预留双路径一律拒绝
        bytes32 plain = keccak256("no-suffix");
        assertTrue(
            uint160(tokenFactory.predictTokenAddress(plain)) & 0xFFFF != VANITY_SUFFIX, "fixture must be non-vanity"
        );

        vm.prank(creator);
        vm.expectRevert(InvalidVanitySuffix.selector);
        coordinator.createToken{value: cFee}(_tokenConfig(), plain);

        vm.prank(alice);
        vm.expectRevert(InvalidVanitySuffix.selector);
        coordinator.reserveTokenAddress{value: rFee}(plain);
    }

    // ---------------------------------------------------------------------------
    // 防重：同盐二次部署整笔回滚
    // ---------------------------------------------------------------------------

    function test_RevertWhen_DuplicateSaltRedeploy() public {
        bytes32 s = _vanitySalt("dup");
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
        bytes32 s = _vanitySalt("plain-ca");
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
        bytes32 s = _vanitySalt("short-pay");
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
        bytes32 s2 = _vanitySalt("overpay");
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
        bytes32 deployedSalt = _vanitySalt("deployed-first");
        vm.prank(creator);
        coordinator.createToken{value: cFee}(_tokenConfig(), deployedSalt);
        address deployed = tokenFactory.predictTokenAddress(deployedSalt);
        assertTrue(deployed.code.length != 0);
        vm.prank(bob);
        vm.expectRevert(AddressAlreadyDeployed.selector);
        coordinator.reserveTokenAddress{value: rFee}(deployedSalt);
    }

    // ---------------------------------------------------------------------------
    // 权限：他人持已预留盐发币被拒；未预留盐对所有人开放
    // ---------------------------------------------------------------------------

    function test_NotReserver_BlockedWhileUnreservedAllowed() public {
        bytes32 locked = _vanitySalt("owned-by-alice");

        vm.prank(alice);
        coordinator.reserveTokenAddress{value: rFee}(locked);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(NotReserver.selector);
        coordinator.createToken{value: cFee}(_tokenConfig(), locked);

        // 未预留的 8888 盐任何人免费可用
        bytes32 open = _vanitySalt("open-salt");
        vm.prank(bob);
        coordinator.createToken{value: cFee}(_tokenConfig(), open);
        assertEq(
            coordinator.getTokenPresalePairsByCreator(bob, 0, 1)[0].tokenAddress, tokenFactory.predictTokenAddress(open)
        );
    }

    // ---------------------------------------------------------------------------
    // 档位 2：尾号 8888 搜索 → 预留 → 落位（前端可行性证明，共享搜盐 library）
    // ---------------------------------------------------------------------------

    function test_VanitySuffix8888_SearchReserveAndDeploy() public {
        bytes32 vanitySalt = _vanitySalt("search-journey");
        assertTrue(vanitySalt != bytes32(0));

        address predicted = tokenFactory.predictTokenAddress(vanitySalt);
        // 靓号 = 地址尾号（低 16 bit）
        assertEq(uint160(predicted) & 0xFFFF, VANITY_SUFFIX);

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
        bytes32 s = _vanitySalt("disabled-window");

        coordinator.setFactoryEnabled(false);
        vm.prank(alice);
        vm.expectRevert(FactoryDisabled.selector);
        coordinator.reserveTokenAddress{value: rFee}(s);
        assertEq(
            coordinator.tokenAddressReserver(tokenFactory.predictTokenAddress(s)), address(0), "no state side-effect"
        );

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
            taxDuration: 7 days,
            antiFarmerDuration: 1 days,
            liqExpectedOutputAmount: 0
        });
    }
}
