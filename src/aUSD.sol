// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract AUSD is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address admin) ERC20("Altitude USD", "aUSD") {
        require(admin != address(0));
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 assets) external onlyRole(MINTER_ROLE) {
        _mint(to, assets);
    }

    function burn(address from, uint256 assets) external onlyRole(MINTER_ROLE) {
        _burn(from, assets);
    }
}
