// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Permit2 interface for signature-based transfers
interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

contract WorldServices is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPermit2 public immutable permit2;

    mapping(address => bool) public allowedTokens;

    event PaymentProcessed(
        address customer,
        uint256 amountPaid,
        address tokenAddress,
        string paymentId,
        string serviceCode,
        string merchantSlug
    );

    event CommissionPaid(
        address indexed recipient,
        uint256 amount,
        address tokenAddress,
        string paymentId
    );

    event TokenAllowed(address indexed tokenAddress);
    event TokenDisallowed(address indexed tokenAddress);

    error UnsupportedToken(address tokenAddress);
    error TransferFailed();
    error PermitNotForETH();
    error InsufficientPermitAmount();

    // @token_address: usdc on world chain 0x79A02482A880bCE3F13e09Da970dC34db4CD24d1
    // @permit2_address: permit2 on world chain 0x000000000022D473030F116dDEE9F6B43aC78BA3
    constructor(
        address initialOwner,
        address permit2_address,
        address[] memory initialAllowedTokens
    ) Ownable(initialOwner) {
        permit2 = IPermit2(permit2_address);
        for (uint256 i = 0; i < initialAllowedTokens.length; i++) {
            allowedTokens[initialAllowedTokens[i]] = true;
            emit TokenAllowed(initialAllowedTokens[i]);
        }
    }

    /**
     * @dev Permite al owner agregar un token a la lista de permitidos.
     */
    function allowToken(address tokenAddress) external onlyOwner {
        allowedTokens[tokenAddress] = true;
        emit TokenAllowed(tokenAddress);
    }

    /**
     * @dev Permite al owner remover un token de la lista de permitidos.
     */
    function disallowToken(address tokenAddress) external onlyOwner {
        allowedTokens[tokenAddress] = false;
        emit TokenDisallowed(tokenAddress);
    }

    function processPaymentWithPermit(
        address tokenAddress,
        uint160 amountPaid,
        string memory paymentId,
        string memory serviceCode,
        string memory merchantSlug,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant {
        require(amountPaid > 0, "No amount specified");
        require(permit.deadline > block.timestamp, "Permit expired");
        if (tokenAddress == address(0)) revert PermitNotForETH();
        if (!allowedTokens[tokenAddress]) revert UnsupportedToken(tokenAddress);
        require(
            permit.permitted.token == tokenAddress,
            "Permit token mismatch"
        );

        // Consume the user's permit signature and transfer tokens
        permit2.permitTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({
                to: address(this),
                requestedAmount: amountPaid
            }),
            msg.sender,
            signature
        );

        emit PaymentProcessed(
            msg.sender,
            amountPaid,
            tokenAddress,
            paymentId,
            serviceCode,
            merchantSlug
        );
    }

    /**
    * @dev Processes a payment with permit and commission.
    * @param tokenAddress The address of the token being used for the payment.
    * @param amountPaid The amount paid for the service.
    * @param paymentId The unique identifier for the payment.
    * @param serviceCode The code of the service being paid.
    * @param merchantSlug The slug of the merchant.
    * @param permit The permit data for the transfer.
    * @param signature The signature for the permit.
    * @param commissionsAddress The address to send the commission to.
    * @param commissionAmount The amount of commission to be sent.
    */
    function processPaymentWithPermitAndCommission(
        address tokenAddress,
        uint160 amountPaid, // Solo el monto del servicio
        string memory paymentId,
        string memory serviceCode,
        string memory merchantSlug,
        IPermit2.PermitTransferFrom calldata permit, // Cambiado a calldata para eficiencia
        bytes calldata signature, // Cambiado a calldata para eficiencia
        address commissionsAddress, // Dirección para comisiones
        uint256 commissionAmount // Monto de comisión
    ) external nonReentrant {
        require(amountPaid > 0, "No amount specified");
        require(permit.deadline > block.timestamp, "Permit expired");
        require(commissionsAddress != address(0), "Invalid commission address");
        require(
            commissionAmount > 0,
            "Commission amount must be greater than 0"
        );
        require(commissionAmount <= permit.permitted.amount - amountPaid, "Commission amount exceeds available amount");
        
        if (tokenAddress == address(0)) revert PermitNotForETH();
        if (!allowedTokens[tokenAddress]) revert UnsupportedToken(tokenAddress);
        require(
            permit.permitted.token == tokenAddress,
            "Permit token mismatch"
        );

        // Validate that the permit amount is sufficient for service + commission
        if (permit.permitted.amount < amountPaid + commissionAmount)
            revert InsufficientPermitAmount();

        permit2.permitTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({
                to: address(this),
                requestedAmount: permit.permitted.amount // Total amount
            }),
            msg.sender,
            signature
        );

        // Send commission to the specified address
        IERC20(tokenAddress).safeTransfer(commissionsAddress, commissionAmount);

        // Emit events
        emit PaymentProcessed(
            msg.sender,
            amountPaid,
            tokenAddress,
            paymentId,
            serviceCode,
            merchantSlug
        );
        emit CommissionPaid(
            commissionsAddress,
            commissionAmount,
            tokenAddress,
            paymentId
        );
    }

    function withdraw(address[] memory tokenAddresses)
        external
        onlyOwner
        nonReentrant
    {
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            address tokenAddr = tokenAddresses[i];
            if (tokenAddr == address(0)) {
                // Withdraw ETH
                uint256 ethBalance = address(this).balance;
                if (ethBalance > 0) {
                    (bool success, ) = payable(owner()).call{value: ethBalance}(
                        ""
                    );
                    if (!success) revert TransferFailed();
                }
            } else {
                // Withdraw ERC20 tokens
                uint256 tokenBalance = IERC20(tokenAddr).balanceOf(
                    address(this)
                );
                if (tokenBalance > 0) {
                    IERC20(tokenAddr).safeTransfer(owner(), tokenBalance);
                }
            }
        }
    }

    function getContractBalances(address[] memory tokenAddresses)
        external
        view
        returns (uint256[] memory balances)
    {
        balances = new uint256[](tokenAddresses.length);
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            if (tokenAddresses[i] == address(0)) {
                balances[i] = address(this).balance;
            } else {
                balances[i] = IERC20(tokenAddresses[i]).balanceOf(
                    address(this)
                );
            }
        }
        return balances;
    }
}
