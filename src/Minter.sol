// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {AUSD} from "./aUSD.sol";

contract Minter is AccessControl, EIP712, Nonces {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant CUSTODY_ROLE = keccak256("CUSTODY_ROLE");
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    bytes32 public constant MINT_TYPEHASH =
        keccak256("Mint(address account,address custody,uint256 assets,uint256 nonce,uint256 deadline)");
    bytes32 public constant BURN_TYPEHASH =
        keccak256("Burn(address account,uint256 assets,uint256 nonce,uint256 deadline)");

    IERC20 public immutable USDT;
    AUSD public immutable aUSD;

    error ZeroAddress();
    error PermitExpired();
    error InvalidSignature();

    constructor(address admin_, IERC20 usdt_, AUSD ausd_) EIP712("aUSD Minter", "1") {
        if (admin_ == address(0) || address(usdt_) == address(0) || address(ausd_) == address(0)) {
            revert ZeroAddress();
        }
        USDT = usdt_;
        aUSD = ausd_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function mint(uint256 assets, address custody, address signer, uint256 deadline, bytes calldata signature)
        external
    {
        _checkRole(CUSTODY_ROLE, custody);
        _checkPermit(
            signer,
            _hashTypedDataV4(
                keccak256(abi.encode(MINT_TYPEHASH, msg.sender, custody, assets, _useNonce(msg.sender), deadline))
            ),
            deadline,
            signature
        );
        USDT.safeTransferFrom(msg.sender, custody, assets);
        aUSD.mint(msg.sender, assets);
    }

    function burn(uint256 assets, address signer, uint256 deadline, bytes calldata signature) external {
        _checkPermit(
            signer,
            _hashTypedDataV4(keccak256(abi.encode(BURN_TYPEHASH, msg.sender, assets, _useNonce(msg.sender), deadline))),
            deadline,
            signature
        );
        aUSD.burn(msg.sender, assets);
        USDT.safeTransfer(msg.sender, assets);
    }

    function mintYield(uint256 assets) external onlyRole(VAULT_ROLE) {
        aUSD.mint(msg.sender, assets);
    }

    function _checkPermit(address signer, bytes32 digest, uint256 deadline, bytes calldata signature) private view {
        if (block.timestamp > deadline) revert PermitExpired();
        _checkRole(SIGNER_ROLE, signer);
        if (!SignatureChecker.isValidSignatureNowCalldata(signer, digest, signature)) revert InvalidSignature();
    }
}
