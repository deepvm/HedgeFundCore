// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IERC20, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract AUSD is ERC20, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDT;
    address public holder;
    address public minter;

    constructor(address owner_, IERC20 usdt_) ERC20("Altitude USD", "aUSD") Ownable(owner_) {
        require(address(usdt_) != address(0));
        USDT = usdt_;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(uint256 assets) external {
        USDT.safeTransferFrom(msg.sender, holder, assets);
        _mint(msg.sender, assets);
    }

    function burn(uint256 assets) external {
        _burn(msg.sender, assets);
        USDT.safeTransfer(msg.sender, assets);
    }

    function mintYield(uint256 assets) external {
        require(msg.sender == minter);
        _mint(msg.sender, assets);
    }

    function settings(address minter_, address holder_) external onlyOwner {
        require(minter_ != address(0) && holder_ != address(0));
        minter = minter_;
        holder = holder_;
    }

    function skim(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(owner(), amount);
    }
}
