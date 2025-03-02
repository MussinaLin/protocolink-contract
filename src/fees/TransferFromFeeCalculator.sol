// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {FeeBase} from './FeeBase.sol';
import {IFeeCalculator} from '../interfaces/IFeeCalculator.sol';

/// @notice Fee calculator for ERC20::transferFrom action. This will also cause ERC721::transferFrom being executed and fail in transaction.
contract TransferFromFeeCalculator is IFeeCalculator, FeeBase {
    address private constant _DUMMY_ERC20_TOKEN = address(0xe20);

    constructor(address router, uint256 feeRate) FeeBase(router, feeRate) {}

    function getFees(bytes calldata data) external view returns (address[] memory, uint256[] memory) {
        // Token transfrom signature:'transferFrom(address,address,uint256)', selector:0x23b872dd
        (, , uint256 amount) = abi.decode(data, (address, address, uint256));

        address[] memory tokens = new address[](1);
        tokens[0] = _DUMMY_ERC20_TOKEN; // The token address is `to` calling contract address. Return a dummy address here

        uint256[] memory fees = new uint256[](1);
        fees[0] = calculateFee(amount);
        return (tokens, fees);
    }

    function getDataWithFee(bytes calldata data) external view returns (bytes memory) {
        (address from, address to, uint256 amount) = abi.decode(data, (address, address, uint256));
        amount = calculateAmountWithFee(amount);
        return abi.encode(from, to, amount);
    }
}
