// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import "./interfaces/IGoSwapFactory.sol";
import "./GoSwapPair.sol";

/**
 * @title GoSwap工厂合约
 */
contract GoSwapFactory is IGoSwapFactory {
    /// @notice 收税地址
    address public override feeTo;
    /// @notice 收税权限控制地址,应为治理地址
    address public override feeToSetter;
    /// @notice 迁移合约地址
    address public override migrator;
    /// @notice 配对映射,地址=>(地址=>地址)
    mapping(address => mapping(address => address)) public override getPair;
    /// @notice 所有配对数组
    address[] public override allPairs;

    /**
     * @dev 事件:创建配对
     * @param token0 token0
     * @param token1 token1
     * @param pair 配对地址
     */
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    /**
     * @dev 构造函数
     */
    constructor() public {
        feeToSetter = msg.sender;
    }

    /**
     * @dev 查询配对数组长度方法
     */
    function allPairsLength() external override view returns (uint256) {
        return allPairs.length;
    }

    /**
     * @dev  配对合约源代码Bytecode的hash值(用作前端计算配对合约地址)
     */
    function pairCodeHash() external override pure returns (bytes32) {
        return keccak256(type(GoSwapPair).creationCode);
    }

    /**
     * @dev 创建配对
     * @param tokenA TokenA
     * @param tokenB TokenB
     * @return pair 配对地址
     * @notice 应该从路由合约调用配对寻找工厂合约来调用,否则通过路由合约找不到配对合约
     */
    function createPair(address tokenA, address tokenB)
        external
        override
        returns (address pair)
    {
        //确认tokenA不等于tokenB
        require(tokenA != tokenB, "GoSwap: IDENTICAL_ADDRESSES");
        //将tokenA和tokenB进行大小排序,确保tokenA小于tokenB
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        //确认token0不等于0地址
        require(token0 != address(0), "GoSwap: ZERO_ADDRESS");
        //确认配对映射中不存在token0=>token1
        require(getPair[token0][token1] == address(0), "GoSwap: PAIR_EXISTS"); // single check is sufficient
        //给bytecode变量赋值"GoSwapPair"合约的创建字节码
        bytes memory bytecode = type(GoSwapPair).creationCode;
        //将token0和token1打包后创建哈希
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        //内联汇编
        //solium-disable-next-line
        assembly {
            //通过create2方法布署合约,并且加盐,返回地址到pair变量
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        //调用pair地址的合约中的"initialize"方法,传入变量token0,token1
        GoSwapPair(pair).initialize(token0, token1);
        //配对映射中设置token0=>token1=pair
        getPair[token0][token1] = pair;
        //配对映射中设置token1=>token0=pair
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        //配对数组中推入pair地址
        allPairs.push(pair);
        //触发配对成功事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }


    /**
     * @dev 修饰符:确认必须为工厂合约的FeeToSetter地址
     */
    modifier onlyFeeToSetter() {
        // 确认必须为工厂合约的FeeToSetter地址
        require(msg.sender == feeToSetter, "GoSwap: FORBIDDEN");
        _;
    }

    /**
     * @dev 设置收税地址
     * @param _feeTo 收税地址
     */
    function setFeeTo(address _feeTo) external override onlyFeeToSetter {
        feeTo = _feeTo;
    }

    /**
     * @dev 设置迁移合约地址的方法,只能由feeToSetter设置
     * @param _migrator 迁移合约地址
     */
    function setMigrator(address _migrator) external override onlyFeeToSetter {
        migrator = _migrator;
    }

    /**
     * @dev 设置收税权限控制
     * @param _feeToSetter 收税权限控制
     */
    function setFeeToSetter(address _feeToSetter)
        external
        override
        onlyFeeToSetter
    {
        feeToSetter = _feeToSetter;
    }
}
