// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPonsV2FeeEscrow} from "./interfaces/ILaunchpadV2.sol";

/**
 * @title PonsV2FeeEscrow
 * @notice Claimable fee ledger for the v2 launchpad. The bonding curves and
 * the meme hook credit quote-asset fees here (native ETH via `credit`,
 * ERC-20 via `creditToken`); protocol and creator recipients withdraw their
 * own balances at any time. Balances are per-recipient and per-asset.
 * Anyone may credit anyone; only the recipient may claim.
 */
contract PonsV2FeeEscrow is Ownable, IPonsV2FeeEscrow {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error InsufficientBalance();
    error TransferFailed();

    event FeeCredited(address indexed recipient, uint256 amount);
    event FeeTokenCredited(address indexed recipient, address indexed token, uint256 amount);

    mapping(address recipient => uint256 amount) private _ethBalances;
    mapping(address recipient => mapping(address token => uint256 amount)) private _tokenBalances;

    constructor(address initialOwner) Ownable(initialOwner) {}

    receive() external payable {}

    function credit(address recipient) external payable override {
        if (recipient == address(0)) revert ZeroAddress();
        _ethBalances[recipient] += msg.value;
        emit FeeCredited(recipient, msg.value);
    }

    function creditToken(address recipient, address token, uint256 amount) external override {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _tokenBalances[recipient][token] += amount;
        emit FeeTokenCredited(recipient, token, amount);
    }

    function claim() external override returns (uint256 amount) {
        amount = _ethBalances[msg.sender];
        if (amount == 0) revert InsufficientBalance();
        _ethBalances[msg.sender] = 0;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();
    }

    function claim(uint256 amount) external override returns (uint256) {
        if (amount == 0 || amount > _ethBalances[msg.sender]) revert InsufficientBalance();
        _ethBalances[msg.sender] -= amount;
        (bool sent,) = payable(msg.sender).call{value: amount}("");
        if (!sent) revert TransferFailed();
        return amount;
    }

    function claimToken(address token) external override returns (uint256 amount) {
        amount = _tokenBalances[msg.sender][token];
        if (amount == 0) revert InsufficientBalance();
        _tokenBalances[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function claimToken(address token, uint256 amount) external override returns (uint256) {
        if (amount == 0 || amount > _tokenBalances[msg.sender][token]) revert InsufficientBalance();
        _tokenBalances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        return amount;
    }

    function balanceOf(address recipient) external view override returns (uint256) {
        return _ethBalances[recipient];
    }

    function balanceOfToken(address recipient, address token) external view override returns (uint256) {
        return _tokenBalances[recipient][token];
    }
}
