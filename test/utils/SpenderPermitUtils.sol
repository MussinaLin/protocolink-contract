// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';
import {SafeERC20, IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {IAgent} from 'src/interfaces/IAgent.sol';
import {Router, IRouter} from 'src/Router.sol';
import {IParam} from 'src/interfaces/IParam.sol';
import {IAllowanceTransfer} from 'permit2/interfaces/IAllowanceTransfer.sol';
import {PermitSignature} from './permit2/PermitSignature.sol';
import {EIP712} from './permit2/Permit2EIP712.sol';

contract SpenderPermitUtils is Test, PermitSignature {
    using SafeERC20 for IERC20;

    uint256 public constant SIGNER_REFERRAL = 1;
    address internal constant permit2Addr = address(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    address private _user;
    address private _spender;
    uint256 private _userPrivateKey;
    IRouter private _router;
    bytes32 DOMAIN_SEPARATOR;

    function spenderSetUp(address user_, uint256 userPrivateKey_, IRouter router_, IAgent agent) internal {
        _user = user_;
        _userPrivateKey = userPrivateKey_;
        _router = router_;
        _spender = address(agent);
        DOMAIN_SEPARATOR = EIP712(permit2Addr).DOMAIN_SEPARATOR();
    }

    function permitToken(IERC20 token) internal {
        // Approve token to permit2
        vm.startPrank(_user);
        token.safeApprove(permit2Addr, type(uint256).max);

        // Encode logics
        IParam.Logic[] memory logics = new IParam.Logic[](1);
        logics[0] = logicSpenderPermit2ERC20PermitToken(token);

        // Encode execute
        address[] memory tokensReturnEmpty;
        _router.execute(logics, tokensReturnEmpty, SIGNER_REFERRAL);
        vm.stopPrank();
    }

    function logicSpenderPermit2ERC20PermitToken(IERC20 token) internal view returns (IParam.Logic memory) {
        // Create signed permit
        uint48 defaultNonce = 0;
        uint48 defaultExpiration = uint48(block.timestamp + 5);
        IAllowanceTransfer.PermitSingle memory permit = defaultERC20PermitAllowance(
            address(token),
            type(uint160).max,
            _spender,
            defaultExpiration,
            defaultNonce
        );
        bytes memory sig = getPermitSignature(permit, _userPrivateKey, DOMAIN_SEPARATOR);

        IParam.Input[] memory inputsEmpty;
        return
            IParam.Logic(
                address(permit2Addr), // to
                abi.encodeWithSignature(
                    'permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)',
                    _user,
                    permit,
                    sig
                ),
                inputsEmpty,
                IParam.WrapMode.NONE,
                address(0), // approveTo
                address(0) // callback
            );
    }

    function logicSpenderPermit2ERC20PullToken(
        IERC20 token,
        uint160 amount
    ) internal view returns (IParam.Logic memory) {
        IParam.Input[] memory inputsEmpty;

        return
            IParam.Logic(
                address(permit2Addr), // to
                abi.encodeWithSignature(
                    'transferFrom(address,address,uint160,address)',
                    _user,
                    _spender,
                    amount,
                    token
                ),
                inputsEmpty,
                IParam.WrapMode.NONE,
                address(0), // approveTo
                address(0) // callback
            );
    }
}
