// SPDX-License-Identifier: GPLv2

// ███████╗░█████╗░██████╗░██████╗░███████╗██████╗░░░░███████╗██╗
// ╚════██║██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗░░░██╔════╝██║
// ░░███╔═╝███████║██████╔╝██████╔╝█████╗░░██████╔╝░░░█████╗░░██║
// ██╔══╝░░██╔══██║██╔═══╝░██╔═══╝░██╔══╝░░██╔══██╗░░░██╔══╝░░██║
// ███████╗██║░░██║██║░░░░░██║░░░░░███████╗██║░░██║██╗██║░░░░░██║
// ╚══════╝╚═╝░░╚═╝╚═╝░░░░░╚═╝░░░░░╚══════╝╚═╝░░╚═╝╚═╝╚═╝░░░░░╚═╝
// Copyright (C) 2020 zapper, nodar, suhail, seb, apoorv, sumit

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
// Visit <https://www.gnu.org/licenses/>for a copy of the GNU Affero General Public License

///@author Zapper
///@notice this contract implements one click removal of liquidity from swap pools, receiving ETH, ERC tokens or both.

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./libraries/Math.sol";
import "./interfaces/IGoSwapFactory.sol";
import "./interfaces/IGoSwapRouter.sol";
import "./interfaces/IGoSwapPair.sol";
import "./interfaces/IERC20GoSwap.sol";
import "./interfaces/IWHT.sol";

contract GoSwap_ZapOut is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address;

    bool public stopped = false;

    IGoSwapRouter public otherRouter;
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

    function setOtherRouter(IGoSwapRouter _otherRouter) public onlyOwner {
        otherRouter = _otherRouter;
    }

    function setRouter(IGoSwapRouter _router) public onlyOwner {
        router = _router;
    }

    function setWHT(address _WHT) public onlyOwner {
        WHT = _WHT;
    }

    /**
    @notice This function is used to zapout of given Swap pair in the bounded tokens
    @param _FromPoolAddress The Swap pair address to zapout
    @param _IncomingLP The amount of LP
    @return amountA the amount of pair tokens received after zapout
     */
    function ZapOut2PairToken(
        address _FromPoolAddress,
        uint256 _IncomingLP
    )
        public
        nonReentrant
        stopInEmergency
        returns (uint256 amountA, uint256 amountB)
    {
        IGoSwapPair pair = IGoSwapPair(_FromPoolAddress);

        require(
            address(pair) != address(0),
            "Error: Invalid pool Address"
        );

        //get reserves
        address token0 = pair.token0();
        address token1 = pair.token1();

        IERC20(_FromPoolAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _IncomingLP
        );

        IERC20(_FromPoolAddress).safeApprove(address(router), _IncomingLP);

        if (token0 == WHT || token1 == WHT) {
            address _token = token0 == WHT ? token1 : token0;
            (amountA, amountB) = router.removeLiquidityHT(
                _token,
                _IncomingLP,
                1,
                1,
                msg.sender,
                deadline
            );
        } else {
            (amountA, amountB) = router.removeLiquidity(
                token0,
                token1,
                _IncomingLP,
                1,
                1,
                msg.sender,
                deadline
            );
        }
    }

    /**
    @notice This function is used to zapout of given swap pair in ETH/ERC20 Tokens
    @param _ToTokenContractAddress The ERC20 token to zapout in (address(0x00) if ether)
    @param _FromPoolAddress The swap pair address to zapout from
    @param _IncomingLP The amount of LP
    @return the amount of eth/tokens received after zapout
     */
    function ZapOut(
        address _ToTokenContractAddress,
        address _FromPoolAddress,
        uint256 _IncomingLP,
        uint256 _minTokensRec
    ) public nonReentrant stopInEmergency returns (uint256) {
        IGoSwapPair pair = IGoSwapPair(_FromPoolAddress);

        require(
            address(pair) != address(0),
            "Error: Invalid pool Address"
        );

        //get pair tokens
        address token0 = pair.token0();
        address token1 = pair.token1();

        IERC20(_FromPoolAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _IncomingLP
        );

        IERC20(_FromPoolAddress).safeApprove(address(router), _IncomingLP);

        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            token0,
            token1,
            _IncomingLP,
            1,
            1,
            address(this),
            deadline
        );

        uint256 tokenBought;
        if (
            canSwapFromV2(_ToTokenContractAddress, token0) &&
            canSwapFromV2(_ToTokenContractAddress, token1)
        ) {
            tokenBought = swapFromV2(token0, _ToTokenContractAddress, amountA);
            tokenBought += swapFromV2(token1, _ToTokenContractAddress, amountB);
        } else if (canSwapFromV2(_ToTokenContractAddress, token0)) {
            uint256 token0Bought = swapFromV2(token1, token0, amountB);
            tokenBought = swapFromV2(
                token0,
                _ToTokenContractAddress,
                token0Bought.add(amountA)
            );
        } else if (canSwapFromV2(_ToTokenContractAddress, token1)) {
            uint256 token1Bought = swapFromV2(token0, token1, amountA);
            tokenBought = swapFromV2(
                token1,
                _ToTokenContractAddress,
                token1Bought.add(amountB)
            );
        }

        require(tokenBought >= _minTokensRec, "High slippage");

        if (_ToTokenContractAddress == address(0)) {
            msg.sender.transfer(tokenBought);
        } else {
            IERC20(_ToTokenContractAddress).safeTransfer(
                msg.sender,
                tokenBought
            );
        }

        return tokenBought;
    }

    function ZapOut2PairTokenWithPermit(
        address _FromPoolAddress,
        uint256 _IncomingLP,
        uint256 _approvalAmount,
        uint256 _deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external stopInEmergency returns (uint256 amountA, uint256 amountB) {
        // permit
        IERC20GoSwap(_FromPoolAddress).permit(
            msg.sender,
            address(this),
            _approvalAmount,
            _deadline,
            v,
            r,
            s
        );
        (amountA, amountB) = ZapOut2PairToken(
            _FromPoolAddress,
            _IncomingLP
        );
    }

    function ZapOutWithPermit(
        address _ToTokenContractAddress,
        address _FromPoolAddress,
        uint256 _IncomingLP,
        uint256 _minTokensRec,
        uint256 _approvalAmount,
        uint256 _deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external stopInEmergency returns (uint256) {
        // permit
        IERC20GoSwap(_FromPoolAddress).permit(
            msg.sender,
            address(this),
            _approvalAmount,
            _deadline,
            v,
            r,
            s
        );

        return (
            ZapOut(
                _ToTokenContractAddress,
                _FromPoolAddress,
                _IncomingLP,
                _minTokensRec
            )
        );
    }

    //swaps _fromToken for _toToken
    //for eth, address(0) otherwise ERC token address
    function swapFromV2(
        address _fromToken,
        address _toToken,
        uint256 amount
    ) internal returns (uint256) {
        require(
            _fromToken != address(0) || _toToken != address(0),
            "Invalid Exchange values"
        );
        if (_fromToken == _toToken) return amount;

        require(canSwapFromV2(_fromToken, _toToken), "Cannot be exchanged");
        require(amount > 0, "Invalid amount");

        if (_fromToken == address(0)) {
            if (_toToken == WHT) {
                IWHT(WHT).deposit{value:amount}();
                return amount;
            }
            address[] memory path = new address[](2);
            path[0] = WHT;
            path[1] = _toToken;
            uint256 minTokens = otherRouter.getAmountsOut(amount, path)[1];
            minTokens = SafeMath.div(
                SafeMath.mul(minTokens, SafeMath.sub(10000, 200)),
                10000
            );
            uint256[] memory amounts = otherRouter.swapExactHTForTokens{value:amount}(minTokens, path, address(this), deadline);
            return amounts[1];
        } else if (_toToken == address(0)) {
            if (_fromToken == WHT) {
                IWHT(WHT).withdraw(amount);
                return amount;
            }
            address[] memory path = new address[](2);
            IERC20(_fromToken).safeApprove(address(otherRouter), amount);
            path[0] = _fromToken;
            path[1] = WHT;
            uint256 minTokens = otherRouter.getAmountsOut(amount, path)[1];
            minTokens = SafeMath.div(
                SafeMath.mul(minTokens, SafeMath.sub(10000, 200)),
                10000
            );
            uint256[] memory amounts = otherRouter.swapExactTokensForHT(
                amount,
                minTokens,
                path,
                address(this),
                deadline
            );
            return amounts[1];
        } else {
            IERC20(_fromToken).safeApprove(address(otherRouter), amount);
            uint256 returnedAmount = _swapTokenToTokenV2(
                _fromToken,
                _toToken,
                amount
            );
            require(returnedAmount > 0, "Error in swap");
            return returnedAmount;
        }
    }

    //swaps 2 ERC tokens (UniV2)
    function _swapTokenToTokenV2(
        address _fromToken,
        address _toToken,
        uint256 amount
    ) internal returns (uint256) {
        IGoSwapPair pair1 = IGoSwapPair(otherFactory.getPair(_fromToken, WHT));
        IGoSwapPair pair2 = IGoSwapPair(otherFactory.getPair(_toToken, WHT));
        IGoSwapPair pair3 = IGoSwapPair(
            otherFactory.getPair(_fromToken, _toToken)
        );

        uint256[] memory amounts;

        if (_haveReserve(pair3)) {
            address[] memory path = new address[](2);
            path[0] = _fromToken;
            path[1] = _toToken;
            uint256 minTokens = otherRouter.getAmountsOut(amount, path)[1];
            minTokens = SafeMath.div(
                SafeMath.mul(minTokens, SafeMath.sub(10000, 200)),
                10000
            );
            amounts = otherRouter.swapExactTokensForTokens(
                amount,
                minTokens,
                path,
                address(this),
                deadline
            );
            return amounts[1];
        } else if (_haveReserve(pair1) && _haveReserve(pair2)) {
            address[] memory path = new address[](3);
            path[0] = _fromToken;
            path[1] = WHT;
            path[2] = _toToken;
            uint256 minTokens = otherRouter.getAmountsOut(amount, path)[2];
            minTokens = SafeMath.div(
                SafeMath.mul(minTokens, SafeMath.sub(10000, 200)),
                10000
            );
            amounts = otherRouter.swapExactTokensForTokens(
                amount,
                minTokens,
                path,
                address(this),
                deadline
            );
            return amounts[2];
        }
        return 0;
    }

    function canSwapFromV2(address _fromToken, address _toToken)
        internal
        view
        returns (bool)
    {
        require(
            _fromToken != address(0) || _toToken != address(0),
            "Invalid Exchange values"
        );

        if (_fromToken == _toToken) return true;

        if (_fromToken == address(0) || _fromToken == WHT) {
            if (_toToken == WHT || _toToken == address(0)) return true;
            IGoSwapPair pair = IGoSwapPair(otherFactory.getPair(_toToken, WHT));
            if (_haveReserve(pair)) return true;
        } else if (_toToken == address(0) || _toToken == WHT) {
            if (_fromToken == WHT || _fromToken == address(0)) return true;
            IGoSwapPair pair = IGoSwapPair(
                otherFactory.getPair(_fromToken, WHT)
            );
            if (_haveReserve(pair)) return true;
        } else {
            IGoSwapPair pair1 = IGoSwapPair(
                otherFactory.getPair(_fromToken, WHT)
            );
            IGoSwapPair pair2 = IGoSwapPair(
                otherFactory.getPair(_toToken, WHT)
            );
            IGoSwapPair pair3 = IGoSwapPair(
                otherFactory.getPair(_fromToken, _toToken)
            );
            if (_haveReserve(pair1) && _haveReserve(pair2)) return true;
            if (_haveReserve(pair3)) return true;
        }
        return false;
    }

    //checks if the UNI v2 contract have reserves to swap tokens
    function _haveReserve(IGoSwapPair pair) internal view returns (bool) {
        if (address(pair) != address(0)) {
            uint256 totalSupply = IERC20GoSwap(address(pair)).totalSupply();
            if (totalSupply > 0) return true;
        }
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

    receive() external payable {
        require(msg.sender != tx.origin, "Do not send HT directly");
    }
}
