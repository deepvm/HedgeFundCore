// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {AUSD} from "../src/aUSD.sol";
import {Minter} from "../src/Minter.sol";
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
    Minter internal minter;
    Vault internal vault;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal exchange = makeAddr("exchange");

    function setUp() public {
        usdt = new MockUSDT();
        ausd = new AUSD(owner);
        minter = new Minter(owner, usdt, ausd);
        vault = new Vault(ausd, minter, owner);

        bytes32 minterRole = ausd.MINTER_ROLE();
        vm.prank(owner);
        ausd.grantRole(minterRole, address(minter));

        bytes32 vaultRole = minter.VAULT_ROLE();
        vm.prank(owner);
        minter.grantRole(vaultRole, address(vault));

        bytes32 depositRole = minter.DEPOSIT_ROLE();
        vm.prank(owner);
        minter.grantRole(depositRole, exchange);

        vm.prank(owner);
        usdt.mint(user, 100e6);
    }

    function testMintAUSDSendsUSDTToExchange() public {
        vm.startPrank(user);
        usdt.approve(address(minter), 100e6);
        minter.mint(100e6, exchange);
        vm.stopPrank();

        assertEq(usdt.balanceOf(exchange), 100e6);
        assertEq(ausd.balanceOf(user), 100e6);
    }

    function testStakeAccruesAPYAndBurnsToUSDT() public {
        vm.startPrank(user);
        usdt.approve(address(minter), 100e6);
        minter.mint(100e6, exchange);
        ausd.approve(address(vault), 100e6);
        vault.deposit(100e6, user);
        vm.stopPrank();

        vm.prank(owner);
        vault.setAPY(10_000);

        vm.warp(block.timestamp + 365 days);
        uint256 expectedAssets = vault.previewRedeem(100e6);
        assertApproxEqAbs(expectedAssets, 200e6, 1);

        vm.prank(user);
        uint256 assets = vault.redeem(100e6, user, user);
        assertEq(assets, expectedAssets);

        usdt.mint(address(minter), assets);

        vm.prank(user);
        minter.burn(assets);

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

    function testOnlyMinterCanMintAUSD() public {
        vm.expectRevert();
        ausd.mint(user, 1);
    }

    function testBlacklistedUserCannotReceiveAUSD() public {
        vm.prank(owner);
        ausd.blacklist(user, true);

        vm.startPrank(user);
        usdt.approve(address(minter), 1);
        vm.expectRevert();
        minter.mint(1, exchange);
        vm.stopPrank();
    }
}
