// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice EIP-1167 极简代理克隆库，双部署路径：
/// @dev    - `clone`（CREATE，无盐）：默认路径。地址由 (调用方, nonce) 唯一决定，
///           同一调用方在同一交易内多次克隆天然不会碰撞，无需任何盐管理；
///         - `cloneDeterministic`（CREATE2）：确定性路径，供"付费预留 CA / 五连 8 靓号"使用。
///           地址 = keccak256(0xff ‖ deployer ‖ salt ‖ keccak256(initcode))[12:]（OpenZeppelin 同款公式），
///           可在链下预计算后落位；盐由调用方显式提供、上层以预留登记做占位互斥，
///           不依赖时间戳等易碰撞输入（同区块连发多币场景安全）。
///           安全注记：确定性路径只搜索盐值、部署方恒为固定合约（TokenFactory），
///           不涉及任何私钥生成，结构性规避 Profanity 类 vanity 私钥工具的熵缺陷风险。
library Clones {
    error CloneFailed();

    function clone(address implementation) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert CloneFailed();
    }

    /// @notice CREATE2 确定性克隆：initcode 与 `clone` 完全一致（EIP-1167 模板），仅换用 create2 落位。
    ///         目标地址已含代码时返回 0 并回滚（EIP-684，天然防重复部署）。
    function cloneDeterministic(address implementation, bytes32 salt) internal returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0)) revert CloneFailed();
    }

    /// @notice 预言 `cloneDeterministic` 的落位地址。deployer 必须是最终实际执行克隆的合约地址，
    ///         否则预言无效（上层封装见 TokenFactory.predictTokenAddress）。
    /// @dev 装配逻辑与 OpenZeppelin Clones 同款：initcode 内嵌于 preimage 缓冲区，
    ///      最终哈希窗口自 0x43 起、长 0x55 字节。
    function predictDeterministicAddress(address implementation, bytes32 salt, address deployer)
        internal
        pure
        returns (address predicted)
    {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x38), deployer)
            mstore(add(ptr, 0x24), 0x5af43d82803e903d91602b57fd5bf3ff)
            mstore(add(ptr, 0x14), implementation)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73)
            mstore(add(ptr, 0x58), salt)
            mstore(add(ptr, 0x78), keccak256(add(ptr, 0x0c), 0x37))
            // CREATE2 地址取哈希低 20 字节（h[12:]）：赋给 address 变量自动截断，与 OZ 同款
            predicted := keccak256(add(ptr, 0x43), 0x55)
        }
    }
}
