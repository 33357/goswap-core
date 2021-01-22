// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import './libraries/GoSwapLibrary.sol';
import './libraries/TransferHelper.sol';
import './interfaces/IGoSwapRouter.sol';
import './interfaces/IERC20GoSwap.sol';
import './interfaces/IWHT.sol';

/**
 * @title GoSwap 路由合约
 */
contract GoSwapRouter is IGoSwapRouter {
    using SafeMath for uint256;

    /// @notice 布署时定义的常量pairFor地址和WHT地址
    address public immutable override company;
    address public immutable override WHT;

    /**
     * @dev 修饰符:确保最后期限大于当前时间
     */
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, 'GoSwapRouter: EXPIRED');
        _;
    }

    /**
     * @dev 返回当前在使用的工厂合约地址,兼容旧版
     */
    function factory() public view override returns (address) {
        return IGoSwapCompany(company).factory();
    }

    /**
     * @dev 构造函数
     * @param _company 寻找配对合约地址
     * @param _WHT WHT合约地址 
     */
    constructor(address _company, address _WHT) public {
        company = _company;
        WHT = _WHT;
    }

    /**
     * @dev 收款方法
     */
    receive() external payable {
        //断言调用者为WHT合约地址
        assert(msg.sender == WHT); // only accept HT via fallback from the WHT contract
    }

    // **** 添加流动性 ****
    /**
     * @dev 添加流动性的私有方法
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @param amountADesired 期望数量A
     * @param amountBDesired 期望数量B
     * @param amountAMin 最小数量A
     * @param amountBMin 最小数量B
     * @return amountA   数量A
     * @return amountB   数量B
     */
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal virtual returns (uint256 amountA, uint256 amountB) {
        // 通过配对寻找工厂合约
        address pairFactory = IGoSwapCompany(company).pairForFactory(tokenA, tokenB);
        //如果工厂合约不存在,则创建配对
        if (pairFactory == address(0)) {
            IGoSwapCompany(company).createPair(tokenA, tokenB);
        }
        //获取不含虚流动性的储备量reserve{A,B}
        (uint256 reserveA, uint256 reserveB, ) = GoSwapLibrary.getReservesWithoutDummy(company, tokenA, tokenB);
        //如果储备reserve{A,B}==0
        if (reserveA == 0 && reserveB == 0) {
            //数量amount{A,B} = 期望数量A,B
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            //最优数量B = 期望数量A * 储备B / 储备A
            uint256 amountBOptimal = GoSwapLibrary.quote(amountADesired, reserveA, reserveB);
            //如果最优数量B <= 期望数量B
            if (amountBOptimal <= amountBDesired) {
                //确认最优数量B >= 最小数量B
                require(amountBOptimal >= amountBMin, 'GoSwapRouter: INSUFFICIENT_B_AMOUNT');
                //数量amount{A,B} = 期望数量A, 最优数量B
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                //最优数量A = 期望数量A * 储备A / 储备B
                uint256 amountAOptimal = GoSwapLibrary.quote(amountBDesired, reserveB, reserveA);
                //断言最优数量A <= 期望数量A
                assert(amountAOptimal <= amountADesired);
                //确认最优数量A >= 最小数量A
                require(amountAOptimal >= amountAMin, 'GoSwapRouter: INSUFFICIENT_A_AMOUNT');
                //数量amount{A,B} = 最优数量A, 期望数量B
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /**
     * @dev 添加流动性方法*
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @param amountADesired 期望数量A
     * @param amountBDesired 期望数量B
     * @param amountAMin 最小数量A
     * @param amountBMin 最小数量B
     * @param to to地址
     * @param deadline 最后期限
     * @return amountA   数量A
     * @return amountB   数量B
     * @return liquidity   流动性数量
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        virtual
        override
        ensure(deadline)
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        //添加流动性,获取数量A,数量B
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        //根据TokenA,TokenB地址,获取`pair合约`地址
        address pair = GoSwapLibrary.pairFor(company, tokenA, tokenB);
        //将数量为amountA的tokenA从msg.sender账户中安全发送到pair合约地址
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        //将数量为amountB的tokenB从msg.sender账户中安全发送到pair合约地址
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        //流动性数量 = pair合约的铸造方法铸造给to地址的返回值
        liquidity = IGoSwapPair(pair).mint(to);
    }

    /**
     * @dev 添加HT流动性方法*
     * @param token token地址
     * @param amountTokenDesired Token期望数量
     * @param amountTokenMin Token最小数量
     * @param amountHTMin HT最小数量
     * @param to to地址
     * @param deadline 最后期限
     * @return amountToken   Token数量
     * @return amountHT   ETH数量
     * @return liquidity   流动性数量
     */
    function addLiquidityHT(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountHTMin,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        ensure(deadline)
        returns (
            uint256 amountToken,
            uint256 amountHT,
            uint256 liquidity
        )
    {
        //添加流动性,获取Token数量,HT数量
        (amountToken, amountHT) = _addLiquidity(token, WHT, amountTokenDesired, msg.value, amountTokenMin, amountHTMin);
        //根据Token,WHT地址,获取`pair合约`地址
        address pair = GoSwapLibrary.pairFor(company, token, WHT);
        //将`Token数量`的token从msg.sender账户中安全发送到`pair合约`地址
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        //向`HT合约`存款`HT数量`的主币
        IWHT(WHT).deposit{value: amountHT}();
        //将`HT数量`的`HT`token发送到`pair合约`地址
        assert(IWHT(WHT).transfer(pair, amountHT));
        //流动性数量 = pair合约的铸造方法铸造给`to地址`的返回值
        liquidity = IGoSwapPair(pair).mint(to);
        //如果`收到的主币数量`>`HT数量` 则返还`收到的主币数量`-`HT数量`
        if (msg.value > amountHT) TransferHelper.safeTransferHT(msg.sender, msg.value - amountHT);
    }

    // **** 移除流动性 ****
    /**
     * @dev 移除流动性*
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @param liquidity 流动性数量
     * @param amountAMin 最小数量A
     * @param amountBMin 最小数量B
     * @param to to地址
     * @param deadline 最后期限
     * @return amountA   数量A
     * @return amountB   数量B
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        //计算TokenA,TokenB的CREATE2地址，而无需进行任何外部调用
        address pair = GoSwapLibrary.pairFor(company, tokenA, tokenB);
        //将流动性数量从用户发送到pair地址(需提前批准)
        IERC20GoSwap(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        //pair合约销毁流动性数量,并将数值0,1的token发送到to地址
        (uint256 amount0, uint256 amount1) = IGoSwapPair(pair).burn(to);
        //排序tokenA,tokenB
        (address token0, ) = GoSwapLibrary.sortTokens(tokenA, tokenB);
        //按排序后的token顺序返回数值AB
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        //确保数值AB大于最小值AB
        require(amountA >= amountAMin, 'GoSwapRouter: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'GoSwapRouter: INSUFFICIENT_B_AMOUNT');
    }

    /**
     * @dev 移除HT流动性*
     * @param token token地址
     * @param liquidity 流动性数量
     * @param amountTokenMin token最小数量
     * @param amountHTMin HT最小数量
     * @param to to地址
     * @param deadline 最后期限
     * @return amountToken   token数量
     * @return amountHT   HT数量
     */
    function removeLiquidityHT(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountHTMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) returns (uint256 amountToken, uint256 amountHT) {
        //(token数量,HT数量) = 移除流动性(token地址,WHT地址,流动性数量,token最小数量,HT最小数量,当前合约地址,最后期限)
        (amountToken, amountHT) = removeLiquidity(
            token,
            WHT,
            liquidity,
            amountTokenMin,
            amountHTMin,
            address(this),
            deadline
        );
        //将token数量的token发送到to地址
        TransferHelper.safeTransfer(token, to, amountToken);
        //从WHT取款HT数量的主币
        IWHT(WHT).withdraw(amountHT);
        //将HT数量的HT发送到to地址
        TransferHelper.safeTransferHT(to, amountHT);
    }

    /**
     * @dev 带签名移除流动性*
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @param liquidity 流动性数量
     * @param amountAMin 最小数量A
     * @param amountBMin 最小数量B
     * @param to to地址
     * @param deadline 最后期限
     * @param approveMax 全部批准
     * @param v v
     * @param r r
     * @param s s
     * @return amountA   数量A
     * @return amountB   数量B
     */
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountA, uint256 amountB) {
        //计算TokenA,TokenB的CREATE2地址，而无需进行任何外部调用
        address pair = GoSwapLibrary.pairFor(company, tokenA, tokenB);
        //如果全部批准,value值等于最大uint256,否则等于流动性
        uint256 value = approveMax ? uint256(-1) : liquidity;
        //调用pair合约的许可方法(调用账户,当前合约地址,数值,最后期限,v,r,s)
        IERC20GoSwap(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        //(数量A,数量B) = 移除流动性(tokenA地址,tokenB地址,流动性数量,最小数量A,最小数量B,to地址,最后期限)
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    /**
     * @dev 带签名移除HT流动性*
     * @param token token地址
     * @param liquidity 流动性数量
     * @param amountTokenMin token最小数量
     * @param amountHTMin HT最小数量
     * @param to to地址
     * @param deadline 最后期限
     * @param approveMax 全部批准
     * @param v v
     * @param r r
     * @param s s
     * @return amountToken   token数量
     * @return amountHT   HT数量
     */
    function removeLiquidityHTWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountHTMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountToken, uint256 amountHT) {
        //计算Token,WETH的CREATE2地址，而无需进行任何外部调用
        address pair = GoSwapLibrary.pairFor(company, token, WHT);
        //如果全部批准,value值等于最大uint256,否则等于流动性
        uint256 value = approveMax ? uint256(-1) : liquidity;
        //调用pair合约的许可方法(调用账户,当前合约地址,数值,最后期限,v,r,s)
        IERC20GoSwap(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        //(token数量,HT数量) = 移除HT流动性(token地址,流动性数量,token最小数量,HT最小数量,to地址,最后期限)
        (amountToken, amountHT) = removeLiquidityHT(token, liquidity, amountTokenMin, amountHTMin, to, deadline);
    }

    /**
     * @dev 移除流动性支持Token收转帐税*
     * @param token token地址
     * @param liquidity 流动性数量
     * @param amountTokenMin token最小数量
     * @param amountHTMin HT最小数量
     * @param to to地址
     * @param deadline 最后期限
     * @return amountHT   HT数量
     */
    function removeLiquidityHTSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountHTMin,
        address to,
        uint256 deadline
    ) public virtual override ensure(deadline) returns (uint256 amountHT) {
        //(,HT数量) = 移除流动性(token地址,WHT地址,流动性数量,token最小数量,HT最小数量,当前合约地址,最后期限)
        (, amountHT) = removeLiquidity(token, WHT, liquidity, amountTokenMin, amountHTMin, address(this), deadline);
        //将当前合约中的token数量的token发送到to地址
        TransferHelper.safeTransfer(token, to, IERC20GoSwap(token).balanceOf(address(this)));
        //从WHT取款HT数量的主币
        IWHT(WHT).withdraw(amountHT);
        //将HT数量的HT发送到to地址
        TransferHelper.safeTransferHT(to, amountHT);
    }

    /**
     * @dev 带签名移除流动性,支持Token收转帐税*
     * @param token token地址
     * @param liquidity 流动性数量
     * @param liquidity 流动性数量
     * @param amountTokenMin token最小数量
     * @param amountHTMin HT最小数量
     * @param to to地址
     * @param deadline 最后期限
     * @param approveMax 全部批准
     * @param v v
     * @param r r
     * @param s s
     * @return amountHT   HT数量
     */
    function removeLiquidityHTWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountHTMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external virtual override returns (uint256 amountHT) {
        //计算Token,WHT的CREATE2地址，而无需进行任何外部调用
        address pair = GoSwapLibrary.pairFor(company, token, WHT);
        //如果全部批准,value值等于最大uint256,否则等于流动性
        uint256 value = approveMax ? uint256(-1) : liquidity;
        //调用pair合约的许可方法(调用账户,当前合约地址,数值,最后期限,v,r,s)
        IERC20GoSwap(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        //(,HT数量) = 移除流动性支持Token收转帐税(token地址,流动性数量,Token最小数量,HT最小数量,to地址,最后期限)
        amountHT = removeLiquidityHTSupportingFeeOnTransferTokens(
            token,
            liquidity,
            amountTokenMin,
            amountHTMin,
            to,
            deadline
        );
    }

    // **** 交换 ****
    /**
     * @dev 私有交换*
     * @notice 要求初始金额已经发送到第一对
     * @param amounts 数额数组
     * @param path 路径数组
     * @param _to to地址
     */
    function _swap(
        uint256[] memory amounts,
        address[] memory path,
        address _to
    ) internal virtual {
        //遍历路径数组
        for (uint256 i; i < path.length - 1; i++) {
            //(输入地址,输出地址) = (当前地址,下一个地址)
            (address input, address output) = (path[i], path[i + 1]);
            //token0 = 排序(输入地址,输出地址)
            (address token0, ) = GoSwapLibrary.sortTokens(input, output);
            //输出数量 = 数额数组下一个数额
            uint256 amountOut = amounts[i + 1];
            //(输出数额0,输出数额1) = 输入地址==token0 ? (0,输出数额) : (输出数额,0)
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            //to地址 = i<路径长度-2 ? (输出地址,路径下下个地址)的pair合约地址 : to地址
            address to = i < path.length - 2 ? GoSwapLibrary.pairFor(company, output, path[i + 2]) : _to;
            //调用(输入地址,输出地址)的pair合约地址的交换方法(输出数额0,输出数额1,to地址,0x00)
            IGoSwapPair(GoSwapLibrary.pairFor(company, input, output)).swap(
                amount0Out,
                amount1Out,
                to,
                new bytes(0)
            );
        }
    }

    /**
     * @dev 根据精确的token交换尽量多的token*
     * @param amountIn 精确输入数额
     * @param amountOutMin 最小输出数额
     * @param path 路径数组
     * @param to to地址
     * @param deadline 最后期限
     * @return amounts  数额数组
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) returns (uint256[] memory amounts) {
        //数额数组 ≈ 遍历路径数组(
        //      (输入数额 * (1000-fee) * 储备量Out) /
        //      (储备量In * 1000 + 输入数额 * (1000-fee)))
        amounts = GoSwapLibrary.getAmountsOut(company, amountIn, path);
        //确认数额数组最后一个元素>=最小输出数额
        require(amounts[amounts.length - 1] >= amountOutMin, 'GoSwapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        //将数量为数额数组[0]的路径[0]的token从调用者账户发送到路径0,1的pair合约
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            GoSwapLibrary.pairFor(company, path[0], path[1]),
            amounts[0]
        );
        //私有交换(数额数组,路径数组,to地址)
        _swap(amounts, path, to);
    }

    /**
     * @dev 使用尽量少的token交换精确的token*
     * @param amountOut 精确输出数额
     * @param amountInMax 最大输入数额
     * @param path 路径数组
     * @param to to地址
     * @param deadline 最后期限
     * @return amounts  数额数组
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) returns (uint256[] memory amounts) {
        //数额数组 ≈ 遍历路径数组(
        //      (储备量In * 储备量Out * 1000) /
        //      (储备量Out - 输出数额 * (1000-fee)) + 1)
        amounts = GoSwapLibrary.getAmountsIn(company, amountOut, path);
        //确认数额数组第一个元素<=最大输入数额
        require(amounts[0] <= amountInMax, 'GoSwapRouter: EXCESSIVE_INPUT_AMOUNT');
        //将数量为数额数组[0]的路径[0]的token从调用者账户发送到路径0,1的pair合约
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            GoSwapLibrary.pairFor(company, path[0], path[1]),
            amounts[0]
        );
        //私有交换(数额数组,路径数组,to地址)
        _swap(amounts, path, to);
    }

    /**
     * @dev 根据精确的ETH交换尽量多的token*
     * @param amountOutMin 最小输出数额
     * @param path 路径数组
     * @param to to地址
     * @param deadline 最后期限
     * @return amounts  数额数组
     */
    function swapExactHTForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) returns (uint256[] memory amounts) {
        //确认路径第一个地址为WHT
        require(path[0] == WHT, 'GoSwapRouter: INVALID_PATH');
        //数额数组 ≈ 遍历路径数组(
        //      (msg.value * (1000-fee) * 储备量Out) /
        //      (储备量In * 1000 + msg.value * (1000-fee)))
        amounts = GoSwapLibrary.getAmountsOut(company, msg.value, path);
        //确认数额数组最后一个元素>=最小输出数额
        require(amounts[amounts.length - 1] >= amountOutMin, 'GoSwapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        //将数额数组[0]的数额存款HT到HT合约
        IWHT(WHT).deposit{value: amounts[0]}();
        //断言将数额数组[0]的数额的HT发送到路径(0,1)的pair合约地址
        assert(IWHT(WHT).transfer(GoSwapLibrary.pairFor(company, path[0], path[1]), amounts[0]));
        //私有交换(数额数组,路径数组,to地址)
        _swap(amounts, path, to);
    }

    /**
     * @dev 使用尽量少的token交换精确的HT*
     * @param amountOut 精确输出数额
     * @param amountInMax 最大输入数额
     * @param path 路径数组
     * @param to to地址
     * @param deadline 最后期限
     * @return amounts  数额数组
     */
    function swapTokensForExactHT(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) returns (uint256[] memory amounts) {
        //确认路径最后一个地址为WHT
        require(path[path.length - 1] == WHT, 'GoSwapRouter: INVALID_PATH');
        //数额数组 ≈ 遍历路径数组(
        //      (储备量In * 储备量Out * 1000) /
        //      (储备量Out - 输出数额 * (1000-fee)) + 1)
        amounts = GoSwapLibrary.getAmountsIn(company, amountOut, path);
        //确认数额数组第一个元素<=最大输入数额
        require(amounts[0] <= amountInMax, 'GoSwapRouter: EXCESSIVE_INPUT_AMOUNT');
        //将数量为数额数组[0]的路径[0]的token从调用者账户发送到路径0,1的pair合约
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            GoSwapLibrary.pairFor(company, path[0], path[1]),
            amounts[0]
        );
        //私有交换(数额数组,路径数组,当前合约地址)
        _swap(amounts, path, address(this));
        //从HT合约提款数额数组最后一个数值的HT
        IWHT(WHT).withdraw(amounts[amounts.length - 1]);
        //将数额数组最后一个数值的ETH发送到to地址
        TransferHelper.safeTransferHT(to, amounts[amounts.length - 1]);
    }

    /**
     * @dev 根据精确的token交换尽量多的HT*
     * @param amountIn 精确输入数额
     * @param amountOutMin 最小输出数额
     * @param path 路径数组
     * @param to to地址
     * @param deadline 最后期限
     * @return amounts  数额数组
     */
    function swapExactTokensForHT(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) returns (uint256[] memory amounts) {
        //确认路径最后一个地址为WHT
        require(path[path.length - 1] == WHT, 'GoSwapRouter: INVALID_PATH');
        //数额数组 ≈ 遍历路径数组(
        //      (输入数额 * (1000-fee) * 储备量Out) /
        //      (储备量In * 1000 + 输入数额 * (1000-fee))))
        amounts = GoSwapLibrary.getAmountsOut(company, amountIn, path);
        //确认数额数组最后一个元素>=最小输出数额
        require(amounts[amounts.length - 1] >= amountOutMin, 'GoSwapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        //将数量为数额数组[0]的路径[0]的token从调用者账户发送到路径0,1的pair合约
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            GoSwapLibrary.pairFor(company, path[0], path[1]),
            amounts[0]
        );
        //私有交换(数额数组,路径数组,当前合约地址)
        _swap(amounts, path, address(this));
        //从WHT合约提款数额数组最后一个数值的HT
        IWHT(WHT).withdraw(amounts[amounts.length - 1]);
        //将数额数组最后一个数值的HT发送到to地址
        TransferHelper.safeTransferHT(to, amounts[amounts.length - 1]);
    }

    /**
     * @dev 使用尽量少的HT交换精确的token*
     * @param amountOut 精确输出数额
     * @param path 路径数组
     * @param to to地址
     * @param deadline 最后期限
     * @return amounts  数额数组
     */
    function swapHTForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) returns (uint256[] memory amounts) {
        //确认路径第一个地址为WHT
        require(path[0] == WHT, 'GoSwapRouter: INVALID_PATH');
        //数额数组 ≈ 遍历路径数组(
        //      (储备量In * 储备量Out * 1000) /
        //      (储备量Out - 输出数额 * (1000-fee)) + 1)
        amounts = GoSwapLibrary.getAmountsIn(company, amountOut, path);
        //确认数额数组第一个元素<=msg.value
        require(amounts[0] <= msg.value, 'GoSwapRouter: EXCESSIVE_INPUT_AMOUNT');
        //将数额数组[0]的数额存款ETH到WHT合约
        IWHT(WHT).deposit{value: amounts[0]}();
        //断言将数额数组[0]的数额的WHT发送到路径(0,1)的pair合约地址
        assert(IWHT(WHT).transfer(GoSwapLibrary.pairFor(company, path[0], path[1]), amounts[0]));
        //私有交换(数额数组,路径数组,to地址)
        _swap(amounts, path, to);
        //如果`收到的主币数量`>`数额数组[0]` 则返还`收到的主币数量`-`数额数组[0]`
        if (msg.value > amounts[0]) TransferHelper.safeTransferHT(msg.sender, msg.value - amounts[0]);
    }

    // **** 交换 (支持收取转帐税的Token) ****
    // requires the initial amount to have already been sent to the first pair
    /**
     * @dev 私有交换支持Token收转帐税*
     * @param path 路径数组
     * @param _to to地址
     */
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        //遍历路径数组
        for (uint256 i; i < path.length - 1; i++) {
            //(输入地址,输出地址) = (当前地址,下一个地址)
            (address input, address output) = (path[i], path[i + 1]);
            // 根据输入地址,输出地址找到配对合约
            IGoSwapPair pair = IGoSwapPair(GoSwapLibrary.pairFor(company, input, output));
            //token0 = 排序(输入地址,输出地址)
            (address token0, ) = GoSwapLibrary.sortTokens(input, output);
            // 定义一些数额变量
            uint256 amountInput;
            uint256 amountOutput;
            {
                //避免堆栈太深的错误
                //获取配对的交易手续费
                uint8 fee = pair.fee();
                //获取配对合约的储备量0,储备量1
                (uint256 reserve0, uint256 reserve1, ) = pair.getReserves();
                // 排序输入储备量和输出储备量
                (uint256 reserveInput, uint256 reserveOutput) =
                    input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
                // 储备量0,1,配对合约中的余额-储备量
                amountInput = input == token0
                    ? pair.balanceOfIndex(0).sub(reserve0)
                    : pair.balanceOfIndex(1).sub(reserve1);
                //根据输入数额,输入储备量,输出储备量,交易手续费计算输出数额
                amountOutput = GoSwapLibrary.getAmountOut(amountInput, reserveInput, reserveOutput, fee);
            }
            // // 排序输出数额0,输出数额1
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOutput) : (amountOutput, uint256(0));
            //to地址 = i<路径长度-2 ? (输出地址,路径下下个地址)的pair合约地址 : to地址
            address to = i < path.length - 2 ? GoSwapLibrary.pairFor(company, output, path[i + 2]) : _to;
            //调用pair合约的交换方法(输出数额0,输出数额1,to地址,0x00)
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /**
     * @dev 根据精确的token交换尽量多的token,支持Token收转帐税*
     * @param amountIn 精确输入数额
     * @param amountOutMin 最小输出数额
     * @param path 路径数组
     * @param to to地址
     * @param deadline 最后期限
     */
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) {
        //将数量为数额数组[0]的路径[0]的token从调用者账户发送到路径0,1的pair合约
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            GoSwapLibrary.pairFor(company, path[0], path[1]),
            amountIn
        );
        // 记录to地址在地址路径最后一个token中的余额
        uint256 balanceBefore = IERC20GoSwap(path[path.length - 1]).balanceOf(to);
        // 调用私有交换支持Token收转帐税方法
        _swapSupportingFeeOnTransferTokens(path, to);
        // 确认to地址收到的地址路径中最后一个token数量大于最小输出数量
        require(
            IERC20GoSwap(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'GoSwapRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    /**
     * @dev 根据精确的ETH交换尽量多的token,支持Token收转帐税*
     * @param amountOutMin 最小输出数额
     * @param path 路径数组
     * @param to to地址
     * @param deadline 最后期限
     */
    function swapExactHTForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override ensure(deadline) {
        //确认路径第一个地址为WHT
        require(path[0] == WHT, 'GoSwapRouter: INVALID_PATH');
        //输入数量=合约收到的主币数量
        uint256 amountIn = msg.value;
        //向WHT合约存款HT
        IWHT(WHT).deposit{value: amountIn}();
        //断言将WHT发送到了地址路径0,1组成的配对合约中
        assert(IWHT(WHT).transfer(GoSwapLibrary.pairFor(company, path[0], path[1]), amountIn));
        // 记录to地址在地址路径最后一个token中的余额
        uint256 balanceBefore = IERC20GoSwap(path[path.length - 1]).balanceOf(to);
        // 调用私有交换支持Token收转帐税方法
        _swapSupportingFeeOnTransferTokens(path, to);
        // 确认to地址收到的地址路径中最后一个token数量大于最小输出数量
        require(
            IERC20GoSwap(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'GoSwapRouter: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    /**
     * @dev 根据精确的token交换尽量多的HT,支持Token收转帐税*
     * @param amountIn 精确输入数额
     * @param amountOutMin 最小输出数额
     * @param path 路径数组
     * @param to to地址
     * @param deadline 最后期限
     */
    function swapExactTokensForHTSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override ensure(deadline) {
        //确认路径最后一个地址为WHT
        require(path[path.length - 1] == WHT, 'GoSwapRouter: INVALID_PATH');
        //将地址路径0的Token发送到地址路径0,1组成的配对合约
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            GoSwapLibrary.pairFor(company, path[0], path[1]),
            amountIn
        );
        //调用私有交换支持Token收转帐税方法
        _swapSupportingFeeOnTransferTokens(path, address(this));
        //输出金额=当前合约收到的WHT数量
        uint256 amountOut = IERC20GoSwap(WHT).balanceOf(address(this));
        //确认输出金额大于最小输出数额
        require(amountOut >= amountOutMin, 'GoSwapRouter: INSUFFICIENT_OUTPUT_AMOUNT');
        //向WHT合约取款
        IWHT(WHT).withdraw(amountOut);
        //将HT发送到to地址
        TransferHelper.safeTransferHT(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) public pure virtual override returns (uint256 amountB) {
        return GoSwapLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint8 fee
    ) public pure virtual override returns (uint256 amountOut) {
        return GoSwapLibrary.getAmountOut(amountIn, reserveIn, reserveOut, fee);
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint8 fee
    ) public pure virtual override returns (uint256 amountIn) {
        return GoSwapLibrary.getAmountIn(amountOut, reserveIn, reserveOut, fee);
    }

    function getAmountsOut(uint256 amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint256[] memory amounts)
    {
        return GoSwapLibrary.getAmountsOut(company, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint256[] memory amounts)
    {
        return GoSwapLibrary.getAmountsIn(company, amountOut, path);
    }
}
