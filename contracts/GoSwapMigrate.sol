// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./interfaces/IGoSwapPair.sol";
import "./interfaces/IERC20GoSwap.sol";
import "./interfaces/IGoSwapRouter.sol";
import "./interfaces/IGoSwapFactory.sol";
import "./libraries/GoSwapLibrary.sol";
import "./libraries/AdminRole.sol";

// SushiRoll helps your migrate your existing Uniswap LP tokens to SushiSwap LP ones
contract GoSwapMigrate is AdminRole {
    using SafeERC20 for IERC20;

    IGoSwapRouter public oldRouter;
    IGoSwapRouter public router;

    function setOldRouter(IGoSwapRouter _oldRouter) public onlyAdmin {
        oldRouter = _oldRouter;
    }

    function setRouter(IGoSwapRouter _router) public onlyAdmin {
        router = _router;
    }

    function migrateWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public {
        address oldFactory = oldRouter.factory();
        IERC20GoSwap pair = IERC20GoSwap(
            GoSwapLibrary.pairFor(oldFactory, tokenA, tokenB)
        );
        pair.permit(msg.sender, address(this), liquidity, deadline, v, r, s);

        migrate(tokenA, tokenB, liquidity, amountAMin, amountBMin, deadline);
    }

    // msg.sender should have approved 'liquidity' amount of LP token of 'tokenA' and 'tokenB'
    function migrate(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) public {
        require(deadline >= block.timestamp, "SushiSwap: EXPIRED");

        // Remove liquidity from the old router with permit
        (uint256 amountA, uint256 amountB) = removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            amountAMin,
            amountBMin,
            deadline
        );

        // Add liquidity to the new router
        (uint256 pooledAmountA, uint256 pooledAmountB) = addLiquidity(
            tokenA,
            tokenB,
            amountA,
            amountB
        );

        // Send remaining tokens to msg.sender
        if (amountA > pooledAmountA) {
            IERC20(tokenA).safeTransfer(msg.sender, amountA - pooledAmountA);
        }
        if (amountB > pooledAmountB) {
            IERC20(tokenB).safeTransfer(msg.sender, amountB - pooledAmountB);
        }
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 deadline
    ) internal returns (uint256 amountA, uint256 amountB) {
        address oldFactory = oldRouter.factory();
        address pair = GoSwapLibrary.pairFor(oldFactory, tokenA, tokenB);
        IERC20GoSwap(pair).transferFrom(msg.sender, address(pair), liquidity);
        (uint256 amount0, uint256 amount1) = IGoSwapPair(pair).burn(
            address(this)
        );
        (address token0, ) = GoSwapLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0
            ? (amount0, amount1)
            : (amount1, amount0);
        require(amountA >= amountAMin, "SushiRoll: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "SushiRoll: INSUFFICIENT_B_AMOUNT");
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) internal returns (uint256 amountA, uint256 amountB) {
        (amountA, amountB) = _addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired
        );
        address pair = GoSwapLibrary.pairFor(router.factory(), tokenA, tokenB);
        IERC20(tokenA).safeTransfer(pair, amountA);
        IERC20(tokenB).safeTransfer(pair, amountB);
        IGoSwapPair(pair).mint(msg.sender);
    }

    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) internal returns (uint256 amountA, uint256 amountB) {
        // create the pair if it doesn't exist yet
        IGoSwapFactory factory = IGoSwapFactory(router.factory());
        if (factory.getPair(tokenA, tokenB) == address(0)) {
            factory.createPair(tokenA, tokenB);
        }
        (uint256 reserveA, uint256 reserveB, ) = GoSwapLibrary.getReserves(
            address(factory),
            tokenA,
            tokenB
        );
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint256 amountBOptimal = GoSwapLibrary.quote(
                amountADesired,
                reserveA,
                reserveB
            );
            if (amountBOptimal <= amountBDesired) {
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint256 amountAOptimal = GoSwapLibrary.quote(
                    amountBDesired,
                    reserveB,
                    reserveA
                );
                assert(amountAOptimal <= amountADesired);
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
}
