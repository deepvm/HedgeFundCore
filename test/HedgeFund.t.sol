// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC7540Deposit, IERC7540Operator, IERC7540Redeem} from "forge-std/interfaces/IERC7540.sol";
import {IERC7575} from "forge-std/interfaces/IERC7575.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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

contract ReentrantAsset is ERC20 {
    HedgeFund internal fund;
    address internal attacker;
    bool internal entered;

    constructor() ERC20("Reentrant USDT", "rUSDT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAttack(HedgeFund fund_, address attacker_) external {
        fund = fund_;
        attacker = attacker_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!entered && msg.sender == address(fund)) {
            entered = true;
            fund.requestDeposit(1, attacker, attacker);
        }

        return super.transferFrom(from, to, amount);
    }
}

contract HedgeFundTest is Test {
    uint256 private constant USDT = 1e6;

    MockAsset internal usdt;
    HedgeFund internal fund;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");
    address internal operator = makeAddr("operator");
    address internal receiver = makeAddr("receiver");
    address internal liquidityVault = makeAddr("liquidityVault");

    function setUp() public {
        usdt = new MockAsset(6);
        fund = new HedgeFund(owner, address(usdt), "Altitude Hedge Fund Share", "AHFS");

        usdt.mint(user, 1_000 * USDT);
        usdt.mint(user2, 1_000 * USDT);
        usdt.mint(owner, 1_000 * USDT);

        vm.prank(user);
        usdt.approve(address(fund), type(uint256).max);

        vm.prank(user2);
        usdt.approve(address(fund), type(uint256).max);

        vm.prank(owner);
        usdt.approve(address(fund), type(uint256).max);
    }

    function testRequestDepositTransfersAssetsButDoesNotMintShares() public {
        vm.prank(user);
        uint256 requestId = fund.requestDeposit(100 * USDT);

        assertEq(requestId, 1);
        assertEq(usdt.balanceOf(address(fund)), 100 * USDT);
        assertEq(usdt.balanceOf(owner), 1_000 * USDT);
        assertEq(fund.balanceOf(user), 0);
        assertEq(fund.totalSupply(), 0);
        assertEq(fund.pendingDepositRequest(requestId, user), 100 * USDT);
        assertEq(fund.pendingDepositAssets(), 100 * USDT);
    }

    function testSettleDepositEpochMintsClaimableSharesAndSendsSurplusToSafe() public {
        vm.prank(user);
        uint256 requestId = fund.requestDeposit(125 * USDT);

        _settle(125e16);

        assertEq(fund.currentEpoch(), requestId);
        assertEq(fund.sharePrice(), 125e16);
        assertEq(fund.pendingDepositRequest(requestId, user), 0);
        assertEq(fund.claimableDepositRequest(requestId, user), 125 * USDT);
        assertEq(fund.claimableDepositShares(requestId, user), 100 * USDT);
        assertEq(fund.balanceOf(address(fund)), 100 * USDT);
        assertEq(fund.totalClaimableDepositShares(), 100 * USDT);
        assertEq(usdt.balanceOf(address(fund)), 0);
        assertEq(usdt.balanceOf(owner), 1_125 * USDT);

        vm.prank(user);
        uint256 shares = fund.claimDeposit(requestId);

        assertEq(shares, 100 * USDT);
        assertEq(fund.balanceOf(user), 100 * USDT);
        assertEq(fund.balanceOf(address(fund)), 0);
        assertEq(fund.totalClaimableDepositShares(), 0);
    }

    function testRedeemFromClaimedSharesPullsDeficitFromSafe() public {
        uint256 depositRequestId = _depositSettleAndClaim(user, 100 * USDT, 1e18);

        vm.prank(user);
        uint256 redeemRequestId = fund.requestRedeem(40 * USDT);

        assertEq(redeemRequestId, depositRequestId + 1);
        assertEq(fund.balanceOf(user), 60 * USDT);
        assertEq(fund.balanceOf(address(fund)), 40 * USDT);
        assertEq(fund.pendingRedeemRequest(redeemRequestId, user), 40 * USDT);

        _settle(125e16);

        assertEq(fund.epochRedeemAssets(redeemRequestId), 50 * USDT);
        assertEq(fund.totalClaimableRedeemAssets(), 50 * USDT);
        assertEq(usdt.balanceOf(address(fund)), 50 * USDT);
        assertEq(usdt.balanceOf(owner), 1_050 * USDT);

        vm.prank(user);
        uint256 assets = fund.claimRedeem(redeemRequestId);

        assertEq(assets, 50 * USDT);
        assertEq(usdt.balanceOf(user), 950 * USDT);
        assertEq(fund.totalClaimableRedeemAssets(), 0);
    }

    function testEpochNetsDepositsAgainstRedeemsAndSendsExcessToSafe() public {
        _depositSettleAndClaim(user, 100 * USDT, 1e18);

        vm.prank(user);
        uint256 redeemRequestId = fund.requestRedeem(80 * USDT);

        vm.prank(user2);
        uint256 depositRequestId = fund.requestDeposit(100 * USDT);

        assertEq(depositRequestId, redeemRequestId);

        _settle(1e18);

        assertEq(fund.totalClaimableRedeemAssets(), 80 * USDT);
        assertEq(fund.claimableDepositShares(depositRequestId, user2), 100 * USDT);
        assertEq(usdt.balanceOf(address(fund)), 80 * USDT);
        assertEq(usdt.balanceOf(owner), 1_120 * USDT);

        vm.prank(user);
        fund.claimRedeem(redeemRequestId);

        vm.prank(user2);
        fund.claimDeposit(depositRequestId);

        assertEq(usdt.balanceOf(address(fund)), 0);
        assertEq(fund.balanceOf(user2), 100 * USDT);
    }

    function testRedeemUnclaimedDepositSharesWithoutClaiming() public {
        vm.prank(user);
        uint256 depositRequestId = fund.requestDeposit(100 * USDT);

        _settle(1e18);

        vm.prank(user);
        uint256 redeemRequestId = fund.requestRedeemClaimableDeposit(depositRequestId, 40 * USDT);

        assertEq(fund.claimableDepositShares(depositRequestId, user), 60 * USDT);
        assertEq(fund.totalClaimableDepositShares(), 60 * USDT);
        assertEq(fund.pendingRedeemRequest(redeemRequestId, user), 40 * USDT);

        _settle(125e16);

        assertEq(fund.totalClaimableRedeemAssets(), 50 * USDT);

        vm.prank(user);
        uint256 assets = fund.claimRedeem(redeemRequestId);

        assertEq(assets, 50 * USDT);

        vm.prank(user);
        uint256 remainingShares = fund.claimDeposit(depositRequestId);

        assertEq(remainingShares, 60 * USDT);
        assertEq(fund.balanceOf(user), 60 * USDT);
    }

    function testERC7540InterfacesAreSupported() public view {
        assertTrue(fund.supportsInterface(type(IERC7540Deposit).interfaceId));
        assertTrue(fund.supportsInterface(type(IERC7540Redeem).interfaceId));
        assertTrue(fund.supportsInterface(type(IERC7540Operator).interfaceId));
        assertTrue(fund.supportsInterface(type(IERC7575).interfaceId));
        assertTrue(fund.supportsInterface(type(IERC165).interfaceId));
        assertEq(fund.share(), address(fund));
    }

    function testERC7540ClaimFunctionsNeedClaimableBalance() public {
        vm.expectRevert(HedgeFund.ZeroAmount.selector);
        fund.deposit(1, user);

        vm.expectRevert(HedgeFund.ZeroAmount.selector);
        fund.mint(1, user);

        vm.expectRevert(HedgeFund.AsyncDeposit.selector);
        fund.previewDeposit(1);

        vm.expectRevert(HedgeFund.AsyncDeposit.selector);
        fund.previewMint(1);

        vm.expectRevert(HedgeFund.ZeroAmount.selector);
        fund.withdraw(1, user, address(this));

        vm.expectRevert(HedgeFund.ZeroAmount.selector);
        fund.redeem(1, user, address(this));

        vm.expectRevert(HedgeFund.AsyncRedeem.selector);
        fund.previewWithdraw(1);

        vm.expectRevert(HedgeFund.AsyncRedeem.selector);
        fund.previewRedeem(1);
    }

    function testERC7540DepositAndRedeemClaims() public {
        vm.prank(user);
        fund.requestDeposit(100 * USDT);

        _settle(1e18);

        vm.prank(user);
        uint256 shares = fund.deposit(100 * USDT, user);

        assertEq(shares, 100 * USDT);
        assertEq(fund.balanceOf(user), 100 * USDT);

        vm.prank(user);
        fund.requestRedeem(40 * USDT);

        _settle(125e16);

        vm.prank(user);
        uint256 assets = fund.redeem(40 * USDT, user, user);

        assertEq(assets, 50 * USDT);
        assertEq(usdt.balanceOf(user), 950 * USDT);
    }

    function testERC7540PartialMintAndWithdrawClaims() public {
        vm.prank(user);
        fund.requestDeposit(100 * USDT);

        _settle(125e16);

        assertEq(fund.maxMint(user), 80 * USDT);

        vm.prank(user);
        uint256 spentAssets = fund.mint(40 * USDT, user);

        assertEq(spentAssets, 50 * USDT);
        assertEq(fund.balanceOf(user), 40 * USDT);
        assertEq(fund.claimableDepositRequest(1, user), 50 * USDT);

        vm.prank(user);
        fund.deposit(50 * USDT, user);

        assertEq(fund.balanceOf(user), 80 * USDT);

        vm.prank(user);
        fund.requestRedeem(80 * USDT);

        _settle(125e16);

        assertEq(fund.maxWithdraw(user), 100 * USDT);

        vm.prank(user);
        uint256 burnedShares = fund.withdraw(50 * USDT, user, user);

        assertEq(burnedShares, 40 * USDT);
        assertEq(fund.maxRedeem(user), 40 * USDT);

        vm.prank(user);
        uint256 receivedAssets = fund.redeem(40 * USDT, user, user);

        assertEq(receivedAssets, 50 * USDT);
        assertEq(usdt.balanceOf(user), 1_000 * USDT);
    }

    function testWithdrawRoundingDoesNotOverReserveRedeemAssets() public {
        vm.prank(user);
        fund.requestDeposit(4);

        _settle(1e18);

        vm.prank(user);
        fund.deposit(4, user);

        vm.prank(user);
        fund.requestRedeem(3);

        _settle(15e17);

        assertEq(fund.totalClaimableRedeemAssets(), 4);

        vm.prank(user);
        uint256 burnedShares = fund.withdraw(2, user, user);

        assertEq(burnedShares, 2);
        assertEq(fund.totalClaimableRedeemAssets(), 1);
        assertEq(fund.maxWithdraw(user), 1);

        vm.prank(user);
        uint256 receivedAssets = fund.redeem(1, user, user);

        assertEq(receivedAssets, 1);
        assertEq(fund.totalClaimableRedeemAssets(), 0);
        assertEq(usdt.balanceOf(address(fund)), 1);
    }

    function testRequestDepositReentrancyIsBlocked() public {
        ReentrantAsset reentrantAsset = new ReentrantAsset();
        HedgeFund reentrantFund = new HedgeFund(owner, address(reentrantAsset), "Reentrant Share", "rSHARE");
        address attacker = makeAddr("attacker");

        reentrantAsset.mint(attacker, 100);
        reentrantAsset.setAttack(reentrantFund, attacker);

        vm.startPrank(attacker);
        reentrantAsset.approve(address(reentrantFund), type(uint256).max);
        reentrantFund.setOperator(address(reentrantAsset), true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        reentrantFund.requestDeposit(10);
        vm.stopPrank();
    }

    function testRequestsUseNextOwnerSettledEpoch() public {
        vm.prank(user);
        uint256 userRequestId = fund.requestDeposit(1);

        vm.prank(user2);
        uint256 user2RequestId = fund.requestDeposit(2);

        assertEq(userRequestId, 1);
        assertEq(user2RequestId, 1);

        _settle(1e18);

        vm.prank(user);
        uint256 requestId = fund.requestDeposit(1);

        assertEq(requestId, 2);
    }

    function testCannotSettleEmptyEpochOrExtremePrice() public {
        vm.prank(owner);
        vm.expectRevert(HedgeFund.EmptyEpoch.selector);
        fund.settleEpoch(1e18);

        vm.prank(user);
        fund.requestDeposit(100 * USDT);

        vm.prank(owner);
        vm.expectRevert(HedgeFund.PriceDeviationTooLarge.selector);
        fund.settleEpoch(2e18);

        vm.prank(owner);
        vm.expectRevert(HedgeFund.InvalidSharePrice.selector);
        fund.settleEpoch(1);

        _settle(15e17);

        assertEq(fund.sharePrice(), 15e17);
    }

    function testCancelPendingDepositRequest() public {
        vm.prank(user);
        uint256 requestId = fund.requestDeposit(100 * USDT);

        assertEq(fund.firstDepositRequest(user), requestId);
        assertEq(usdt.balanceOf(user), 900 * USDT);

        vm.prank(user);
        uint256 assets = fund.cancelDepositRequest(requestId);

        assertEq(assets, 100 * USDT);
        assertEq(usdt.balanceOf(user), 1_000 * USDT);
        assertEq(fund.pendingDepositAssets(), 0);
        assertEq(fund.epochDepositAssets(requestId), 0);
        assertEq(fund.firstDepositRequest(user), 0);

        vm.prank(owner);
        vm.expectRevert(HedgeFund.EmptyEpoch.selector);
        fund.settleEpoch(1e18);
    }

    function testCancelPendingRedeemRequest() public {
        _depositSettleAndClaim(user, 100 * USDT, 1e18);

        vm.prank(user);
        uint256 requestId = fund.requestRedeem(40 * USDT);

        assertEq(fund.firstRedeemRequest(user), requestId);
        assertEq(fund.balanceOf(user), 60 * USDT);

        vm.prank(user);
        uint256 shares = fund.cancelRedeemRequest(requestId);

        assertEq(shares, 40 * USDT);
        assertEq(fund.balanceOf(user), 100 * USDT);
        assertEq(fund.totalPendingRedeemShares(), 0);
        assertEq(fund.epochRedeemShares(requestId), 0);
        assertEq(fund.firstRedeemRequest(user), 0);
    }

    function testLiquidityVaultCanDifferFromOwner() public {
        usdt.mint(liquidityVault, 1_000 * USDT);

        vm.prank(liquidityVault);
        usdt.approve(address(fund), type(uint256).max);

        vm.prank(owner);
        fund.setLiquidityVault(liquidityVault);

        _depositSettleAndClaim(user, 100 * USDT, 1e18);

        assertEq(fund.liquidityVault(), liquidityVault);
        assertEq(usdt.balanceOf(liquidityVault), 1_100 * USDT);
        assertEq(usdt.balanceOf(owner), 1_000 * USDT);

        vm.prank(user);
        uint256 redeemRequestId = fund.requestRedeem(50 * USDT);

        _settle(1e18);

        assertEq(fund.totalClaimableRedeemAssets(), 50 * USDT);
        assertEq(usdt.balanceOf(address(fund)), 50 * USDT);
        assertEq(usdt.balanceOf(liquidityVault), 1_050 * USDT);

        vm.prank(user);
        fund.claimRedeem(redeemRequestId);

        assertEq(usdt.balanceOf(user), 950 * USDT);
    }

    function testSettlementSurplusIsPulledByLiquidityVault() public {
        vm.prank(user);
        fund.requestDeposit(100 * USDT);

        vm.prank(owner);
        fund.settleEpoch(1e18);

        assertEq(fund.pendingLiquidityAssets(), 100 * USDT);
        assertEq(usdt.balanceOf(owner), 1_000 * USDT);
        assertEq(usdt.balanceOf(address(fund)), 100 * USDT);

        vm.prank(owner);
        uint256 assets = fund.claimLiquidityAssets();

        assertEq(assets, 100 * USDT);
        assertEq(fund.pendingLiquidityAssets(), 0);
        assertEq(usdt.balanceOf(owner), 1_100 * USDT);
    }

    function testUnclaimedLiquiditySurplusCanFundLaterRedeems() public {
        vm.prank(user);
        uint256 depositRequestId = fund.requestDeposit(100 * USDT);

        vm.prank(owner);
        fund.settleEpoch(1e18);

        vm.prank(user);
        fund.claimDeposit(depositRequestId);

        vm.prank(user);
        fund.requestRedeem(50 * USDT);

        vm.prank(owner);
        usdt.approve(address(fund), 0);

        vm.prank(owner);
        fund.settleEpoch(1e18);

        assertEq(fund.pendingLiquidityAssets(), 50 * USDT);
        assertEq(fund.totalClaimableRedeemAssets(), 50 * USDT);
    }

    function testDepositLimitIncludesPendingDeposits() public {
        vm.prank(owner);
        fund.setDepositLimit(150 * USDT);

        vm.prank(user);
        fund.requestDeposit(100 * USDT);

        assertEq(fund.maxDeposit(user), 0);
        assertEq(fund.maxRequestDeposit(user), 50 * USDT);

        vm.prank(user2);
        vm.expectRevert(HedgeFund.DepositLimitExceeded.selector);
        fund.requestDeposit(51 * USDT);
    }

    function testDepositLimitIncludesClaimableRedeemAssets() public {
        vm.prank(owner);
        fund.setDepositLimit(150 * USDT);

        _depositSettleAndClaim(user, 100 * USDT, 1e18);

        vm.prank(user);
        fund.requestRedeem(50 * USDT);

        _settle(1e18);

        assertEq(fund.totalAssets(), 50 * USDT);
        assertEq(fund.totalClaimableRedeemAssets(), 50 * USDT);
        assertEq(fund.maxRequestDeposit(user2), 50 * USDT);
    }

    function testControllerActiveEpochListSkipsOtherSettledEpochs() public {
        vm.prank(user);
        uint256 firstRequestId = fund.requestDeposit(10 * USDT);

        _settle(1e18);

        for (uint256 i; i < 3; i++) {
            vm.prank(user2);
            fund.requestDeposit(1 * USDT);
            _settle(1e18);
        }

        vm.prank(user);
        uint256 secondRequestId = fund.requestDeposit(20 * USDT);

        _settle(1e18);

        assertEq(fund.maxDeposit(user), 30 * USDT);

        vm.prank(user);
        fund.claimDeposit(firstRequestId);

        assertEq(fund.firstDepositRequest(user), secondRequestId);

        vm.prank(user);
        fund.claimDeposit(secondRequestId);

        assertEq(fund.balanceOf(user), 30 * USDT);
        assertEq(fund.firstDepositRequest(user), 0);
    }

    function testOperatorCanClaimButNotRequestDeposit() public {
        vm.prank(user);
        fund.setOperator(operator, true);

        vm.prank(operator);
        vm.expectRevert(HedgeFund.NotRequestOwner.selector);
        fund.requestDeposit(100 * USDT, user, user);

        vm.prank(user);
        uint256 depositRequestId = fund.requestDeposit(100 * USDT);

        _settle(1e18);

        vm.prank(operator);
        uint256 shares = fund.claimDeposit(depositRequestId, receiver, user);

        assertEq(shares, 100 * USDT);
        assertEq(fund.balanceOf(receiver), 100 * USDT);
    }

    function testOnlyOwnerCanSettleAndPriceCannotBeZero() public {
        vm.prank(user);
        vm.expectRevert();
        fund.settleEpoch(1e18);

        vm.prank(owner);
        vm.expectRevert(HedgeFund.InvalidSharePrice.selector);
        fund.settleEpoch(0);
    }

    function _depositSettleAndClaim(address account, uint256 assets, uint256 price)
        internal
        returns (uint256 requestId)
    {
        vm.prank(account);
        requestId = fund.requestDeposit(assets);

        _settle(price);

        vm.prank(account);
        fund.claimDeposit(requestId);
    }

    function _settle(uint256 price) internal {
        vm.prank(owner);
        fund.settleEpoch(price);
        if (fund.pendingLiquidityAssets() != 0) {
            vm.prank(fund.liquidityVault());
            fund.claimLiquidityAssets();
        }
    }
}
