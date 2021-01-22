// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IGoSwapPair.sol";
import "./interfaces/IGoSwapFactory.sol";

/**
 * @title 通过手续费回购GOT的合约
 */
contract GoSwapBuyGOT is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IGoSwapFactory public factory;
    address public sGOT;
    address public GOT;
    address public GOC;

    function setFactory(IGoSwapFactory _factory) public onlyOwner {
        factory = _factory;
    }

    function setSGOT(address _sGOT) public onlyOwner {
        sGOT = _sGOT;
    }

    function setGOT(address _GOT) public onlyOwner {
        GOT = _GOT;
    }

    function setGOC(address _GOC) public onlyOwner {
        GOC = _GOC;
    }

    /**
     * @dev 将token转换为GOT
     * @param token0 token0
     * @param token1 token1
     */
    function convert(address token0, address token1) public {
        // 至少我们尝试使前置运行变得更困难
        // At least we try to make front-running harder to do.
        // 确认合约调用者为初始调用用户
        require(msg.sender == tx.origin, "do not convert from contract");
        // 通过token0和token1找到配对合约地址,并实例化配对合约
        address pair = factory.getPair(token0, token1);
        // 调用配对合约的transfer方法,将当前合约的余额发送到配对合约地址上
        IERC20(pair).transfer(pair, IERC20(pair).balanceOf(address(this)));
        // 调用配对合约的销毁方法,将流动性token销毁,之后配对合约将会向当前合约地址发送token0和token1
        (uint256 amount0, uint256 amount1) = IGoSwapPair(pair).burn(
            address(this)
        );
        // 调整顺序
        if (token0 != IGoSwapPair(pair).token0()) {
            (amount0, amount1) = (amount1, amount0);
        }
        //
        uint256 GOCAmount = _toGOC(token0, amount0) + _toGOC(token1, amount1);
        _toGOT(GOCAmount);
    }

    /**
     * @dev 将token卖出转换为GOC
     * @param token token
     */
    function _toGOC(address token, uint256 amountIn)
        internal
        returns (uint256)
    {
        // 如果token地址是GOT地址
        if (token == GOT) {
            // 将输入数额从当前合约地址发送到stake合约
            _safeTransfer(token, sGOT, amountIn);
            return 0;
        }
        // 如果token地址是GOC地址
        if (token == GOC) {
            // 将数额从当前合约发送到工厂合约上的GOC和GOT的配对合约地址上
            _safeTransfer(token, factory.getPair(GOC, GOT), amountIn);
            return amountIn;
        }
        // 实例化token地址和GOC地址的配对合约
        IGoSwapPair pair = IGoSwapPair(factory.getPair(token, GOC));
        // 如果配对合约地址 == 0地址 返回0
        if (address(pair) == address(0)) {
            return 0;
        }
        // 从配对合约获取储备量0,储备量1
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        // 找到token0
        address token0 = pair.token0();
        // 获取手续费
        uint8 fee = pair.fee();
        // 排序形成储备量In和储备量Out
        (uint256 reserveIn, uint256 reserveOut) = token0 == token
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
        // 税后输入数额 = 输入数额 * (1000-fee)
        uint256 amountInWithFee = amountIn.mul(1000 - fee);
        // 输出数额 = 税后输入数额 * 储备量Out / 储备量In * 1000 + 税后输入数额
        uint256 amountOut = amountInWithFee.mul(reserveOut) /
            reserveIn.mul(1000).add(amountInWithFee);
        // 排序输出数额0和输出数额1,有一个是0
        (uint256 amount0Out, uint256 amount1Out) = token0 == token
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));
        // 将输入数额发送到配对合约
        _safeTransfer(token, address(pair), amountIn);
        // 执行配对合约的交换方法(输出数额0,输出数额1,发送到WETH和token的配对合约上)
        pair.swap(
            amount0Out,
            amount1Out,
            factory.getPair(GOC, GOT),
            new bytes(0)
        );
        return amountOut;
    }

    /**
     * @dev 用amountIn数量的GOC交换GOT并发送到stake合约上
     * @param amountIn 输入数额
     */
    function _toGOT(uint256 amountIn) internal {
        // 获取GOT和GOC的配对合约地址,并实例化配对合约
        IGoSwapPair pair = IGoSwapPair(factory.getPair(GOC, GOT));
        // 获取配对合约的储备量0,储备量1
        (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
        // 找到token0
        address token0 = pair.token0();
        // 获取手续费
        uint8 fee = pair.fee();
        // 排序生成储备量In和储备量Out
        (uint256 reserveIn, uint256 reserveOut) = token0 == GOC
            ? (reserve0, reserve1)
            : (reserve1, reserve0);
        // 税后输入数额 = 输入数额 * (1000-fee)
        uint256 amountInWithFee = amountIn.mul(1000 - fee);
        // 分子 = 税后输入数额 * 储备量Out
        uint256 numerator = amountInWithFee.mul(reserveOut);
        // 分母 = 储备量In * 1000 + 税后输入数额
        uint256 denominator = reserveIn.mul(1000).add(amountInWithFee);
        // 输出数额 = 分子 / 分母
        uint256 amountOut = numerator / denominator;
        // 排序输出数额0和输出数额1,有一个是0
        (uint256 amount0Out, uint256 amount1Out) = token0 == GOC
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));
        // 执行配对合约的交换方法(输出数额0,输出数额1,发送到stake合约上)
        pair.swap(amount0Out, amount1Out, sGOT, new bytes(0));
    }

    /**
     * @dev 安全法送方法
     * @param token token地址
     * @param to 接收地址
     * @param amount 数额
     */
    function _safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        IERC20(token).safeTransfer(to, amount);
    }
}
