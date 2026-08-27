// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test, Vm} from "forge-std/Test.sol";
import {CoordinatorFactory, PresaleConfig} from "src/CoordinatorFactory.sol";
import {TokenFactory, TokenConfig} from "src/TokenFactory.sol";
import {PRESALE} from "src/Presale.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";
import {MockRouterWithFactory, MockPairFactory, IERC20Lite} from "./TokenReservation.t.sol";

uint256 constant SUPPLY = 1e9 ether; // FlapTaxTokenV3 固定总量
uint256 constant MAX_TOKENS = 8; // 封顶防 invariant 校验循环膨胀
uint256 constant SALT_SPACE = 8; // 盐取值域 {0..7}：强制预留/发币/冲突路径互扰

/// @notice 平台资金流不变量测试（handler 模式）
/// @dev 三条性质，任意随机调用序列后必须成立：
///      1. 托管守恒：对每个已发代币，仓内余额 + 累计流出 == 初始供应（创建即托管、出口全记账）
///      2. CREATE2 确定性：盐路径部署地址 == 预言地址
///      3. 预留权属稳定：tokenAddressReserver 登记项不被任何调用序列改写
///      fail_on_revert=false：随机参数触发业务性 revert 属正常，仅 invariant 断言视为失败。
contract Handler {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    CoordinatorFactory immutable coordinator;
    TokenFactory immutable tokenFactory;

    address[5] actors;

    // ── ghost 账本（fuzzer 世界与链上状态对照） ──
    address[] tokens;
    mapping(address => bytes32) ghostSalt;
    mapping(address => address) ghostPresale;
    mapping(address => address) ghostCreator;
    mapping(address => uint256) ghostReleased; // 托管仓累计流出（覆盖 claim/claimAll/unsold/reclaim/加池）

    address[] reservedAddrs;
    mapping(address => address) ghostReserver;

    constructor(CoordinatorFactory _coordinator, TokenFactory _tokenFactory) {
        coordinator = _coordinator;
        tokenFactory = _tokenFactory;
        actors = [address(0xA11CE), address(0xB0B), address(0xC0C), address(0xD0D), address(0xE0E)];
    }

    // ------------------------------------------------------------------
    // 发币与预留
    // ------------------------------------------------------------------

    function createToken(uint256 saltSeed, uint256 actorSeed) external {
        if (tokens.length >= MAX_TOKENS) return;
        address actor = actors[actorSeed % actors.length];
        bytes32 salt = bytes32(uint256(saltSeed % SALT_SPACE));
        vm.deal(actor, 1000 ether);
        // 先缓存费率：花括号 value 表达式内的 staticcall 会吞掉 vm.prank（见 TokenReservation.t 注释）
        uint256 fee = coordinator.creationFee();
        vm.prank(actor);
        (address token, address presale) = coordinator.createToken{value: fee}(_tokenConfig(), salt);
        ghostSalt[token] = salt;
        ghostPresale[token] = presale;
        ghostCreator[token] = actor;
        ghostReleased[token] = 0;
        tokens.push(token);
    }

    function reserve(uint256 saltSeed, uint256 actorSeed) external {
        if (reservedAddrs.length >= MAX_TOKENS) return;
        bytes32 salt = bytes32(uint256(saltSeed % SALT_SPACE));
        address actor = actors[actorSeed % actors.length];
        vm.deal(actor, 1000 ether);
        uint256 fee = coordinator.reservationFee();
        address predicted = tokenFactory.predictTokenAddress(salt);
        vm.prank(actor);
        coordinator.reserveTokenAddress{value: fee}(salt);
        ghostReserver[predicted] = actor;
        reservedAddrs.push(predicted);
    }

    // ------------------------------------------------------------------
    // 预售生命周期（成功线 0.1 BNB / 失败线 3 BNB 双分支）
    // ------------------------------------------------------------------

    function setupPresale(uint256 tokenIdx, uint256 hardBranch) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenIdx % tokens.length];
        PRESALE p = PRESALE(payable(ghostPresale[token]));
        if (p.presaleEnabled() || p.presaleStatus() != 0) return; // 已配置或已推进
        vm.prank(ghostCreator[token]);
        coordinator.setupPresale(token, _presaleConfig(hardBranch % 2 == 0));
    }

    function openPresale(uint256 tokenIdx) external {
        if (tokens.length == 0) return;
        PRESALE p = PRESALE(payable(ghostPresale[tokens[tokenIdx % tokens.length]]));
        if (!p.presaleEnabled() || p.presaleStatus() != 0) return;
        vm.prank(p.owner());
        p.openPresale();
    }

    function subscribe(uint256 tokenIdx, uint256 actorSeed, uint256 amtSeed) external {
        if (tokens.length == 0) return;
        PRESALE p = PRESALE(payable(ghostPresale[tokens[tokenIdx % tokens.length]]));
        if (p.presaleStatus() != 1) return;
        address buyer = actors[actorSeed % actors.length];
        vm.deal(buyer, 1000 ether);
        vm.prank(buyer);
        p.subscribe{value: 0.05 ether + (amtSeed % 50) * 0.01 ether}();
    }

    function endPresale(uint256 tokenIdx) external {
        if (tokens.length == 0) return;
        PRESALE p = PRESALE(payable(ghostPresale[tokens[tokenIdx % tokens.length]]));
        if (p.presaleStatus() != 1) return;
        vm.prank(p.owner());
        p.endPresale();
    }

    function launch(uint256 tokenIdx) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenIdx % tokens.length];
        PRESALE p = PRESALE(payable(ghostPresale[token]));
        if (p.presaleStatus() != 2) return;
        // 真实用户旅程：创建者先把 token 所有权移交托管仓（前端步骤），launch 才能编排迁移
        vm.prank(p.owner());
        FlapTaxTokenV3(token).transferOwnership(address(p));
        _trackExit(token, p, p.owner(), 0);
    }

    function claim(uint256 tokenIdx, uint256 actorSeed) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenIdx % tokens.length];
        PRESALE p = PRESALE(payable(ghostPresale[token]));
        if (p.presaleStatus() != 3) return;
        _trackExit(token, p, actors[actorSeed % actors.length], 1);
    }

    function claimAllTokens(uint256 tokenIdx) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenIdx % tokens.length];
        PRESALE p = PRESALE(payable(ghostPresale[token]));
        if (p.presaleEnabled() || p.presaleStatus() != 0) return; // 纯发币模式（未配置预售）
        _trackExit(token, p, p.owner(), 2);
    }

    function withdrawUnsoldTokens(uint256 tokenIdx, uint256 warpSeed) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenIdx % tokens.length];
        PRESALE p = PRESALE(payable(ghostPresale[token]));
        if (p.presaleStatus() != 3) return;
        uint256 jump = warpSeed % 91 days;
        if (jump > 0) vm.warp(block.timestamp + jump); // 推进 vesting 周期
        _trackExit(token, p, p.owner(), 3);
    }

    function refund(uint256 tokenIdx, uint256 actorSeed) external {
        if (tokens.length == 0) return;
        PRESALE p = PRESALE(payable(ghostPresale[tokens[tokenIdx % tokens.length]]));
        if (p.presaleStatus() != p.STATUS_FAILED()) return;
        vm.prank(actors[actorSeed % actors.length]);
        p.refund(); // 仅 BNB 流，无代币流
    }

    function reclaimTokens(uint256 tokenIdx) external {
        if (tokens.length == 0) return;
        address token = tokens[tokenIdx % tokens.length];
        PRESALE p = PRESALE(payable(ghostPresale[token]));
        if (p.presaleStatus() != p.STATUS_FAILED()) return;
        _trackExit(token, p, p.owner(), 4);
    }

    // ------------------------------------------------------------------
    // ghost 读取口（invariant 校验用）
    // ------------------------------------------------------------------

    function getTokens() external view returns (address[] memory) {
        return tokens;
    }

    function getGhostPresale(address token) external view returns (address) {
        return ghostPresale[token];
    }

    function getGhostReleased(address token) external view returns (uint256) {
        return ghostReleased[token];
    }

    function getGhostSalt(address token) external view returns (bytes32) {
        return ghostSalt[token];
    }

    function getReservedAddrs() external view returns (address[] memory) {
        return reservedAddrs;
    }

    function getGhostReserver(address predicted) external view returns (address) {
        return ghostReserver[predicted];
    }

    // ------------------------------------------------------------------
    // 内部
    // ------------------------------------------------------------------

    /// @dev 执行代币出口动作并记账：流出量 = 仓内余额前后差
    ///      （动作 revert 时整笔调用回滚，ghost 与链上状态同步还原，不会记错账）
    function _trackExit(address token, PRESALE p, address caller, uint8 action) internal {
        uint256 before = IERC20Lite(token).balanceOf(address(p));
        vm.prank(caller);
        if (action == 0) {
            p.launch(); // 20% 底池份额出仓加池
        } else if (action == 1) {
            p.claim();
        } else if (action == 2) {
            p.claimAllTokens(); // 纯发币模式 100% 出仓
        } else if (action == 3) {
            p.withdrawUnsoldTokens();
        } else {
            p.reclaimTokens(); // 失败终态：未售份额全量退回创建者
        }
        ghostReleased[token] += before - IERC20Lite(token).balanceOf(address(p));
    }

    function _presaleConfig(bool hardSoftCap) internal pure returns (PresaleConfig memory) {
        return PresaleConfig({
            presaleTokenPrice: 1e15, // 0.001 BNB/token
            maxBuyPerWallet: 1e8 ether,
            hardcap: 0,
            minLiquidityAmount: 0.1 ether,
            softCap: hardSoftCap ? 3 ether : 0.1 ether, // 高线 → 失败路径；低线 → 成功路径
            startTime: 0,
            vestingDelay: 7 days,
            vestingRate: 10,
            slippage: 0
        });
    }

    function _tokenConfig() internal pure returns (TokenConfig memory) {
        return TokenConfig({
            name: "InvToken",
            symbol: "INV",
            meta: "ipfs://QmInv",
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

contract LaunchpadInvariants is Test {
    CoordinatorFactory coordinator;
    TokenFactory tokenFactory;
    Handler handler;

    function setUp() public {
        FlapTaxTokenV3 flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);
        MockPairFactory pairFactory = new MockPairFactory();
        MockRouterWithFactory router = new MockRouterWithFactory(address(0xAABB), pairFactory);
        Dividend dividendImpl = new Dividend(address(0xAABB), address(0xdead));
        tokenFactory = new TokenFactory(address(flapImpl), address(router), address(0));
        PRESALE presaleTemplate = new PRESALE();
        PresaleFactory presaleFactory = new PresaleFactory(address(presaleTemplate), address(0));
        coordinator = new CoordinatorFactory(
            address(tokenFactory), address(presaleFactory), address(router), address(dividendImpl)
        );

        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        handler = new Handler(coordinator, tokenFactory);
        targetContract(address(handler));
    }

    /// @notice 1. 托管守恒：仓内余额 + 累计流出 == 初始供应（含创建即全量入仓）
    function invariant_EscrowConservation() public view {
        address[] memory tokens = handler.getTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            assertEq(
                IERC20Lite(tokens[i]).balanceOf(handler.getGhostPresale(tokens[i]))
                    + handler.getGhostReleased(tokens[i]),
                SUPPLY,
                "escrow conservation broken"
            );
        }
    }

    /// @notice 2. CREATE2 确定性：盐路径部署地址与预言地址恒等
    function invariant_Create2Determinism() public view {
        address[] memory tokens = handler.getTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            bytes32 salt = handler.getGhostSalt(tokens[i]);
            if (salt == bytes32(0)) continue; // 无盐路径不适用
            assertEq(tokens[i], tokenFactory.predictTokenAddress(salt), "CREATE2 determinism broken");
        }
    }

    /// @notice 3. 预留权属稳定：登记项不被任何调用序列改写
    function invariant_ReservationOwnershipStable() public view {
        address[] memory reserved = handler.getReservedAddrs();
        for (uint256 i = 0; i < reserved.length; i++) {
            assertEq(
                coordinator.tokenAddressReserver(reserved[i]),
                handler.getGhostReserver(reserved[i]),
                "reservation ownership hijacked"
            );
        }
    }
}
