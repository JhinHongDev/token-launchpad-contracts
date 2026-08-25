// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice EIP-1167 极简代理克隆。
/// @dev 使用 CREATE 而非 create2：地址由 (调用方, nonce) 唯一决定，
///      同一调用方在同一交易内多次克隆不会盐值碰撞
///      （create2 + 时间戳盐方案在用户同区块连发两币时会 CloneFailed）。
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
}
