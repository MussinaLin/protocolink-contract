// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {SafeERC20, IERC20, Address} from 'openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {ERC721Holder} from 'openzeppelin-contracts/contracts/token/ERC721/utils/ERC721Holder.sol';
import {ERC1155Holder} from 'openzeppelin-contracts/contracts/token/ERC1155/utils/ERC1155Holder.sol';

import {IAgent} from './interfaces/IAgent.sol';
import {IParam} from './interfaces/IParam.sol';
import {IRouter} from './interfaces/IRouter.sol';
import {IFeeCalculator} from './interfaces/IFeeCalculator.sol';
import {IWrappedNative} from './interfaces/IWrappedNative.sol';
import {ApproveHelper} from './libraries/ApproveHelper.sol';

/// @title Implementation contract of agent logics
contract AgentImplementation is IAgent, ERC721Holder, ERC1155Holder {
    using SafeERC20 for IERC20;
    using Address for address;
    using Address for address payable;

    event FeeCharged(address indexed token, uint256 amount);

    address private constant _NATIVE = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    bytes4 private constant _NATIVE_FEE_SELECTOR = 0xeeeeeeee;
    address private constant _DUMMY_ERC20_TOKEN = address(0xe20); // For ERC20 transferFrom charge fee using
    uint256 private constant _BPS_BASE = 10_000;
    uint256 private constant _SKIP = type(uint256).max;

    address public immutable router;
    address public immutable wrappedNative;

    address private _caller;

    modifier checkCaller() {
        address caller = _caller;
        if (caller != msg.sender) {
            // Only predefined caller can call agent
            revert InvalidCaller();
        } else if (caller != router) {
            // When the caller is not router, should be reset right away to guarantee one-time usage from callback contracts
            _caller = router;
        }
        _;
    }

    constructor(address wrappedNative_) {
        router = msg.sender;
        wrappedNative = wrappedNative_;
    }

    function initialize() external {
        if (_caller != address(0)) revert Initialized();
        _caller = router;
    }

    /// @notice Execute logics and return tokens to user
    function execute(
        IParam.Logic[] calldata logics,
        address[] calldata tokensReturn,
        bool isFeeEnabled
    ) external payable checkCaller {
        address feeCollector;
        if (isFeeEnabled) feeCollector = IRouter(router).feeCollector();

        // Execute each logic
        uint256 logicsLength = logics.length;
        for (uint256 i = 0; i < logicsLength; ) {
            address to = logics[i].to;
            bytes memory data = logics[i].data;
            IParam.Input[] calldata inputs = logics[i].inputs;
            IParam.WrapMode wrapMode = logics[i].wrapMode;
            address approveTo = logics[i].approveTo;
            address callback = logics[i].callback;

            // Default `approveTo` is same as `to` unless `approveTo` is set
            if (approveTo == address(0)) {
                approveTo = to;
            }

            // Execute each input if need to modify the amount or do approve
            uint256 value;
            uint256 wrappedAmount;
            uint256 inputsLength = inputs.length;
            for (uint256 j = 0; j < inputsLength; ) {
                address token = inputs[j].token;
                uint256 amountBps = inputs[j].amountBps;

                // Calculate native or token amount
                // 1. if amountBps is skip: read amountOrOffset as amount
                // 2. if amountBps isn't skip: balance multiplied by amountBps as amount
                uint256 amount;
                if (amountBps == _SKIP) {
                    amount = inputs[j].amountOrOffset;
                } else {
                    if (amountBps == 0 || amountBps > _BPS_BASE) revert InvalidBps();

                    if (token == address(wrappedNative) && wrapMode == IParam.WrapMode.WRAP_BEFORE) {
                        // Use the native balance for amount calculation as wrap will be executed later
                        amount = (address(this).balance * amountBps) / _BPS_BASE;
                    } else {
                        amount = (_getBalance(token) * amountBps) / _BPS_BASE;
                    }

                    // Skip if don't need to replace, e.g., most protocols set native amount in call value
                    uint256 offset = inputs[j].amountOrOffset;
                    if (offset != _SKIP) {
                        // Replace the amount at offset in data with the calculated amount
                        assembly {
                            let loc := add(add(data, 0x24), offset) // 0x24 = 0x20(data_length) + 0x4(sig)
                            mstore(loc, amount)
                        }
                    }
                }

                if (wrapMode == IParam.WrapMode.WRAP_BEFORE) {
                    // Use += to accumulate amounts with multiple WRAP_BEFORE, although such cases are rare
                    wrappedAmount += amount;
                }

                if (token == _NATIVE) {
                    value += amount;
                } else if (token != approveTo) {
                    ApproveHelper._approveMax(token, approveTo, amount);
                }

                unchecked {
                    ++j;
                }
            }

            if (wrapMode == IParam.WrapMode.WRAP_BEFORE) {
                // Wrap native before the call
                IWrappedNative(wrappedNative).deposit{value: wrappedAmount}();
            } else if (wrapMode == IParam.WrapMode.UNWRAP_AFTER) {
                // Or store the before wrapped native amount for calculation after the call
                wrappedAmount = _getBalance(wrappedNative);
            }

            // Set _callback who should enter one-time execute
            if (callback != address(0)) _caller = callback;

            // Execute and send native
            if (data.length == 0) {
                payable(to).sendValue(value);
            } else {
                to.functionCallWithValue(data, value, 'ERROR_ROUTER_EXECUTE');
            }

            // Revert if the previous call didn't enter execute
            if (_caller != router) revert UnresetCallback();

            // Unwrap to native after the call
            if (wrapMode == IParam.WrapMode.UNWRAP_AFTER) {
                IWrappedNative(wrappedNative).withdraw(_getBalance(wrappedNative) - wrappedAmount);
            }

            // Charge fees
            if (isFeeEnabled) {
                _chargeFee(to, data, feeCollector);
            }

            unchecked {
                ++i;
            }
        }

        // Charge native token fee
        if (isFeeEnabled && msg.value > 0) {
            _chargeNativeFee(feeCollector);
        }

        // Push tokensReturn if any balance
        uint256 tokensReturnLength = tokensReturn.length;
        if (tokensReturnLength > 0) {
            address user = IRouter(router).user();
            for (uint256 i = 0; i < tokensReturnLength; ) {
                address token = tokensReturn[i];
                if (token == _NATIVE) {
                    payable(user).sendValue(address(this).balance);
                } else {
                    uint256 balance = IERC20(token).balanceOf(address(this));
                    IERC20(token).safeTransfer(user, balance);
                }

                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Check transaction `data` and charge fee
    function _chargeFee(address to, bytes memory data, address feeCollector) private {
        bytes4 selector = bytes4(data);
        address feeCalculator = IRouter(router).feeCalculators(selector);
        if (feeCalculator != address(0)) {
            // Get charge tokens and fees
            (address[] memory tokens, uint256[] memory fees) = IFeeCalculator(feeCalculator).getFees(data);
            uint256 length = tokens.length;
            for (uint256 i = 0; i < length; ) {
                uint256 fee = fees[i];
                if (fee > 0) {
                    address token = tokens[i];
                    if (token == _DUMMY_ERC20_TOKEN) token = to; // ERC20 transferFrom case

                    IERC20(token).safeTransfer(feeCollector, fee);
                    emit FeeCharged(token, fee);
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _chargeNativeFee(address feeCollector) private {
        address feeCalculator = IRouter(router).feeCalculators(_NATIVE_FEE_SELECTOR);
        if (feeCalculator != address(0)) {
            (, uint256[] memory fees) = IFeeCalculator(feeCalculator).getFees(abi.encodePacked(msg.value));
            uint256 nativeFee = fees[0];
            if (nativeFee > 0) {
                payable(feeCollector).sendValue(nativeFee);
                emit FeeCharged(_NATIVE, nativeFee);
            }
        }
    }

    function _getBalance(address token) private view returns (uint256 balance) {
        if (token == _NATIVE) {
            balance = address(this).balance;
        } else {
            balance = IERC20(token).balanceOf(address(this));
        }
    }
}
