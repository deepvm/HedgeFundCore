// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

interface ITRC20JToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
}

contract JustLendAdapter is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    error ZeroAddress();
    error MintFailed();
    error RedeemFailed();

    IERC20 public immutable usdt;
    ITRC20JToken public immutable jUSDT;
    address public minter;

    constructor(address _admin, address _operator, address _minter, address _usdt, address _jUSDT) {
        if (
            _minter == address(0) || _admin == address(0) || _operator == address(0) || _usdt == address(0)
                || _jUSDT == address(0)
        ) {
            revert ZeroAddress();
        }
        usdt = IERC20(_usdt);
        jUSDT = ITRC20JToken(_jUSDT);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
        minter = _minter;

        usdt.forceApprove(_jUSDT, type(uint256).max);
    }

    function deposit() external onlyRole(OPERATOR_ROLE) {
        uint256 uBalance = usdt.balanceOf(address(this));
        if (uBalance > 0) {
            if (jUSDT.mint(uBalance) != 0) revert MintFailed();
        }
    }

    function withdraw(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        if (jUSDT.redeemUnderlying(amount) != 0) revert RedeemFailed();
        usdt.safeTransfer(minter, amount);
    }

    function withdrawTo(uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (jUSDT.redeemUnderlying(amount) != 0) revert RedeemFailed();
        usdt.safeTransfer(to, amount);
    }

    function setMinter(address _minter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_minter == address(0)) revert ZeroAddress();
        minter = _minter;
    }
}
