// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {IFlapTaxTokenV3} from "src/lib/interfaces/IFlapTaxTokenV3.sol";
import {PRESALE, NothingToClaim, TokensAlreadyClaimed, InvalidVestingDelay} from "src/Presale.sol";

interface IERC20Sim {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

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
        IERC20Sim(token).transferFrom(msg.sender, to, amountTokenDesired);
        return (amountTokenDesired, msg.value, 1e18);
    }
}

contract DummyTaxProcessor {}

contract LaunchpadTest is Test {
    address constant LP_DEAD = address(0xdead);
    uint256 constant SUPPLY = 1e6 ether; // FlapTaxTokenV3 maxSupply

    FlapTaxTokenV3 token;
    PRESALE presale;
    MockRouter router;
    address pair = address(0x1111);
    uint256 creatorShare = SUPPLY * 30 / 100;
    uint256 poolShare = SUPPLY * 20 / 100;
    uint256 presaleShare = SUPPLY * 50 / 100;

    function setUp() public {
        router = new MockRouter();
        vm.deal(address(this), 100 ether);
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

    function test_FullLaunchFlow() public {
        address alice = address(0x1234);
        vm.deal(alice, 10 ether);

        // ===== 认购 =====
        presale.openPresale();
        vm.prank(alice);
        presale.subscribe{value: 1 ether}(); // 1 BNB → 1000 ether 代币

        assertEq(presale.accumulatedBNB(), 1 ether);
        assertEq(presale.subscribedTokens(alice), 1000 ether);
        assertEq(presale.totalSubscribedTokens(), 1000 ether);
        assertEq(token.balanceOf(address(presale)), SUPPLY);

        presale.endPresale();

        // ===== 开盘（自动迁移三步）=====
        assertEq(uint8(token.state()), 0); // BondingCurve
        presale.launch();

        // 迁移完成：税态 + token 无主 + LP 死锁
        assertEq(uint8(token.state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer));
        assertEq(token.owner(), address(0));
        assertEq(token.balanceOf(LP_DEAD), poolShare); // LP 侧代币已死锁黑洞
        assertEq(presale.liquidityAdded(), true);
        assertEq(presale.presaleStatus(), 3);

        // ===== vesting 领取（散户 alice）=====
        vm.warp(block.timestamp + 7 days + 1);
        uint256 claimable = presale.getVestedAmount(alice); // 散户 1000ether 的 10%
        assertEq(claimable, 100 ether);

        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(presale.claimedTokens(alice), 100 ether);

        // 第二个周期再领；视图应报告“下一个”释放边界而非首个周期边界
        vm.warp(block.timestamp + 7 days);
        (,, uint256 aliceClaimed, uint256 nextVestingTime) = presale.getUserVestingStatus(alice);
        assertEq(aliceClaimed, 100 ether);
        assertEq(nextVestingTime, presale.vestingStart() + 3 * 7 days, "next boundary, not first");
        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 200 ether);

        // 创建者 30% 同套 vesting 可领（此时已过 3 个周期 → 30%）
        vm.warp(block.timestamp + 7 days);
        uint256 creatorClaimable = presale.getVestedAmount(address(this));
        assertEq(creatorClaimable, (creatorShare * 3) / 10);
        presale.claim();
        assertEq(token.balanceOf(address(this)), (creatorShare * 3) / 10);
    }

    /// @dev testnet 分支标定回归：vestingDelay 下限放宽至 1 分钟（主网口径 7 天）。
    ///      低于 1 分钟仍拒绝；1 分钟周期端到端走通：认购 → 开盘 → 过满 1 周期领取
    function test_VestingDelayTestnetFloor() public {
        vm.expectRevert(InvalidVestingDelay.selector);
        presale.setVestingConfig(30 seconds, 10);

        presale.setVestingConfig(1 minutes, 10);
        assertEq(presale.vestingDelay(), 1 minutes);

        address alice = address(0x1234);
        vm.deal(alice, 10 ether);
        presale.openPresale();
        vm.prank(alice);
        presale.subscribe{value: 1 ether}();
        presale.endPresale();
        presale.launch();

        // 过满 1 个 1 分钟周期 → 散户 1000 ether 份额 × 10% 解锁
        vm.warp(block.timestamp + 1 minutes + 1);
        assertEq(presale.getVestedAmount(alice), 100 ether);
        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function test_WithdrawUnsoldTokensVested() public {
        address alice = address(0x1234);
        vm.deal(alice, 10 ether);

        presale.openPresale();
        vm.prank(alice);
        presale.subscribe{value: 1 ether}(); // 卖出 1000 ether，未售 = presaleShare - 1000 ether
        presale.endPresale();
        presale.launch();

        uint256 unsold = presaleShare - 1000 ether;

        // launch 后立即提取：vesting 未开始 → 无配额
        vm.expectRevert(NothingToClaim.selector);
        presale.withdrawUnsoldTokens();

        // 第 1 个周期（7 天）：提取 10%
        vm.warp(block.timestamp + 7 days + 1);
        uint256 balanceBefore = token.balanceOf(address(this));
        presale.withdrawUnsoldTokens();
        assertEq(token.balanceOf(address(this)), balanceBefore + (unsold * 10) / 100);
        assertEq(presale.unsoldWithdrawn(), (unsold * 10) / 100);

        // 第 2 个周期：再 10%
        vm.warp(block.timestamp + 7 days);
        presale.withdrawUnsoldTokens();
        assertEq(presale.unsoldWithdrawn(), (unsold * 20) / 100);

        // 散户份额不受影响：此时已过 2 个周期，领取 2 期
        vm.prank(alice);
        presale.claim();
        assertEq(token.balanceOf(alice), 200 ether);
    }

    function test_NoPresaleClaimAll() public {
        FlapTaxTokenV3 token2 = _freshToken();

        PRESALE p = new PRESALE();
        p.initialize(address(this), address(router));
        p.configureLaunch(false, address(0), 0, 0, 0);
        p.setCoinAndPair(address(token2), pair);
        token2.transfer(address(p), SUPPLY);
        token2.transferOwnership(address(p)); // createToken 时所有权即交托管仓

        p.claimAllTokens();
        assertEq(token2.balanceOf(address(this)), SUPPLY);
        assertEq(p.tokensClaimed(), true);

        // 领取即上线：迁移三步 + renounce 同笔完成，税按发币配置即时生效
        assertEq(uint8(token2.state()), uint8(IFlapTaxTokenV3.PoolState.TaxEnforcedAntiFarmer));
        assertEq(token2.owner(), address(0));

        // 池转账解锁：BondingCurve 拦截不复存在；转池按卖向计税（sellTax 500 bps）
        token2.transfer(pair, 100 ether);
        assertEq(token2.balanceOf(pair), 95 ether);
        assertEq(token2.balanceOf(address(token2)), 5 ether, "sell tax accrued in tax vault");

        // 出口封闭：二次领取拒绝
        vm.expectRevert(TokensAlreadyClaimed.selector);
        p.claimAllTokens();
    }

    // 无论测试台如何使用，合约必须能接收 BNB（MockRouter addLiquidityETH 等场景）
    receive() external payable {}

    function _freshToken() internal returns (FlapTaxTokenV3) {
        // EIP-1167 克隆（构造函数不执行，initialize 可用）
        FlapTaxTokenV3 impl = new FlapTaxTokenV3(5e3 ether, 1e4 ether);
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

    function _clone(address implementation) internal returns (address instance) {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, address(this)));
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
