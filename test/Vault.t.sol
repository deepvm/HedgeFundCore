// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AUSD} from "../src/aUSD.sol";
import {Vault} from "../src/Vault.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 assets) external {
        _mint(to, assets);
    }
}

contract VaultTest is Test {
    MockUSDT internal usdt;
    AUSD internal ausd;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal holder = makeAddr("holder");

    function setUp() public {
        usdt = new MockUSDT();
        ausd = new AUSD(owner, usdt);
        vault = new Vault(ausd, owner);

        vm.prank(owner);
        ausd.settings(address(vault), holder);

        vm.prank(owner);
        usdt.mint(user, 100e6);
    }

    function testMintAUSDSendsUSDTToholder() public {
        vm.startPrank(user);
        usdt.approve(address(ausd), 100e6);
        ausd.mint(100e6);
        vm.stopPrank();

        assertEq(usdt.balanceOf(holder), 100e6);
        assertEq(ausd.balanceOf(user), 100e6);
    }

    function testStakeAccruesAPRAndBurnsToUSDT() public {
        vm.startPrank(user);
        usdt.approve(address(ausd), 100e6);
        ausd.mint(100e6);
        ausd.approve(address(vault), 100e6);
        vault.deposit(100e6, user);
        vm.stopPrank();

        vm.prank(owner);
        vault.setAPR(10_000);

        vm.warp(block.timestamp + 365 days);
        uint256 expectedAssets = vault.previewRedeem(100e6);
        assertApproxEqAbs(expectedAssets, 200e6, 1);

        vm.prank(user);
        uint256 assets = vault.redeem(100e6, user, user);
        assertEq(assets, expectedAssets);

        usdt.mint(address(ausd), assets);

        vm.prank(user);
        ausd.burn(assets);

        assertEq(ausd.balanceOf(user), 0);
        assertEq(usdt.balanceOf(user), assets);
    }

    function testMetadata() public view {
        assertEq(ausd.name(), "Altitude USD");
        assertEq(ausd.symbol(), "aUSD");
        assertEq(ausd.decimals(), 6);
        assertEq(vault.name(), "Staked aUSD");
        assertEq(vault.symbol(), "saUSD");
        assertEq(vault.decimals(), 6);
        assertEq(vault.asset(), address(ausd));
    }
}
