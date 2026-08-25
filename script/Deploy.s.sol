// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {FlapTaxTokenV3} from "src/lib/token/FlapTaxTokenV3.sol";
import {Dividend} from "src/lib/dividend/Dividend.sol";
import {PRESALE} from "src/Presale.sol";
import {TokenFactory} from "src/TokenFactory.sol";
import {PresaleFactory} from "src/PresaleFactory.sol";
import {CoordinatorFactory} from "src/CoordinatorFactory.sol";

// BSC 测试网
address constant ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
address constant WBNB = 0xae13d989dac2F0DcefF4b7F04D71cC9F9f3d33b7;

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        // FlapTaxTokenV3 实现：MIN=0.5% 供应量(5e6 ether)，START=1%(1e7 ether)
        FlapTaxTokenV3 flapImpl = new FlapTaxTokenV3(5e6 ether, 1e7 ether);

        // Dividend 实现：WBNB 为分红代币（withdraw 时自动解包原生 BNB），黑洞排除
        Dividend dividendImpl = new Dividend(WBNB, address(0xdead));

        // 工厂与 Coordinator 存在循环引用：先建工厂（coordinator 占位 0），建好 Coordinator 后授权
        TokenFactory tokenFactory = new TokenFactory(address(flapImpl), ROUTER, address(0));

        PRESALE presaleTemplate = new PRESALE();
        PresaleFactory presaleFactory = new PresaleFactory(address(presaleTemplate), address(0));

        CoordinatorFactory coordinator =
            new CoordinatorFactory(address(tokenFactory), address(presaleFactory), ROUTER, address(dividendImpl));

        tokenFactory.grantRole(tokenFactory.COORDINATOR_ROLE(), address(coordinator));
        presaleFactory.grantRole(presaleFactory.COORDINATOR_ROLE(), address(coordinator));

        console2.log("FlapTaxTokenV3 impl:", address(flapImpl));
        console2.log("Dividend impl:", address(dividendImpl));
        console2.log("TokenFactory:", address(tokenFactory));
        console2.log("PRESALE template:", address(presaleTemplate));
        console2.log("PresaleFactory:", address(presaleFactory));
        console2.log("CoordinatorFactory:", address(coordinator));

        vm.stopBroadcast();
    }
}
