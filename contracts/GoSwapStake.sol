pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
* @title GoSwap 质押合约
 */
contract GoSwapStake is ERC20("GoSwap Stake", "sGOT"){
    using SafeMath for uint256;
    IERC20 public GOT;

    /**
    * @dev 构造函数
    * @param _GOT GoSwap Token地址
     */
    constructor(IERC20 _GOT) public {
        GOT = _GOT;// 0x6b3595068778dd592e39a122f4f5a5cf09c90fe2
    }

    /**
    * @dev 进入吧台,将自己的GoSwap Token发送到合约换取份额
    * @param _amount GoSwap Token数额
     */
    // 进入吧台, 支付一些GOT, 赚取份额
    // Enter the bar. Pay some GOT. Earn some shares.
    function enter(uint256 _amount) public {
        // 当前合约的GoSwap Token余额
        uint256 totalGOT = GOT.balanceOf(address(this));
        // 当前合约的总发行量
        uint256 totalShares = totalSupply();
        // 如果 当前合约的总发行量 == 0 || 当前合约的总发行量 == 0
        if (totalShares == 0 || totalGOT == 0) {
            // 当前合约铸造amount数量的token给调用者
            _mint(msg.sender, _amount);
        } else {
            // what数额 = 数额 * 当前合约的总发行量 / 当前合约的GoSwap Token余额
            uint256 what = _amount.mul(totalShares).div(totalGOT);
            // 当前合约铸造what数量的token给调用者
            _mint(msg.sender, what);
        }
        // 将amount数量的GoSwap Token从调用者发送到当前合约地址
        GOT.transferFrom(msg.sender, address(this), _amount);
    }

    /**
    * @dev 离开吧台,取回自己的GoSwap Token
    * @param _share GOT数额
     */
    // Leave the bar. Claim back your GOT.
    function leave(uint256 _share) public {
        // 当前合约的总发行量
        uint256 totalShares = totalSupply();
        // what数额 = 份额 * 当前合约在GoSwap Token的余额 / 当前合约的总发行量
        uint256 what = _share.mul(GOT.balanceOf(address(this))).div(totalShares);
        // 为调用者销毁份额
        _burn(msg.sender, _share);
        // 将what数额的GoSwap Token发送到调用者账户
        GOT.transfer(msg.sender, what);
    }
}