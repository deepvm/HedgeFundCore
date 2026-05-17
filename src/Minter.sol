// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {AUSD} from "./aUSD.sol";

contract Minter is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant DEPOSIT_ROLE = keccak256("DEPOSIT_ROLE");
    IERC20 public immutable USDT;
    AUSD public immutable aUSD;

    constructor(address admin, IERC20 usdt_, AUSD ausd_) {
        require(address(usdt_) != address(0) && address(ausd_) != address(0));
        USDT = usdt_;
        aUSD = ausd_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function mint(uint256 assets, address deposit) external {
        _checkRole(DEPOSIT_ROLE, deposit);
        USDT.safeTransferFrom(msg.sender, deposit, assets);
        aUSD.mint(msg.sender, assets);
    }

    function burn(uint256 assets) external {
        aUSD.burn(msg.sender, assets);
        USDT.safeTransfer(msg.sender, assets);
    }

    function mintYield(uint256 assets) external onlyRole(VAULT_ROLE) {
        aUSD.mint(msg.sender, assets);
    }
}
