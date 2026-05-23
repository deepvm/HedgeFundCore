// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    MockUSDT internal usdt;
    AUSD internal ausd;
    Minter internal minter;
    Vault internal vault;

    uint256 internal signerKey = 0xA11CE;
    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");
    address internal signer;
    address internal custody = makeAddr("custody");

    function setUp() public {
        signer = vm.addr(signerKey);
        usdt = new MockUSDT();
        ausd = new AUSD(owner);
        minter = new Minter(owner, usdt, ausd);
        vault = new Vault(owner, ausd, minter);

        bytes32 minterRole = ausd.MINTER_ROLE();
        vm.prank(owner);
        ausd.grantRole(minterRole, address(minter));

        bytes32 vaultRole = minter.VAULT_ROLE();
        vm.prank(owner);
        minter.grantRole(vaultRole, address(vault));

        bytes32 custodyRole = minter.CUSTODY_ROLE();
        vm.prank(owner);
        minter.grantRole(custodyRole, custody);

        bytes32 signerRole = minter.SIGNER_ROLE();
        vm.prank(owner);
        minter.grantRole(signerRole, signer);

        vm.prank(owner);
        usdt.mint(user, 100e6);
    }

    function testMintAUSDSendsUSDTToCustody() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _mintSignature(user, 100e6, custody, deadline);

        vm.startPrank(user);
        usdt.approve(address(minter), 100e6);
        minter.mint(100e6, custody, signer, deadline, signature);
        vm.stopPrank();

        assertEq(usdt.balanceOf(custody), 100e6);
        assertEq(ausd.balanceOf(user), 100e6);
    }

    function testStakeAccruesAPYAndBurnsToUSDT() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _mintSignature(user, 100e6, custody, deadline);

        vm.startPrank(user);
        usdt.approve(address(minter), 100e6);
        minter.mint(100e6, custody, signer, deadline, signature);
        ausd.approve(address(vault), 100e6);
        vault.deposit(100e6, user);
        vm.stopPrank();

        vm.prank(owner);
        vault.setAPY(10_000);

        vm.warp(block.timestamp + 365 days);
        uint256 expectedAssets = vault.previewRedeem(100e6);
        assertApproxEqAbs(expectedAssets, 200e6, 200000000);

        vm.prank(user);
        uint256 assets = vault.redeem(100e6, user, user);
        assertEq(assets, expectedAssets);

        usdt.mint(address(minter), assets);

        deadline = block.timestamp + 1 days;
        signature = _burnSignature(user, assets, deadline);
        vm.prank(user);
        minter.burn(assets, signer, deadline, signature);

        assertEq(ausd.balanceOf(user), 0);
        assertEq(usdt.balanceOf(user), assets);
    }

    function testMetadata() public view {
        assertEq(ausd.name(), "Altitude USD");
        assertEq(ausd.symbol(), "aUSD");
        assertEq(ausd.decimals(), 6);
        assertEq(vault.name(), "Staked aUSD");
        assertEq(vault.symbol(), "saUSD");
        assertEq(vault.decimals(), 18);
        assertEq(vault.asset(), address(ausd));
    }

    function testOnlyMinterCanMintAUSD() public {
        vm.expectRevert();
        ausd.mint(user, 1);
    }

    function testPermitCannotReplay() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _mintSignature(user, 1, custody, deadline);

        vm.startPrank(user);
        usdt.approve(address(minter), 2);
        minter.mint(1, custody, signer, deadline, signature);
        vm.expectRevert();
        minter.mint(1, custody, signer, deadline, signature);
        vm.stopPrank();
    }

    function testExpiredPermitReverts() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory signature = _mintSignature(user, 1, custody, deadline);

        vm.startPrank(user);
        usdt.approve(address(minter), 1);
        vm.expectRevert();
        minter.mint(1, custody, signer, deadline, signature);
        vm.stopPrank();
    }

    function testMintRequiresCustodyRole() public {
        address unauthorizedCustody = makeAddr("unauthorizedCustody");
        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _mintSignature(user, 1, unauthorizedCustody, deadline);

        vm.startPrank(user);
        usdt.approve(address(minter), 1);
        vm.expectRevert();
        minter.mint(1, unauthorizedCustody, signer, deadline, signature);
        vm.stopPrank();
    }

    function testMintSignatureIsBoundToCustody() public {
        address otherCustody = makeAddr("otherCustody");
        bytes32 custodyRole = minter.CUSTODY_ROLE();

        vm.prank(owner);
        minter.grantRole(custodyRole, otherCustody);

        uint256 deadline = block.timestamp + 1 days;
        bytes memory signature = _mintSignature(user, 1, custody, deadline);

        vm.startPrank(user);
        usdt.approve(address(minter), 1);
        vm.expectRevert();
        minter.mint(1, otherCustody, signer, deadline, signature);
        vm.stopPrank();
    }

    function _mintSignature(address account, uint256 assets, address custody_, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            keccak256(abi.encode(minter.MINT_TYPEHASH(), account, custody_, assets, minter.nonces(account), deadline))
        );
    }

    function _burnSignature(address account, uint256 assets, uint256 deadline) internal view returns (bytes memory) {
        return _sign(keccak256(abi.encode(minter.BURN_TYPEHASH(), account, assets, minter.nonces(account), deadline)));
    }

    function _sign(bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(signerKey, keccak256(abi.encodePacked("\x19\x01", _domain(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("aUSD Minter")),
                keccak256(bytes("1")),
                block.chainid,
                address(minter)
            )
        );
    }
}
