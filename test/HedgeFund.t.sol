// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {HedgeFund} from "../src/HedgeFund.sol";

contract MockAsset is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(uint8 decimals_) ERC20("Mock USDT", "USDT") {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract HedgeFundTest is Test {
    uint256 private constant USDT = 1e6;
    uint256 private constant WEEK = 7 days;

    MockAsset internal usdt;
    HedgeFund internal fund;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    function setUp() public {
        usdt = new MockAsset(6);
        fund = new HedgeFund(owner, address(usdt), "Altitude Hedge Fund Share", "AHFS");

        usdt.mint(user, 1_000 * USDT);
        usdt.mint(owner, 1_000 * USDT);

        vm.prank(user);
        usdt.approve(address(fund), type(uint256).max);
    }

    function testDepositMintsSharesAndForwardsAssetsToOwner() public {
        vm.prank(user);
        uint256 shares = fund.deposit(100 * USDT, user);

        assertEq(shares, 100 * USDT);
        assertEq(fund.balanceOf(user), 100 * USDT);
        assertEq(fund.totalAssets(), 100 * USDT);
        assertEq(usdt.balanceOf(address(fund)), 0);
        assertEq(usdt.balanceOf(owner), 1_100 * USDT);
        assertEq(fund.decimals(), 6);
    }

    function testOwnerReportedPriceVestsUpward() public {
        vm.prank(user);
        fund.deposit(100 * USDT, user);

        vm.prank(owner);
        fund.setSharePrice(125e16, WEEK);

        assertEq(fund.sharePrice(), 1e18);
        assertEq(fund.convertToAssets(100 * USDT), 100 * USDT);

        vm.warp(block.timestamp + 3 days + 12 hours);

        assertEq(fund.sharePrice(), 1125e15);
        assertEq(fund.convertToAssets(100 * USDT), 112_500_000);

        vm.warp(block.timestamp + 3 days + 12 hours);

        assertEq(fund.sharePrice(), 125e16);
        assertEq(fund.convertToAssets(100 * USDT), 125 * USDT);
        assertEq(fund.convertToShares(125 * USDT), 100 * USDT);
        assertEq(fund.totalAssets(), 125 * USDT);
    }

    function testOwnerReportedPriceDropAppliesImmediately() public {
        vm.prank(user);
        fund.deposit(100 * USDT, user);

        vm.prank(owner);
        fund.setSharePrice(125e16, WEEK);

        vm.warp(block.timestamp + WEEK);

        vm.prank(owner);
        fund.setSharePrice(9e17, WEEK);

        assertEq(fund.sharePrice(), 9e17);
        assertEq(fund.convertToAssets(100 * USDT), 90 * USDT);
    }

    function testSyncWithdrawAndRedeemAreDisabled() public {
        vm.prank(user);
        fund.deposit(100 * USDT, user);

        assertEq(fund.maxWithdraw(user), 0);
        assertEq(fund.maxRedeem(user), 0);

        vm.prank(user);
        vm.expectRevert();
        fund.withdraw(1, user, user);

        vm.prank(user);
        vm.expectRevert();
        fund.redeem(1, user, user);
    }

    function testRequestRedeemBurnsSharesAndFixesAssets() public {
        vm.prank(user);
        fund.deposit(100 * USDT, user);

        vm.prank(owner);
        fund.setSharePrice(120e16, 0);

        vm.prank(user);
        uint256 assets = fund.requestRedeem(50 * USDT);

        assertEq(assets, 60 * USDT);
        assertEq(fund.pendingRedeemAssets(user), 60 * USDT);
        assertEq(fund.totalPendingRedeemAssets(), 60 * USDT);
        assertEq(fund.balanceOf(user), 50 * USDT);
        assertEq(fund.totalAssets(), 60 * USDT);

        vm.prank(owner);
        fund.setSharePrice(150e16, WEEK);

        assertEq(fund.pendingRedeemAssets(user), 60 * USDT);
    }

    function testClaimRedeemPaysFixedAssetsAfterOwnerFundsVault() public {
        vm.prank(user);
        fund.deposit(100 * USDT, user);

        vm.prank(owner);
        fund.setSharePrice(120e16, 0);

        vm.prank(user);
        fund.requestRedeem(50 * USDT);

        vm.prank(owner);
        assertTrue(usdt.transfer(address(fund), 60 * USDT));

        uint256 userBalanceBefore = usdt.balanceOf(user);

        vm.prank(user);
        uint256 assets = fund.claimRedeem();

        assertEq(assets, 60 * USDT);
        assertEq(usdt.balanceOf(user), userBalanceBefore + 60 * USDT);
        assertEq(fund.pendingRedeemAssets(user), 0);
        assertEq(fund.totalPendingRedeemAssets(), 0);
    }

    function testRequestRedeemAccumulatesPendingAssets() public {
        vm.prank(user);
        fund.deposit(100 * USDT, user);

        vm.prank(user);
        fund.requestRedeem(40 * USDT);

        vm.prank(user);
        fund.requestRedeem(10 * USDT);

        assertEq(fund.pendingRedeemAssets(user), 50 * USDT);
        assertEq(fund.totalPendingRedeemAssets(), 50 * USDT);
        assertEq(fund.balanceOf(user), 50 * USDT);
    }

    function testDepositLimitCapsDepositsButDoesNotBlockRequestRedeem() public {
        vm.prank(owner);
        fund.setDepositLimit(150 * USDT);

        vm.prank(user);
        fund.deposit(100 * USDT, user);

        assertEq(fund.maxDeposit(user), 50 * USDT);

        vm.prank(user);
        vm.expectRevert();
        fund.deposit(51 * USDT, user);

        vm.prank(user);
        fund.requestRedeem(10 * USDT);

        assertEq(fund.pendingRedeemAssets(user), 10 * USDT);
    }

    function testDepositRevertsWhenSharesRoundToZero() public {
        vm.prank(owner);
        fund.setSharePrice(2e18, 0);

        vm.prank(user);
        vm.expectRevert(HedgeFund.ZeroAmount.selector);
        fund.deposit(1, user);
    }

    function testOnlyOwnerCanSetPriceAndPriceCannotBeZero() public {
        vm.prank(user);
        vm.expectRevert();
        fund.setSharePrice(2e18, 0);

        vm.prank(owner);
        vm.expectRevert(HedgeFund.InvalidSharePrice.selector);
        fund.setSharePrice(0, 0);
    }

    function testMaxMintDoesNotOverflowBelowOneDollarPrice() public {
        vm.prank(owner);
        fund.setSharePrice(5e17, 0);

        assertEq(fund.maxDeposit(user), type(uint256).max);
        assertEq(fund.maxMint(user), type(uint256).max);
    }
}
