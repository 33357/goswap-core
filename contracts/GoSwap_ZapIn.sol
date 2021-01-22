// SPDX-License-Identifier: GPLv2

// ███████╗░█████╗░██████╗░██████╗░███████╗██████╗░░░░███████╗██╗
// ╚════██║██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗░░░██╔════╝██║
// ░░███╔═╝███████║██████╔╝██████╔╝█████╗░░██████╔╝░░░█████╗░░██║
// ██╔══╝░░██╔══██║██╔═══╝░██╔═══╝░██╔══╝░░██╔══██╗░░░██╔══╝░░██║
// ███████╗██║░░██║██║░░░░░██║░░░░░███████╗██║░░██║██╗██║░░░░░██║
// ╚══════╝╚═╝░░╚═╝╚═╝░░░░░╚═╝░░░░░╚══════╝╚═╝░░╚═╝╚═╝╚═╝░░░░░╚═╝
// Copyright (C) 2020 zapper

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//

///@author Zapper
///@notice This contract adds liquidity to Sushiswap pools using ETH or any ERC20 Token.
// SPDX-License-Identifier: GPLv2

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/Math.sol";
import "./interfaces/IGoSwapFactory.sol";
import "./interfaces/IGoSwapRouter.sol";
import "./interfaces/IGoSwapPair.sol";

contract GoSwap_ZapIn is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for IERC20;

    bool public stopped = false;

    IGoSwapRouter public router;
    IGoSwapFactory public otherFactory;
    IGoSwapFactory public factory;

    address public WHT;

    uint256
        private constant deadline = 0xf000000000000000000000000000000000000000000000000000000000000000;

    // circuit breaker modifiers
    modifier stopInEmergency {
        if (stopped) {
            revert("Temporarily Paused");
        } else {
            _;
        }
    }

    function setOtherFactory(IGoSwapFactory _otherFactory) public onlyOwner {
        otherFactory = _otherFactory;
    }

    function setFactory(IGoSwapFactory _factory) public onlyOwner {
        factory = _factory;
    }

    function setRouter(IGoSwapRouter _router) public onlyOwner {
        router = _router;
    }

    function setWHT(address _WHT) public onlyOwner {
        WHT = _WHT;
    }

    /**
    @notice This function is used to invest in given Sushiswap pair through ETH/ERC20 Tokens
    @param _FromTokenContractAddress The ERC20 token used for investment (address(0x00) if ether)
    @param _pairAddress The Sushiswap pair address
    @param _amount The amount of fromToken to invest
    @param _minPoolTokens Reverts if less tokens received than this
    @param _allowanceTarget Spender for the first swap
    @param _swapTarget Excecution target for the first swap
    @param swapData Dex quote data
    @return Amount of LP bought
     */
    function ZapIn(
        address _FromTokenContractAddress,
        address _pairAddress,
        uint256 _amount,
        uint256 _minPoolTokens,
        address _allowanceTarget,
        address _swapTarget,
        bytes calldata swapData
    ) external payable nonReentrant stopInEmergency returns (uint256) {
        uint256 toInvest;
        if (_FromTokenContractAddress == address(0)) {
            require(msg.value > 0, "Error: HT not sent");
            toInvest = msg.value;
        } else {
            require(msg.value == 0, "Error: HT sent");
            require(_amount > 0, "Error: Invalid ERC amount");
            IERC20(_FromTokenContractAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
            toInvest = _amount;
        }

        uint256 LPBought = _performZapIn(
            _FromTokenContractAddress,
            _pairAddress,
            toInvest,
            _allowanceTarget,
            _swapTarget,
            swapData
        );
        require(LPBought >= _minPoolTokens, "ERR: High Slippage");

        IERC20(_pairAddress).safeTransfer(msg.sender, LPBought);
        return LPBought;
    }

    function _getPairTokens(address _pairAddress)
        internal
        pure
        returns (address token0, address token1)
    {
        IGoSwapPair pair = IGoSwapPair(_pairAddress);
        token0 = pair.token0();
        token1 = pair.token1();
    }

    function _performZapIn(
        address _FromTokenContractAddress,
        address _pairAddress,
        uint256 _amount,
        address _allowanceTarget,
        address _swapTarget,
        bytes memory swapData
    ) internal returns (uint256) {
        uint256 intermediateAmt;
        address intermediateToken;
        (
            address _ToSushipoolToken0,
            address _ToSushipoolToken1
        ) = _getPairTokens(_pairAddress);

        if (
            _FromTokenContractAddress != _ToSushipoolToken0 &&
            _FromTokenContractAddress != _ToSushipoolToken1
        ) {
            // swap to intermediate
            (intermediateAmt, intermediateToken) = _fillQuote(
                _FromTokenContractAddress,
                _pairAddress,
                _amount,
                _allowanceTarget,
                _swapTarget,
                swapData
            );
        } else {
            intermediateToken = _FromTokenContractAddress;
            intermediateAmt = _amount;
        }
        // divide intermediate into appropriate amount to add liquidity
        (uint256 token0Bought, uint256 token1Bought) = _swapIntermediate(
            intermediateToken,
            _ToSushipoolToken0,
            _ToSushipoolToken1,
            intermediateAmt
        );

        return
            _deposit(
                _ToSushipoolToken0,
                _ToSushipoolToken1,
                token0Bought,
                token1Bought
            );
    }

    function _deposit(
        address _ToUnipoolToken0,
        address _ToUnipoolToken1,
        uint256 token0Bought,
        uint256 token1Bought
    ) internal returns (uint256) {
        IERC20(_ToUnipoolToken0).safeApprove(address(router), 0);
        IERC20(_ToUnipoolToken1).safeApprove(address(router), 0);

        IERC20(_ToUnipoolToken0).safeApprove(address(router), token0Bought);
        IERC20(_ToUnipoolToken1).safeApprove(address(router), token1Bought);

        (uint256 amountA, uint256 amountB, uint256 LP) = router.addLiquidity(
            _ToUnipoolToken0,
            _ToUnipoolToken1,
            token0Bought,
            token1Bought,
            1,
            1,
            address(this),
            deadline
        );

        //Returning Residue in token0, if any.
        if (token0Bought.sub(amountA) > 0) {
            IERC20(_ToUnipoolToken0).safeTransfer(
                msg.sender,
                token0Bought.sub(amountA)
            );
        }

        //Returning Residue in token1, if any
        if (token1Bought.sub(amountB) > 0) {
            IERC20(_ToUnipoolToken1).safeTransfer(
                msg.sender,
                token1Bought.sub(amountB)
            );
        }

        return LP;
    }

    function _fillQuote(
        address _fromTokenAddress,
        address _pairAddress,
        uint256 _amount,
        address _allowanceTarget,
        address _swapTarget,
        bytes memory swapCallData
    ) internal returns (uint256 amountBought, address intermediateToken) {
        uint256 valueToSend;
        if (_fromTokenAddress == address(0)) {
            valueToSend = _amount;
        } else {
            IERC20 fromToken = IERC20(_fromTokenAddress);
            fromToken.safeApprove(address(_allowanceTarget), 0);
            fromToken.safeApprove(address(_allowanceTarget), _amount);
        }

        (address _token0, address _token1) = _getPairTokens(_pairAddress);
        IERC20 token0 = IERC20(_token0);
        IERC20 token1 = IERC20(_token1);
        uint256 initialBalance0 = token0.balanceOf(address(this));
        uint256 initialBalance1 = token1.balanceOf(address(this));

        (bool success, ) = _swapTarget.call{value:valueToSend}(swapCallData);
        require(success, "Error Swapping Tokens 1");

        uint256 finalBalance0 = token0.balanceOf(address(this)).sub(
            initialBalance0
        );
        uint256 finalBalance1 = token1.balanceOf(address(this)).sub(
            initialBalance1
        );

        if (finalBalance0 > finalBalance1) {
            amountBought = finalBalance0;
            intermediateToken = _token0;
        } else {
            amountBought = finalBalance1;
            intermediateToken = _token1;
        }

        require(amountBought > 0, "Swapped to Invalid Intermediate");
    }

    function _swapIntermediate(
        address _toContractAddress,
        address _ToSushipoolToken0,
        address _ToSushipoolToken1,
        uint256 _amount
    ) internal returns (uint256 token0Bought, uint256 token1Bought) {
        IGoSwapPair pair = IGoSwapPair(
            factory.getPair(_ToSushipoolToken0, _ToSushipoolToken1)
        );
        (uint256 res0, uint256 res1, ) = pair.getReserves();
        if (_toContractAddress == _ToSushipoolToken0) {
            uint256 amountToSwap = calculateSwapInAmount(res0, _amount);
            //if no reserve or a new pair is created
            if (amountToSwap <= 0) amountToSwap = _amount.div(2);
            token1Bought = _token2Token(
                _toContractAddress,
                _ToSushipoolToken1,
                amountToSwap
            );
            token0Bought = _amount.sub(amountToSwap);
        } else {
            uint256 amountToSwap = calculateSwapInAmount(res1, _amount);
            //if no reserve or a new pair is created
            if (amountToSwap <= 0) amountToSwap = _amount.div(2);
            token0Bought = _token2Token(
                _toContractAddress,
                _ToSushipoolToken0,
                amountToSwap
            );
            token1Bought = _amount.sub(amountToSwap);
        }
    }

    function calculateSwapInAmount(uint256 reserveIn, uint256 userIn)
        internal
        pure
        returns (uint256)
    {
        return
            Math
                .sqrt(
                reserveIn.mul(userIn.mul(3988000) + reserveIn.mul(3988009))
            )
                .sub(reserveIn.mul(1997)) / 1994;
    }

    /**
    @notice This function is used to swap ERC20 <> ERC20
    @param _FromTokenContractAddress The token address to swap from.
    @param _ToTokenContractAddress The token address to swap to.
    @param tokens2Trade The amount of tokens to swap
    @return tokenBought The quantity of tokens bought
    */
    function _token2Token(
        address _FromTokenContractAddress,
        address _ToTokenContractAddress,
        uint256 tokens2Trade
    ) internal returns (uint256 tokenBought) {
        if (_FromTokenContractAddress == _ToTokenContractAddress) {
            return tokens2Trade;
        }
        IERC20(_FromTokenContractAddress).safeApprove(address(router), 0);
        IERC20(_FromTokenContractAddress).safeApprove(
            address(router),
            tokens2Trade
        );

        if (_FromTokenContractAddress != WHT) {
            if (_ToTokenContractAddress != WHT) {
                // check output via tokenA -> tokenB
                address pairA = otherFactory.getPair(
                    _FromTokenContractAddress,
                    _ToTokenContractAddress
                );
                address[] memory pathA = new address[](2);
                pathA[0] = _FromTokenContractAddress;
                pathA[1] = _ToTokenContractAddress;
                uint256 amtA;
                if (pairA != address(0)) {
                    amtA = router.getAmountsOut(tokens2Trade, pathA)[1];
                }

                // check output via tokenA -> weth -> tokenB
                address[] memory pathB = new address[](3);
                pathB[0] = _FromTokenContractAddress;
                pathB[1] = WHT;
                pathB[2] = _ToTokenContractAddress;

                uint256 amtB = router.getAmountsOut(tokens2Trade, pathB)[2];

                if (amtA >= amtB) {
                    tokenBought = router.swapExactTokensForTokens(
                        tokens2Trade,
                        1,
                        pathA,
                        address(this),
                        deadline
                    )[pathA.length - 1];
                } else {
                    tokenBought = router.swapExactTokensForTokens(
                        tokens2Trade,
                        1,
                        pathB,
                        address(this),
                        deadline
                    )[pathB.length - 1];
                }
            } else {
                address[] memory path = new address[](2);
                path[0] = _FromTokenContractAddress;
                path[1] = WHT;

                tokenBought = router.swapExactTokensForTokens(
                    tokens2Trade,
                    1,
                    path,
                    address(this),
                    deadline
                )[path.length - 1];
            }
        } else {
            address[] memory path = new address[](2);
            path[0] = WHT;
            path[1] = _ToTokenContractAddress;
            tokenBought = router.swapExactTokensForTokens(
                tokens2Trade,
                1,
                path,
                address(this),
                deadline
            )[path.length - 1];
        }

        require(tokenBought > 0, "Error Swapping Tokens 2");
    }

    function inCaseTokengetsStuck(IERC20 _TokenAddress) public onlyOwner {
        uint256 qty = _TokenAddress.balanceOf(address(this));
        _TokenAddress.safeTransfer(owner(), qty);
    }

    // - to Pause the contract
    function toggleContractActive() public onlyOwner {
        stopped = !stopped;
    }

    // - to withdraw any ETH balance sitting in the contract
    function withdraw() public onlyOwner {
        uint256 contractBalance = address(this).balance;
        address payable _to = address(uint160(owner()));
        _to.transfer(contractBalance);
    }
}
