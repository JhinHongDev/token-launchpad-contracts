// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @notice 安全转账辅助库：校验 ERC20 / ETH 转账真实成功（兼容无返回值与返回 false 的旧代币实现）
/// @dev 与 OZ SafeERC20 等价，但失败信息采用参数化 Custom Error（项目规范：弃用字符串错误）
library TransferHelper {
    error ApproveFailed(address token, address spender);
    error TransferFailed(address token, address to);
    error TransferFromFailed(address token, address from, address to);
    error ETHTransferFailed(address to);

    function safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, to, value));
        if (!(success && (data.length == 0 || abi.decode(data, (bool))))) revert ApproveFailed(token, to);
    }

    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, value));
        if (!(success && (data.length == 0 || abi.decode(data, (bool))))) revert TransferFailed(token, to);
    }

    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value));
        if (!(success && (data.length == 0 || abi.decode(data, (bool))))) {
            revert TransferFromFailed(token, from, to);
        }
    }

    function safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        if (!success) revert ETHTransferFailed(to);
    }
}
