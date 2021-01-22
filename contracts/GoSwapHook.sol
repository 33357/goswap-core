// SPDX-License-Identifier: MIT
pragma solidity =0.6.12;
import "./libraries/AdminRole.sol";
import '@openzeppelin/contracts/utils/EnumerableSet.sol';

interface ITOKEN {
    function mint(address recipient_, uint256 amount_) external returns (bool);
}

/**
* @title 交易钩子合约,替换这个合约可以在swap交易过程中插入操作
 */
contract GoSwapHook is AdminRole {
    using EnumerableSet for EnumerableSet.AddressSet;
    address public token;
    
    /// @dev 配对合约set
    EnumerableSet.AddressSet private _pairs;
    /**
     * @dev 事件:交换
     * @param sender 发送者
     * @param amount0Out 输出金额0
     * @param amount1Out 输出金额1
     * @param to to地址
     */
    event Swap(
        address indexed pair,
        address indexed sender,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );

    constructor (address _token) public{
        token = _token;
    }

    /**
     * @dev 返回所有配对合约
     * @return pairs 配对合约数组
     */
    function allPairs() public view returns (address[] memory pairs) {
        pairs = new address[](_pairs.length());
        for(uint256 i=0;i<_pairs.length();i++){
            pairs[i] = _pairs.at(i);
        }
    }

    /**
     * @dev 添加配对合约
     * @param pair 帐号地址
     */
    function addPair(address pair) public onlyAdmin {
        _pairs.add(pair);
    }

    /**
     * @dev 移除配对合约
     * @param pair 帐号地址
     */
    function removePair(address pair) public onlyAdmin {
        _pairs.remove(pair);
    }

    /**
     * @dev 修改器:只能通过配对合约调用
     */
    modifier onlyPair() {
        require(_pairs.contains(msg.sender), "Only Pair can call this");
        _;
    }


    /**
     * @dev 交换钩子
     * @param sender 发送者
     * @param amount0Out 输出金额0
     * @param amount1Out 输出金额1
     * @param to to地址
     */
    function swapHook(
        address sender,
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) public onlyPair {
        ITOKEN(token).mint(to,1 * 10**18);
        //触发交换事件
        emit Swap(msg.sender, sender, amount0Out, amount1Out, to);
    }
}
