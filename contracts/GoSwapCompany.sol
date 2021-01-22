// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;

import '@openzeppelin/contracts/utils/EnumerableSet.sol';
import './interfaces/IGoSwapFactory.sol';
import './interfaces/IGoSwapCompany.sol';
import './libraries/AdminRole.sol';

contract GoSwapCompany is AdminRole, IGoSwapCompany {
    using EnumerableSet for EnumerableSet.AddressSet;
    /// @notice 当前工厂合约
    address public override factory;
    /// @dev 工厂合约列表
    EnumerableSet.AddressSet private factorys;

    /// @notice 配对寻找工厂的映射,地址=>(地址=>地址)
    mapping(address => mapping(address => address)) public override pairForFactory;

    /**
     * @dev 创建配对
     * @param tokenA TokenA
     * @param tokenB TokenB
     * @return pair 配对地址
     */
    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        // 确认token没有过对应的工厂,或者是管理员创建的配对,可以强制更新工厂合约
        require(pairForFactory[tokenA][tokenB] == address(0) || isAdmin(msg.sender), 'GoSwap: PAIR_EXISTS');
        // 调用工厂合约的创建配对方法
        pair = IGoSwapFactory(factory).createPair(tokenA, tokenB);
        // 记录token对应的工厂合约地址
        pairForFactory[tokenA][tokenB] = factory;
        pairForFactory[tokenB][tokenA] = factory;
    }

    /**
     * @dev 设置新工厂合约
     * @param _factory 新工厂合约地址
     */
    function setNewFactory(address _factory) public onlyAdmin {
        require(!factorys.contains(_factory), 'factory exist!');
        factorys.add(_factory);
        factory = _factory;
    }

    /**
     * @dev 返回工厂合约数量
     * @return 工厂合约数量
     */
    function factoryLength() public view returns (uint256) {
        return factorys.length();
    }

    /**
     * @dev 根据索引查询工厂合约地址
     * @param index 索引
     * @return 工厂合约地址
     */
    function getFactoryByIndex(uint256 index) public view returns (address) {
        return factorys.at(index);
    }
}
