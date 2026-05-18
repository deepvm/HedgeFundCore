// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AUSD} from "./aUSD.sol";
import {Minter} from "./Minter.sol";

contract Vault is ERC4626, AccessControl {
    uint256 private constant BPS = 10_000;
    Minter public immutable minter;
    uint256 public apy;
    uint256 public lastUpdate;

    constructor(AUSD asset_, Minter minter_, address admin) ERC20("Staked aUSD", "saUSD") ERC4626(asset_) {
        require(admin != address(0) && address(minter_) != address(0));
        minter = minter_;
        lastUpdate = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setAPY(uint256 apy_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(apy_ <= BPS);
        _sync();
        apy = apy_;
    }

    function totalAssets() public view override returns (uint256 assets) {
        assets = super.totalAssets();
        assets += assets * apy * (block.timestamp - lastUpdate) / BPS / 365 days;
    }

    function _transferIn(address from, uint256 assets) internal override {
        _sync();
        super._transferIn(from, assets);
    }

    function _transferOut(address to, uint256 assets) internal override {
        _sync();
        super._transferOut(to, assets);
    }

    function _sync() private {
        uint256 yield = super.totalAssets() * apy * (block.timestamp - lastUpdate) / BPS / 365 days;
        lastUpdate = block.timestamp;
        if (yield != 0) minter.mintYield(yield);
    }
}
