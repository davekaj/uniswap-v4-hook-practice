// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Foundry libraries
import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";

// Test ERC-20 token implementation
import {TestERC20} from "v4-core/test/TestERC20.sol";

// Libraries
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

// Interfaces
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// Pool Manager related contracts
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolModifyPositionTest} from "v4-core/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

// Our contracts
import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";
import {TakeProfitsStub} from "../src/TakeProfitsStub.sol";

contract TakeProfitsHookTest is Test, GasSnapshot {
    // Use the libraries
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    bytes internal constant ZERO_BYTES = bytes("0");

    // Hardcode the address for our hook instead of deploying it
    // We will overwrite the storage to replace code at this address with code from the stub
    TakeProfitsHook hook = TakeProfitsHook(address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG)));

    // poolManager is the Uniswap v4 Pool Manager
    PoolManager poolManager;

    // modifyPositionRouter is the test-version of the contract that allows
    // liquidity providers to add/remove/update their liquidity positions
    PoolModifyPositionTest modifyPositionRouter;

    // swapRouter is the test-version of the contract that allows
    // users to execute swaps on Uniswap v4
    PoolSwapTest swapRouter;

    // token0 and token1 are the two tokens in the pool
    TestERC20 token0;
    TestERC20 token1;

    // poolKey and poolId are the pool key and pool id for the pool
    PoolKey poolKey;
    PoolId poolId;

    // SQRT_RATIO_1_1 is the Q notation for sqrtPriceX96 where price = 1
    // i.e. sqrt(1) * 2^96
    // This is used as the initial price for the pool
    // as we add equal amounts of token0 and token1 to the pool during setUp
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function setUp() public {
        _deployERC20Tokens();
        poolManager = new PoolManager(500_000);
        _stubValidateHookAddress();
        _initializePool();
        _addLiquidityToPool();
    }

    function _placeOrderHelper(int24 tick, uint256 amount, bool zeroForOne) private returns (uint256) {
        TestERC20 token = zeroForOne ? token0 : token1;

        uint256 originalBalance = token.balanceOf(address(this));
        token.approve(address(hook), amount);
        int24 tickLower = hook.placeOrder(poolKey, tick, amount, zeroForOne);

        uint256 newBalance = token.balanceOf(address(this));

        // Since we deployed the pool contract with tick spacing = 60
        // and initially the tick is 0, lowerTick should be 60 or -120
        int24 tickExpected = zeroForOne ? int24(60) : int24(-120); // Cheap way of checking, as it wouldn't work on fuzzing - DK
        assertEq(tickLower, tickExpected);

        // Ensure that our balance was reduced by `amount` tokens
        assertEq(originalBalance - amount, newBalance);

        // Check the balance of ERC-1155 tokens we received
        uint256 tokenID = hook.getTokenID(poolKey, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), tokenID); // balanceOf() is from ERC-1155

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token tokens we placed the order for
        assertTrue(tokenID != 0);
        assertEq(tokenBalance, amount); // The balance of ERC-1155 == tokens in the order, always

        // DK - TODO - add a few more asserts here

        return tokenID;
    }

    function test_placeOrder() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;
        _placeOrderHelper(tick, amount, zeroForOne);
    }

    function test_cancelOrder() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOf(address(this));
        uint256 tokenID = _placeOrderHelper(tick, amount, zeroForOne);

        hook.cancelOrder(poolKey, tick, zeroForOne);

        // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
        uint256 tokenBalance = hook.balanceOf(address(this), tokenID);
        assertTrue(tokenBalance == 0);
        uint256 newBalance = token0.balanceOf(address(this));
        assertTrue(newBalance == originalBalance);
    }

    function test_orderExecute_zeroForOne() public {
        // Place our order at tick 100 for 10e18 token0 tokens
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;
        uint256 tokenID = _placeOrderHelper(tick, amount, zeroForOne);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens

        // sqrtPriceLimitX96
        // You can get a number from its Q Notation by dividing it by 2 ^ K
        // K is equal to 96, and it's represented as the number after X in variable names in the Uniswap codebase.
        // Example: store 1.000234 in Solidity 
        // Using Q notation with k = 96 you can represent it as 79246702000000000000000000000
        // Which is an integer value that can easily fit in a uint160 
        // sqrtPriceX96 is a RATIO of token0 to token1
        // sqrtPriceLimitX96 is a LIMIT on the slippage, so 0.1-1% or something like that, applied to the price they wanted
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne, // because we want to push the tick in the other direction
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1 // We're just saying any slippage is OK here
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES); // DK - TODO - why ZERO_BYTES

        // Check that the order has been executed
        int256 tokensLeftInOrder = hook.takeProfitPositions(poolId, tick, zeroForOne);
        assertEq(tokensLeftInOrder, 0);

        // Check that the hook contract has the expected number of token1 tokens ready to redeem
        uint256 claimableTokens = hook.tokenIdClaimable(tokenID);
        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        assertEq(claimableTokens, hookContractToken1Balance);

        // Ensure we can redeem the token1 tokens
        uint256 originalToken1Balance = token1.balanceOf(address(this));
        hook.redeem(tokenID, amount, address(this));
        uint256 newToken1Balance = token1.balanceOf(address(this));
        assertEq(newToken1Balance - originalToken1Balance, claimableTokens);
    }

    function test_orderExecute_oneForZero() public {
        // Place our order at tick -100 for 10e18 token1 tokens
        int24 tick = -100;
        uint256 amount = 10 ether;
        bool zeroForOne = false;
        uint256 tokenID = _placeOrderHelper(tick, amount, zeroForOne);

        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: !zeroForOne, // because we want to push the tick in the other direction
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        swapRouter.swap(poolKey, params, testSettings, ZERO_BYTES);

        // Check that the order has been executed
        int256 tokensLeftInOrder = hook.takeProfitPositions(poolId, tick, zeroForOne);
        assertEq(tokensLeftInOrder, 0);

        // Check that the hook contract has the expected number of token0 tokens ready to redeem
        uint256 claimableTokens = hook.tokenIdClaimable(tokenID);
        uint256 hookContractToken0Balance = token0.balanceOf(address(hook));
        assertEq(claimableTokens, hookContractToken0Balance);

        // Ensure we can redeem the token0 tokens
        uint256 originalToken0Balance = token0.balanceOf(address(this));
        hook.redeem(tokenID, amount, address(this));
        uint256 newToken0Balance = token0.balanceOf(address(this));
        assertEq(newToken0Balance - originalToken0Balance, claimableTokens);
    }

    // ---------------------------------- Setup Functions ----------------------------------
    // -------------------------------------------------------------------------------------

    function _addLiquidityToPool() private {
        // Mint a lot of tokens to ourselves
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        // Approve the modifyPositionRouter to spend your tokens
        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);

        // Add liquidity across different tick ranges
        // First, from -60 to +60
        // Then, from -120 to +120
        // Then, from minimum possible tick to maximum possible tick

        // Add liquidity from -60 to +60
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-60, 60, 10 ether), ZERO_BYTES);

        // Add liquidity from -120 to +120
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-120, 120, 10 ether), ZERO_BYTES);

        // Add liquidity from minimum tick to maximum tick
        modifyPositionRouter.modifyPosition(
            poolKey,
            IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 50 ether),
            ZERO_BYTES
        );

        // Approve the tokens for swapping through the swapRouter
        token0.approve(address(swapRouter), 100 ether);
        token1.approve(address(swapRouter), 100 ether);
    }

    function _initializePool() private {
        // Deploy the test-versions of modifyPositionRouter and swapRouter
        modifyPositionRouter = new PoolModifyPositionTest(
            IPoolManager(address(poolManager))
        );
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        // Specify the pool key and pool id for the new pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        poolId = poolKey.toId();

        // Initialize the new pool with initial price ratio = 1
        poolManager.initialize(poolKey, SQRT_RATIO_1_1, ZERO_BYTES);
    }

    function _stubValidateHookAddress() private {
        // Deploy the stub contract
        TakeProfitsStub stub = new TakeProfitsStub(poolManager, hook);

        // Fetch all the storage slot writes that have been done at the stub address
        // during deployment
        (, bytes32[] memory writes) = vm.accesses(address(stub));

        // Etch the code of the stub at the hardcoded hook address
        vm.etch(address(hook), address(stub).code);

        // Replay the storage slot writes at the hook address
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(hook), slot, vm.load(address(stub), slot));
            }
        }
    }

    function _deployERC20Tokens() private {
        TestERC20 tokenA = new TestERC20(2 ** 128);
        TestERC20 tokenB = new TestERC20(2 ** 128);

        // Token 0 and Token 1 are assigned in a pool based on
        // the address of the token
        if (address(tokenA) < address(tokenB)) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
    }

    receive() external payable {}

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"));
    }
}
