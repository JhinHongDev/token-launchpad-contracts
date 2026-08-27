// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {CoordinatorFactory} from "src/CoordinatorFactory.sol";
import {TokenConfig} from "src/TokenFactory.sol";
import {PRESALE} from "src/Presale.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {TaxProcessor} from "src/TaxProcessor.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";
import {IPancakeRouter02} from "src/lib/interfaces/IPancakeRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

address constant COORDINATOR_ADDR = 0x3Ee493AfFb9f70756D9c04DdE35C66E03F973D37;
address constant ROUTER_ADDR = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;

/// @notice 分红全流程端到端自动化测试脚本
contract TestDividendFlow is Script {
    IPancakeRouter02 constant router = IPancakeRouter02(ROUTER_ADDR);
    CoordinatorFactory constant coordinator = CoordinatorFactory(COORDINATOR_ADDR);

    /// @notice 一键端到端全流程（读取 .env 中的 PRIVATE_KEY 和 RETAIL_PRIVATE_KEY）
    function run() external {
        uint256 creatorKey = vm.envUint("CREATOR_PRIVATE_KEY");
        uint256 retailKey = vm.envUint("RETAIL_PRIVATE_KEY");
        address creator = vm.addr(creatorKey);
        address retail = vm.addr(retailKey);
        address wbnb = router.WETH();

        console2.log("===============================================================");
        console2.log(unicode"🚀 [开始全流程测试] 新代币分红机制端到端验证");
        console2.log(unicode"发币者钱包 (Creator):", creator);
        console2.log(unicode"散户钱包   (Retail): ", retail);
        console2.log(unicode"WBNB 路由器地址:      ", wbnb);
        console2.log("===============================================================");

        // 阶段 1: 发币、加池、配资给散户
        (address tokenAddr, address dividendAddr) = _step1_deployAndFund(creatorKey, creator, retail);

        // 阶段 2: 两次交易（累积税收 -> 触发清算 -> dispatch 派发）
        _step2_tradeAndDispatch(creatorKey, creator, tokenAddr, dividendAddr, wbnb, retail);

        // 阶段 3: 散户签名提领分红
        _step3_retailClaim(retailKey, retail, dividendAddr);
    }

    function _step1_deployAndFund(uint256 creatorKey, address creator, address retail)
        internal
        returns (address tokenAddr, address dividendAddr)
    {
        console2.log(unicode"\n>>> [阶段 1] 发币与初始化底池流动性...");
        vm.startBroadcast(creatorKey);

        if (retail.balance < 0.0005 ether) {
            console2.log(unicode"正在向散户钱包转入 0.0005 BNB 作为 Gas 费...");
            payable(retail).transfer(0.0005 ether);
        }

        address presaleAddr;
        (tokenAddr, presaleAddr) = coordinator.createToken{value: 0.001 ether}(
            TokenConfig({
                name: "DividendTestToken",
                symbol: "DIVTEST",
                meta: "ipfs://QmDividendTestToken",
                buyTax: 500, // 5% 买税
                sellTax: 500, // 5% 卖税
                feeRecipient: creator,
                marketAddress: creator,
                taxDuration: 30 days,
                antiFarmerDuration: 0,
                liqExpectedOutputAmount: 0,
                marketBps: 0,
                deflationBps: 0,
                dividendBps: 10000, // 100% 分红通道
                lpBps: 0,
                minHolderBalance: 1000 ether // 最低持仓 1000 DIVTEST
            }),
            bytes32(0) // 默认随机地址路径
        );

        PRESALE(payable(presaleAddr)).claimAllTokens();
        FlapTaxTokenV3 token = FlapTaxTokenV3(payable(tokenAddr));
        token.startMigration();

        // 创建者加池 5 亿代币 + 0.001 BNB
        token.approve(ROUTER_ADDR, 500_000_000 ether);
        router.addLiquidityETH{value: 0.001 ether}(
            tokenAddr,
            500_000_000 ether,
            0,
            0,
            creator,
            block.timestamp + 300
        );
        token.finalizeMigration();

        // 转账 50,000,000 代币给散户
        token.transfer(retail, 50_000_000 ether);
        vm.stopBroadcast();

        dividendAddr = coordinator.tokenDividends(tokenAddr);
        (uint256 share,,) = Dividend(payable(dividendAddr)).userInfo(retail);

        console2.log(unicode"✅ 代币部署成功:", tokenAddr);
        console2.log(unicode"✅ 分红合约地址:", dividendAddr);
        console2.log(unicode"✅ 散户代币余额:", token.balanceOf(retail) / 1e18, "DIVTEST");
        console2.log(unicode"✅ Dividend 合约记录散户 Shares:", share / 1e18);
    }

    function _step2_tradeAndDispatch(
        uint256 creatorKey,
        address creator,
        address tokenAddr,
        address dividendAddr,
        address wbnb,
        address retail
    ) internal {
        console2.log(unicode"\n>>> [阶段 2] 触发 DEX 交易产生税收并清算派发...");
        FlapTaxTokenV3 token = FlapTaxTokenV3(payable(tokenAddr));
        TaxProcessor processor = TaxProcessor(payable(token.taxProcessor()));

        vm.startBroadcast(creatorKey);

        // 交易 1: 卖出 2.5 亿代币，扣税 5%（1250 万代币）存入合约
        token.approve(ROUTER_ADDR, 260_000_000 ether);
        address[] memory path = new address[](2);
        path[0] = tokenAddr;
        path[1] = wbnb;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens{gas: 800000}(
            250_000_000 ether,
            0,
            path,
            creator,
            block.timestamp + 300
        );
        console2.log(unicode"第一笔交易完成，代币合约已扣税存入:", token.balanceOf(tokenAddr) / 1e18, "DIVTEST");

        // 交易 2: 卖出 100 万代币，由于上笔已积攒 1250 万（>= 1000 万清算阈值），此笔交易自动触发清算 swap 成 WBNB！
        router.swapExactTokensForETHSupportingFeeOnTransferTokens{gas: 800000}(
            1_000_000 ether,
            0,
            path,
            creator,
            block.timestamp + 300
        );

        uint256 pendingWBNB = processor.pendingDividendQuoteTokenBalance();
        console2.log(unicode"第二笔交易触发自动清算！TaxProcessor 已到账待分红 WBNB:", pendingWBNB);

        // 执行 dispatch 充入分红池
        processor.dispatch{gas: 500000}();
        vm.stopBroadcast();

        uint256 claimable = Dividend(payable(dividendAddr)).withdrawableDividends(retail);
        console2.log(unicode"✅ 分红池当前 WBNB 余额:", IERC20(wbnb).balanceOf(dividendAddr));
        console2.log(unicode"✅ 散户当前实时可提领 BNB:", claimable, "wei");
    }

    function _step3_retailClaim(uint256 retailKey, address retail, address dividendAddr) internal {
        console2.log(unicode"\n>>> [阶段 3] 散户钱包签名提领 BNB 分红...");
        Dividend dividend = Dividend(payable(dividendAddr));
        uint256 bnbBefore = retail.balance;

        vm.startBroadcast(retailKey);
        dividend.withdrawDividends{gas: 500000}();
        vm.stopBroadcast();

        console2.log("===============================================================");
        console2.log(unicode"🎉 [测试大获成功！] 验证结果:");
        console2.log(unicode"散户提领前 BNB 余额:  ", bnbBefore);
        console2.log(unicode"散户提领后 BNB 余额:  ", retail.balance);
        console2.log(unicode"散户已累计提领 BNB 额度:", dividend.withdrawnDividends(retail));
        console2.log("===============================================================");
    }
}
