// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JustLendAdapter, ITRC20JToken} from "../src/JustLendAdapter.sol";

contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 assets) external {
        _mint(to, assets);
    }
}

contract MockjUSDT is ITRC20JToken, ERC20 {
    IERC20 public immutable usdt;
    uint256 public mintReturnValue;
    uint256 public redeemReturnValue;

    constructor(address _usdt) ERC20("JustLend USDT", "jUSDT") {
        usdt = IERC20(_usdt);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function setMintReturnValue(uint256 val) external {
        mintReturnValue = val;
    }

    function setRedeemReturnValue(uint256 val) external {
        redeemReturnValue = val;
    }

    function mint(uint256 mintAmount) external override returns (uint256) {
        if (mintReturnValue == 0 && mintAmount > 0) {
            usdt.transferFrom(msg.sender, address(this), mintAmount);
            _mint(msg.sender, mintAmount);
        }
        return mintReturnValue;
    }

    function redeemUnderlying(uint256 redeemAmount) external override returns (uint256) {
        if (redeemReturnValue == 0 && redeemAmount > 0) {
            _burn(msg.sender, redeemAmount);
            usdt.transfer(msg.sender, redeemAmount);
        }
        return redeemReturnValue;
    }
}

contract JustLendAdapterTest is Test {
    MockUSDT internal usdt;
    MockjUSDT internal jUSDT;
    JustLendAdapter internal adapter;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal minter = makeAddr("minter");
    address internal user = makeAddr("user");

    function setUp() public {
        usdt = new MockUSDT();
        jUSDT = new MockjUSDT(address(usdt));

        adapter = new JustLendAdapter(admin, operator, minter, address(usdt), address(jUSDT));
    }

    function testInitialization() public view {
        assertEq(address(adapter.usdt()), address(usdt));
        assertEq(address(adapter.jUSDT()), address(jUSDT));
        assertEq(adapter.minter(), minter);

        assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(adapter.hasRole(adapter.OPERATOR_ROLE(), operator));
        assertFalse(adapter.hasRole(adapter.OPERATOR_ROLE(), user));

        assertEq(usdt.allowance(address(adapter), address(jUSDT)), type(uint256).max);
    }

    function testDepositSuccess() public {
        usdt.mint(address(adapter), 1000e6);

        vm.prank(operator);
        adapter.deposit();

        assertEq(usdt.balanceOf(address(adapter)), 0);
        assertEq(usdt.balanceOf(address(jUSDT)), 1000e6);
        assertEq(jUSDT.balanceOf(address(adapter)), 1000e6);
    }

    function testDepositRevertsIfNotOperator() public {
        usdt.mint(address(adapter), 1000e6);

        vm.prank(user);
        vm.expectRevert();
        adapter.deposit();
    }

    function testDepositRevertsIfMintFails() public {
        usdt.mint(address(adapter), 1000e6);

        jUSDT.setMintReturnValue(1);

        vm.prank(operator);
        vm.expectRevert();
        adapter.deposit();
    }

    function testWithdrawSuccess() public {
        usdt.mint(address(adapter), 1000e6);
        vm.prank(operator);
        adapter.deposit();

        vm.prank(operator);
        adapter.withdraw(400e6);

        assertEq(usdt.balanceOf(minter), 400e6);
        assertEq(usdt.balanceOf(address(jUSDT)), 600e6);
        assertEq(jUSDT.balanceOf(address(adapter)), 600e6);
    }

    function testWithdrawRevertsIfNotOperator() public {
        usdt.mint(address(adapter), 1000e6);
        vm.prank(operator);
        adapter.deposit();

        vm.prank(user);
        vm.expectRevert();
        adapter.withdraw(400e6);
    }

    function testWithdrawRevertsIfRedeemFails() public {
        usdt.mint(address(adapter), 1000e6);
        vm.prank(operator);
        adapter.deposit();

        jUSDT.setRedeemReturnValue(2);

        vm.prank(operator);
        vm.expectRevert();
        adapter.withdraw(400e6);
    }

    function testDepositZeroBalanceDoesNotCallMint() public {
        jUSDT.setMintReturnValue(1);
        vm.prank(operator);
        adapter.deposit();
    }

    function testConstructorZeroMinterReverts() public {
        vm.expectRevert();
        new JustLendAdapter(admin, operator, address(0), address(usdt), address(jUSDT));
    }

    function testSetMinterSuccess() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(admin);
        adapter.setMinter(newMinter);

        assertEq(adapter.minter(), newMinter);
    }

    function testSetMinterRevertsIfNotAdmin() public {
        address newMinter = makeAddr("newMinter");

        vm.prank(user);
        vm.expectRevert();
        adapter.setMinter(newMinter);
    }

    function testSetMinterZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert();
        adapter.setMinter(address(0));
    }
}
