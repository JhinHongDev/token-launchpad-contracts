// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PRESALE} from "src/Presale.sol";
import {Clones} from "src/Clones.sol";

// ---------------------------------------------------------------------------
// 自定义错误
// ---------------------------------------------------------------------------

// ============================================================================
// PresaleFactory - 轻量克隆版 PRESALE（仅作托管仓创建；预售配置见 CoordinatorFactory.setupPresale）
// ============================================================================

struct PresaleConfig {
    uint256 presaleTokenPrice; // BNB per token（wei）
    uint256 maxBuyPerWallet;
    uint256 hardcap;
    uint256 minLiquidityAmount;
    uint256 softCap; // 认购成功线：必须 ≥ minLiquidityAmount，否则 endPresale 判失败开放退款
    uint256 startTime;
    uint256 vestingDelay;
    uint256 vestingRate;
    uint256 slippage;
}

contract PresaleFactory is AccessControl {
    bytes32 public constant COORDINATOR_ROLE = keccak256("COORDINATOR_ROLE");

    address public immutable presaleImplementation;

    event PresaleCreated(address indexed presale, address indexed creator);

    constructor(address _presaleImplementation, address _coordinator) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COORDINATOR_ROLE, _coordinator);
        presaleImplementation = _presaleImplementation;
    }

    /// @dev 克隆并创建未配置的托管仓（owner=工厂，配置完成后移交上层）。
    ///      预售各项配置（份额/价格/vesting）由 CoordinatorFactory.setupPresale 完成。
    function createPresale(address _router) external onlyRole(COORDINATOR_ROLE) returns (address) {
        address presaleAddress = Clones.clone(presaleImplementation);
        PRESALE presale = PRESALE(payable(presaleAddress));

        presale.initialize(address(this), _router); // owner = 工厂（配置期间），末尾移交
        presale.configureLaunch(false, address(0), 0, 0, 0); // 纯托管模式

        // 配置完成，所有权移交上层（Coordinator），由其再转给创建者
        presale.transferOwnership(msg.sender);

        emit PresaleCreated(presaleAddress, msg.sender);
        return presaleAddress;
    }
}
