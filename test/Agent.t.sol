// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';
import {ERC20} from 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';
import {SafeERC20, IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';
import {Agent} from 'src/Agent.sol';
import {AgentImplementation, IAgent} from 'src/AgentImplementation.sol';
import {Router, IRouter} from 'src/Router.sol';
import {IParam} from 'src/interfaces/IParam.sol';
import {ICallback, MockCallback} from './mocks/MockCallback.sol';
import {MockFallback} from './mocks/MockFallback.sol';
import {MockWrappedNative, IWrappedNative} from './mocks/MockWrappedNative.sol';

contract AgentTest is Test {
    using SafeERC20 for IERC20;

    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant BPS_BASE = 10_000;
    uint256 public constant SKIP = type(uint256).max;

    address public user;
    address public recipient;
    address public router;
    IAgent public agent;
    address public mockWrappedNative;
    IERC20 public mockERC20;
    ICallback public mockCallback;
    address public mockFallback;

    // Empty arrays
    address[] public tokensReturnEmpty;
    IParam.Input[] public inputsEmpty;

    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() external {
        user = makeAddr('User');
        recipient = makeAddr('Recipient');
        router = makeAddr('Router');

        mockWrappedNative = address(new MockWrappedNative());
        vm.prank(router);
        agent = IAgent(address(new Agent(address(new AgentImplementation(mockWrappedNative)))));
        mockERC20 = new ERC20('mockERC20', 'mock');
        mockCallback = new MockCallback();
        mockFallback = address(new MockFallback());

        vm.mockCall(router, 0, abi.encodeWithSignature('user()'), abi.encode(user));
        vm.label(address(agent), 'Agent');
        vm.label(address(mockWrappedNative), 'mWrappedNative');
        vm.label(address(mockERC20), 'mERC20');
        vm.label(address(mockCallback), 'mCallback');
        vm.label(address(mockFallback), 'mFallback');
    }

    function testRouter() external {
        assertEq(agent.router(), router);
    }

    function testWrappedNative() external {
        assertEq(agent.wrappedNative(), mockWrappedNative);
    }

    function testCannotExecuteByInvalidCallback() external {
        IParam.Logic[] memory callbacks = new IParam.Logic[](1);
        callbacks[0] = IParam.Logic(
            address(mockFallback), // to
            '',
            inputsEmpty,
            IParam.WrapMode.NONE,
            address(0), // approveTo
            address(0) // callback
        );
        bytes memory data = abi.encodeWithSelector(IAgent.execute.selector, callbacks, tokensReturnEmpty, false);
        IParam.Logic[] memory logics = new IParam.Logic[](1);
        logics[0] = IParam.Logic(
            address(mockCallback),
            abi.encodeWithSelector(ICallback.callback.selector, data),
            inputsEmpty,
            IParam.WrapMode.NONE,
            address(0), // approveTo
            address(router) // callback
        );
        vm.expectRevert(IAgent.InvalidCaller.selector);
        vm.prank(router);
        agent.execute(logics, tokensReturnEmpty, false);
    }

    function testCannotBeInvalidBps() external {
        IParam.Logic[] memory logics = new IParam.Logic[](1);
        IParam.Input[] memory inputs = new IParam.Input[](1);

        // Revert if amountBps = 0
        inputs[0] = IParam.Input(
            address(0),
            0, // amountBps
            0 // amountOrOffset
        );
        logics[0] = IParam.Logic(
            address(0), // to
            '',
            inputs,
            IParam.WrapMode.NONE,
            address(0), // approveTo
            address(0) // callback
        );
        vm.expectRevert(IAgent.InvalidBps.selector);
        vm.prank(router);
        agent.execute(logics, tokensReturnEmpty, false);

        // Revert if amountBps = BPS_BASE + 1
        inputs[0] = IParam.Input(
            address(0),
            BPS_BASE + 1, // amountBps
            0 // amountOrOffset
        );
        logics[0] = IParam.Logic(
            address(0), // to
            '',
            inputs,
            IParam.WrapMode.NONE,
            address(0), // approveTo
            address(0) // callback
        );
        vm.expectRevert(IAgent.InvalidBps.selector);
        vm.prank(router);
        agent.execute(logics, tokensReturnEmpty, false);
    }

    function testCannotUnresetCallback() external {
        IParam.Logic[] memory logics = new IParam.Logic[](1);
        logics[0] = IParam.Logic(
            address(mockFallback), // to
            '',
            inputsEmpty,
            IParam.WrapMode.NONE,
            address(0), // approveTo
            address(mockCallback) // callback
        );
        vm.expectRevert(IAgent.UnresetCallback.selector);
        vm.prank(router);
        agent.execute(logics, tokensReturnEmpty, false);
    }

    function testWrapBeforeFixedAmounts(uint128 amount1, uint128 amount2) external {
        uint256 amount = uint256(amount1) + uint256(amount2);
        deal(router, amount);
        IParam.Logic[] memory logics = new IParam.Logic[](1);
        IParam.Input[] memory inputs = new IParam.Input[](2);

        // Fixed amounts
        inputs[0] = IParam.Input(
            mockWrappedNative, // token
            SKIP, // amountBps
            amount1 // amountOrOffset
        );
        inputs[1] = IParam.Input(
            mockWrappedNative, // token
            SKIP, // amountBps
            amount2 // amountOrOffset
        );
        logics[0] = IParam.Logic(
            address(mockFallback), // to
            '',
            inputs,
            IParam.WrapMode.WRAP_BEFORE,
            address(0), // approveTo
            address(0) // callback
        );
        if (amount > 0) {
            vm.expectEmit(true, true, true, true, mockWrappedNative);
            emit Approval(address(agent), address(mockFallback), type(uint256).max);
        }
        vm.prank(router);
        agent.execute{value: amount}(logics, tokensReturnEmpty, false);
        assertEq(IERC20(mockWrappedNative).balanceOf(address(agent)), amount);
    }

    function testWrapBeforeReplacedAmounts(uint256 amount, uint256 bps) external {
        amount = bound(amount, 0, type(uint256).max / BPS_BASE); // Prevent overflow when calculates the replaced amount
        bps = bound(bps, 1, BPS_BASE - 1);
        deal(router, amount);
        IParam.Logic[] memory logics = new IParam.Logic[](1);
        IParam.Input[] memory inputs = new IParam.Input[](2);

        // Replaced amounts
        inputs[0] = IParam.Input(
            mockWrappedNative, // token
            bps, // amountBps
            SKIP // amountOrOffset
        );
        inputs[1] = IParam.Input(
            mockWrappedNative, // token
            BPS_BASE - bps, // amountBps
            SKIP // amountOrOffset
        );
        logics[0] = IParam.Logic(
            address(mockFallback), // to
            '',
            inputs,
            IParam.WrapMode.WRAP_BEFORE,
            address(0), // approveTo
            address(0) // callback
        );

        // Both replaced amounts are 0 when amount is 1
        if (amount > 1) {
            vm.expectEmit(true, true, true, true, mockWrappedNative);
            emit Approval(address(agent), address(mockFallback), type(uint256).max);
        }
        vm.prank(router);
        agent.execute{value: amount}(logics, tokensReturnEmpty, false);
        assertApproxEqAbs(IERC20(mockWrappedNative).balanceOf(address(agent)), amount, 1); // 1 unit due to BPS_BASE / 2
    }

    function testUnwrapAfter(uint128 amount, uint128 amountBefore) external {
        deal(router, amount);
        deal(mockWrappedNative, address(agent), amountBefore); // Ensure agent handles differences
        IParam.Logic[] memory logics = new IParam.Logic[](1);
        IParam.Input[] memory inputs = new IParam.Input[](1);

        // Wrap native and immediately unwrap after
        inputs[0] = IParam.Input(
            NATIVE, // token
            SKIP, // amountBps
            amount // amountOrOffset
        );
        logics[0] = IParam.Logic(
            address(mockWrappedNative), // to
            abi.encodeWithSelector(IWrappedNative.deposit.selector),
            inputs,
            IParam.WrapMode.UNWRAP_AFTER,
            address(0), // approveTo
            address(0) // callback
        );

        vm.prank(router);
        agent.execute{value: amount}(logics, tokensReturnEmpty, false);
        assertEq((address(agent).balance), amount);
        assertEq(IERC20(mockWrappedNative).balanceOf(address(agent)), amountBefore);
    }

    function testSendNative(uint256 amountIn, uint256 amountBps) external {
        amountIn = bound(amountIn, 0, type(uint128).max);
        amountBps = bound(amountBps, 0, BPS_BASE);
        if (amountBps == 0) amountBps = SKIP;
        deal(router, amountIn);

        // Encode logics
        IParam.Logic[] memory logics = new IParam.Logic[](1);
        logics[0] = _logicSendNative(amountIn, amountBps);

        // Execute
        vm.prank(router);
        agent.execute{value: amountIn}(logics, tokensReturnEmpty, false);

        uint256 recipientAmount = amountIn;
        if (amountBps != SKIP) recipientAmount = (amountIn * amountBps) / BPS_BASE;
        assertEq(address(router).balance, 0);
        assertEq(recipient.balance, recipientAmount);
        assertEq(address(agent).balance, amountIn - recipientAmount);
    }

    function _logicSendNative(uint256 amountIn, uint256 amountBps) internal view returns (IParam.Logic memory) {
        // Encode inputs
        IParam.Input[] memory inputs = new IParam.Input[](1);
        inputs[0].token = NATIVE;
        inputs[0].amountBps = amountBps;
        if (inputs[0].amountBps == SKIP) inputs[0].amountOrOffset = amountIn;
        else inputs[0].amountOrOffset = SKIP; // data is not provided

        return
            IParam.Logic(
                address(recipient), // to
                '',
                inputs,
                IParam.WrapMode.NONE,
                address(0), // approveTo
                address(0) // callback
            );
    }

    function testApproveToIsDefault(uint256 amountIn) external {
        vm.assume(amountIn > 0);

        IParam.Logic[] memory logics = new IParam.Logic[](1);
        IParam.Input[] memory inputs = new IParam.Input[](1);

        inputs[0] = IParam.Input(
            address(mockERC20),
            SKIP, // amountBps
            amountIn // amountOrOffset
        );
        logics[0] = IParam.Logic(
            address(mockFallback), // to
            '',
            inputs,
            IParam.WrapMode.NONE,
            address(0), // approveTo
            address(0) // callback
        );

        // Execute
        vm.expectEmit(true, true, true, true, address(mockERC20));
        emit Approval(address(agent), address(mockFallback), type(uint256).max);
        vm.prank(router);
        agent.execute(logics, tokensReturnEmpty, false);

        // Execute again, mock approve to guarantee that approval is not called
        vm.mockCall(
            address(mockERC20),
            0,
            abi.encodeCall(IERC20.approve, (address(mockFallback), type(uint256).max)),
            abi.encode(false)
        );
        vm.prank(router);
        agent.execute(logics, tokensReturnEmpty, false);
    }

    function testApproveToIsSet(uint256 amountIn, address approveTo) external {
        vm.assume(amountIn > 0);
        vm.assume(approveTo != address(0) && approveTo != mockFallback && approveTo != address(mockERC20));

        IParam.Logic[] memory logics = new IParam.Logic[](1);
        IParam.Input[] memory inputs = new IParam.Input[](1);

        inputs[0] = IParam.Input(
            address(mockERC20),
            SKIP, // amountBps
            amountIn // amountOrOffset
        );
        logics[0] = IParam.Logic(
            address(mockFallback), // to
            '',
            inputs,
            IParam.WrapMode.NONE,
            approveTo, // approveTo
            address(0) // callback
        );

        // Execute
        vm.expectEmit(true, true, true, true, address(mockERC20));
        emit Approval(address(agent), approveTo, type(uint256).max);
        vm.prank(router);
        agent.execute(logics, tokensReturnEmpty, false);

        // Execute again, mock approve to guarantee that approval is not called
        vm.mockCall(
            address(mockERC20),
            0,
            abi.encodeCall(IERC20.approve, (address(mockERC20), type(uint256).max)),
            abi.encode(false)
        );
        vm.prank(router);
        agent.execute(logics, tokensReturnEmpty, false);
    }
}
