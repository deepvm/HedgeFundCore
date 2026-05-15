// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {AUSD} from "src/aUSD.sol";

contract Vault is ERC4626, Ownable {
    uint256 private constant BPS = 10_000;
    uint256 public apr;
    uint256 public lastUpdate;

    constructor(AUSD asset_, address owner_) ERC20("Staked aUSD", "saUSD") ERC4626(asset_) Ownable(owner_) {}

    function setAPR(uint256 apr_) external onlyOwner {
        require(apr_ < BPS);
        _sync();
        apr = apr_;
    }

    function totalAssets() public view override returns (uint256 assets) {
        assets = super.totalAssets();
        assets += assets * apr * (block.timestamp - lastUpdate) / BPS / 365 days;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _sync();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _sync();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _sync() private {
        uint256 yield = super.totalAssets() * apr * (block.timestamp - lastUpdate) / BPS / 365 days;
        lastUpdate = block.timestamp;
        if (yield != 0) AUSD(asset()).mintYield(yield);
    }
}
