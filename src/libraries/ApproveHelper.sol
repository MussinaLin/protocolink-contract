// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IERC20Usdt {
    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external;
}

/// @title Approve helper
/// @notice Contains helper methods for interacting with ERC20 tokens that have inconsistent implementation
library ApproveHelper {
    function _approveMax(address token, address to, uint256 amount) internal {
        if (IERC20Usdt(token).allowance(address(this), to) < amount) {
            try IERC20Usdt(token).approve(to, type(uint256).max) {} catch {
                IERC20Usdt(token).approve(to, 0);
                IERC20Usdt(token).approve(to, type(uint256).max);
            }
        }
    }

    function _approve(address token, address to, uint256 amount) internal {
        try IERC20Usdt(token).approve(to, amount) {} catch {
            IERC20Usdt(token).approve(to, 0);
            IERC20Usdt(token).approve(to, amount);
        }
    }

    function _approveZero(address token, address to) internal {
        if (IERC20Usdt(token).allowance(address(this), to) > 0) {
            try IERC20Usdt(token).approve(to, 0) {} catch {
                IERC20Usdt(token).approve(to, 1);
            }
        }
    }
}
