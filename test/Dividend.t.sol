// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice 可解包的原生币模拟 WBNB：withdraw 销毁并退回原生 BNB
contract MockWBNB is MockERC20 {
    constructor() MockERC20("WBNB", "WBNB") {}

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}

contract DividendTest is Test {
    MockERC20 taxToken;
    MockWBNB wbnb;
    Dividend impl;
    Dividend dividend;

    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    uint256 constant MIN_SHARE = 100 ether;

    function setUp() public {
        taxToken = new MockERC20("Tax", "TAX");
        wbnb = new MockWBNB();
        impl = new Dividend(address(wbnb), address(0xdead));

        dividend = Dividend(payable(_clone(address(impl))));
        dividend.initialize(address(wbnb), address(taxToken), MIN_SHARE);

        // 注册份额（仅税代币可调用）
        vm.prank(address(taxToken));
        dividend.setShare(alice, 300 ether); // 达标
        vm.prank(address(taxToken));
        dividend.setShare(bob, 100 ether); // 恰好达标

        // WBNB 合约需持有原生币以支持解包
        vm.deal(address(wbnb), 1000 ether);
    }

    function test_ProportionalDistribution() public {
        wbnb.mint(address(this), 400 ether);
        wbnb.approve(address(dividend), 400 ether);
        assertTrue(dividend.deposit(400 ether));

        assertEq(dividend.withdrawableDividends(alice), 300 ether); // 3/4
        assertEq(dividend.withdrawableDividends(bob), 100 ether); // 1/4
    }

    function test_MinimumShareBalanceGate() public {
        address carol = address(0xc0);
        vm.prank(address(taxToken));
        dividend.setShare(carol, MIN_SHARE - 1 wei); // 差 1 wei 不达标 → 份额归零

        (uint256 carolShare,,) = dividend.userInfo(carol);
        assertEq(carolShare, 0);
        assertEq(dividend.totalShares(), 400 ether); // carol 未计入

        wbnb.mint(address(this), 400 ether);
        wbnb.approve(address(dividend), 400 ether);
        dividend.deposit(400 ether);

        assertEq(dividend.withdrawableDividends(carol), 0);

        // 提高持仓过线后，下次转账登记即可获得份额
        vm.prank(address(taxToken));
        dividend.setShare(carol, MIN_SHARE);
        assertEq(dividend.totalShares(), 400 ether + MIN_SHARE);
    }

    function test_WithdrawUnwrapsToNativeBNB() public {
        wbnb.mint(address(this), 400 ether);
        wbnb.approve(address(dividend), 400 ether);
        dividend.deposit(400 ether);

        uint256 bnbBefore = alice.balance;
        vm.prank(alice);
        assertTrue(dividend.withdrawDividends());

        assertEq(alice.balance, bnbBefore + 300 ether); // 收到原生 BNB
        assertEq(wbnb.balanceOf(address(dividend)), 100 ether); // WBNB 已解包销毁
        assertEq(dividend.withdrawableDividends(alice), 0);
        assertEq(dividend.withdrawnDividends(alice), 300 ether);
    }

    function test_ExcludeAddressResetsShare() public {
        assertEq(dividend.totalShares(), 400 ether);
        dividend.excludeAddress(bob); // owner（测试合约）操作
        assertEq(dividend.totalShares(), 300 ether);
        (uint256 bobShare,,) = dividend.userInfo(bob);
        assertEq(bobShare, 0);
    }

    function test_DepositReturnsFalseWhenNoShares() public {
        Dividend empty = Dividend(payable(_clone(address(impl))));
        empty.initialize(address(wbnb), address(taxToken), 0);

        wbnb.mint(address(this), 10 ether);
        wbnb.approve(address(empty), 10 ether);
        assertFalse(empty.deposit(10 ether)); // 无份额人 → false，不转入
        assertEq(wbnb.balanceOf(address(empty)), 0);
    }

    function test_SetShareOnlyTaxToken() public {
        vm.prank(alice);
        vm.expectRevert("Dividend: caller is not the tax token");
        dividend.setShare(alice, 1 ether);
    }

    // EIP-1167 克隆辅助
    function _clone(address implementation) internal returns (address instance) {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, gasleft()));
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "clone failed");
    }

    receive() external payable {}
}
