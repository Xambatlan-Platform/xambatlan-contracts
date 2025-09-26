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

// Interface para Morpho Blue (protocolo de lending directo)
interface IMorpho {
    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }
    
    function supply(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256);
    
    function withdraw(
        MarketParams calldata marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256);
    
    function position(bytes32 id, address user) external view returns (
        uint256 supplyShares,
        uint128 borrowShares,
        uint128 collateral
    );
    
    function market(bytes32 id) external view returns (
        uint128 totalSupplyAssets,
        uint128 totalSupplyShares,
        uint128 totalBorrowAssets,
        uint128 totalBorrowShares,
        uint128 lastUpdate,
        uint128 fee
    );
}

contract EscrowWithLending is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    IPermit2 public immutable permit2;
    IMorpho public immutable morpho;
    
    // Configuración de distribución
    uint256 public constant VENDOR_PERCENTAGE = 20; // 20%
    uint256 public constant LENDING_PERCENTAGE = 80; // 80%
    
    // Estados del escrow
    enum EscrowStatus {
        Pending,        // Pago realizado, esperando confirmación
        Confirmed,      // Servicio confirmado, fondos liberados
        Disputed,       // En disputa
        Cancelled       // Cancelado
    }
    
    struct EscrowData {
        address buyer;
        address vendor;
        address token;
        uint256 totalAmount;
        uint256 vendorAmount;
        uint256 lendingAmount;
        EscrowStatus status;
        uint256 createdAt;
        uint256 confirmedAt;
        string serviceId;
        uint256 supplyShares; // Cantidad de shares de supply en Morpho
        bytes32 marketId; // ID del mercado en Morpho
    }
    
    mapping(bytes32 => EscrowData) public escrows;
    mapping(address => bool) public allowedTokens;
    mapping(address => IMorpho.MarketParams) public tokenToMarket; // Mapeo token -> MarketParams
    
    // Eventos
    event EscrowCreated(
        bytes32 indexed escrowId,
        address indexed buyer,
        address indexed vendor,
        address token,
        uint256 totalAmount,
        string serviceId
    );
    
    event ServiceConfirmed(
        bytes32 indexed escrowId,
        address indexed vendor,
        uint256 vendorAmount,
        uint256 lendingAmount
    );
    
    event FundsReleased(
        bytes32 indexed escrowId,
        address indexed vendor,
        uint256 amount
    );
    
    event LendingYieldClaimed(
        bytes32 indexed escrowId,
        address indexed platform,
        uint256 yieldAmount
    );
    
    event DisputeInitiated(
        bytes32 indexed escrowId,
        address indexed initiator
    );
    
    error UnsupportedToken(address tokenAddress);
    error InvalidEscrow(bytes32 escrowId);
    error UnauthorizedAccess();
    error EscrowNotInPendingStatus();
    error InsufficientPermitAmount();
    error TransferFailed();
    
    constructor(
        address initialOwner,
        address permit2_address,
        address morpho_address
    ) Ownable(initialOwner) {
        permit2 = IPermit2(permit2_address);
        morpho = IMorpho(morpho_address);
    }
    
    /**
     * @dev Permite al owner agregar un token y configurar su mercado en Morpho
     */
    function allowToken(
        address tokenAddress, 
        IMorpho.MarketParams calldata marketParams
    ) external onlyOwner {
        allowedTokens[tokenAddress] = true;
        tokenToMarket[tokenAddress] = marketParams;
    }
    
    /**
     * @dev Crea un escrow con Permit2 y distribuye los fondos
     */
    function createEscrowWithPermit(
        address vendor,
        address tokenAddress,
        uint256 totalAmount,
        string memory serviceId,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant returns (bytes32) {
        require(vendor != address(0), "Invalid vendor address");
        require(totalAmount > 0, "Invalid amount");
        require(permit.deadline > block.timestamp, "Permit expired");
        
        if (!allowedTokens[tokenAddress]) revert UnsupportedToken(tokenAddress);
        require(
            permit.permitted.token == tokenAddress,
            "Permit token mismatch"
        );
        require(
            permit.permitted.amount >= totalAmount,
            "Insufficient permit amount"
        );
        
        // Generar ID único del escrow
        bytes32 escrowId = keccak256(
            abi.encodePacked(
                msg.sender,
                vendor,
                tokenAddress,
                totalAmount,
                serviceId,
                block.timestamp
            )
        );
        
        // Calcular distribución
        uint256 vendorAmount = (totalAmount * VENDOR_PERCENTAGE) / 100;
        uint256 lendingAmount = (totalAmount * LENDING_PERCENTAGE) / 100;
        
        // Transferir tokens usando Permit2
        permit2.permitTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({
                to: address(this),
                requestedAmount: totalAmount
            }),
            msg.sender,
            signature
        );
        
        // Enviar 20% al vendedor inmediatamente
        IERC20(tokenAddress).safeTransfer(vendor, vendorAmount);
        
        // Depositar 80% en Morpho Blue
        IMorpho.MarketParams memory marketParams = tokenToMarket[tokenAddress];
        require(marketParams.loanToken != address(0), "Market not configured");
        
        IERC20(tokenAddress).approve(address(morpho), lendingAmount);
        (uint256 assetsSupplied, uint256 shares) = morpho.supply(
            marketParams,
            lendingAmount,
            0, // shares = 0 para depositar assets exactos
            address(this),
            ""
        );
        
        // Guardar datos del escrow
        escrows[escrowId] = EscrowData({
            buyer: msg.sender,
            vendor: vendor,
            token: tokenAddress,
            totalAmount: totalAmount,
            vendorAmount: vendorAmount,
            lendingAmount: lendingAmount,
            status: EscrowStatus.Pending,
            createdAt: block.timestamp,
            confirmedAt: 0,
            serviceId: serviceId,
            supplyShares: shares,
            marketId: keccak256(abi.encode(marketParams))
        });
        
        emit EscrowCreated(escrowId, msg.sender, vendor, tokenAddress, totalAmount, serviceId);
        
        return escrowId;
    }
    
    /**
     * @dev Confirma la entrega del servicio y libera los fondos del lending
     */
    function confirmService(bytes32 escrowId) external nonReentrant {
        EscrowData storage escrow = escrows[escrowId];
        
        if (escrow.buyer == address(0)) revert InvalidEscrow(escrowId);
        if (escrow.status != EscrowStatus.Pending) revert EscrowNotInPendingStatus();
        if (msg.sender != escrow.buyer) revert UnauthorizedAccess();
        
        // Retirar fondos de Morpho Blue
        IMorpho.MarketParams memory marketParams = tokenToMarket[escrow.token];
        (uint256 assetsWithdrawn, uint256 sharesWithdrawn) = morpho.withdraw(
            marketParams,
            escrow.lendingAmount,
            escrow.supplyShares,
            address(this),
            address(this)
        );
        
        // Calcular rendimiento generado
        uint256 yield = assetsWithdrawn - escrow.lendingAmount;
        
        // Enviar solo el monto principal al vendedor (sin rendimiento)
        IERC20(escrow.token).safeTransfer(escrow.vendor, escrow.lendingAmount);
        
        // Enviar TODO el rendimiento generado a la plataforma
        if (yield > 0) {
            IERC20(escrow.token).safeTransfer(owner(), yield);
            emit LendingYieldClaimed(escrowId, owner(), yield);
        }
        
        // Actualizar estado del escrow
        escrow.status = EscrowStatus.Confirmed;
        escrow.confirmedAt = block.timestamp;
        
        emit ServiceConfirmed(escrowId, escrow.vendor, escrow.lendingAmount, escrow.lendingAmount);
        emit FundsReleased(escrowId, escrow.vendor, escrow.lendingAmount);
    }
    
    /**
     * @dev Inicia una disputa (solo el comprador o vendedor)
     */
    function initiateDispute(bytes32 escrowId) external {
        EscrowData storage escrow = escrows[escrowId];
        
        if (escrow.buyer == address(0)) revert InvalidEscrow(escrowId);
        if (escrow.status != EscrowStatus.Pending) revert EscrowNotInPendingStatus();
        if (msg.sender != escrow.buyer && msg.sender != escrow.vendor) {
            revert UnauthorizedAccess();
        }
        
        escrow.status = EscrowStatus.Disputed;
        emit DisputeInitiated(escrowId, msg.sender);
    }
    
    /**
     * @dev Resuelve disputa (solo owner)
     */
    function resolveDispute(
        bytes32 escrowId,
        bool favorVendor
    ) external onlyOwner nonReentrant {
        EscrowData storage escrow = escrows[escrowId];
        
        if (escrow.buyer == address(0)) revert InvalidEscrow(escrowId);
        if (escrow.status != EscrowStatus.Disputed) revert EscrowNotInPendingStatus();
        
        IMorpho.MarketParams memory marketParams = tokenToMarket[escrow.token];
        
        if (favorVendor) {
            // Liberar fondos al vendedor
            (uint256 assetsWithdrawn, ) = morpho.withdraw(
                marketParams,
                escrow.lendingAmount,
                escrow.supplyShares,
                address(this),
                address(this)
            );
            IERC20(escrow.token).safeTransfer(escrow.vendor, assetsWithdrawn);
            escrow.status = EscrowStatus.Confirmed;
        } else {
            // Devolver fondos al comprador
            (uint256 assetsWithdrawn, ) = morpho.withdraw(
                marketParams,
                escrow.lendingAmount,
                escrow.supplyShares,
                address(this),
                address(this)
            );
            IERC20(escrow.token).safeTransfer(escrow.buyer, assetsWithdrawn);
            escrow.status = EscrowStatus.Cancelled;
        }
        
        escrow.confirmedAt = block.timestamp;
    }
    
    /**
     * @dev Obtiene información del escrow
     */
    function getEscrow(bytes32 escrowId) external view returns (EscrowData memory) {
        return escrows[escrowId];
    }
    
    /**
     * @dev Calcula el rendimiento actual de Morpho Blue
     */
    function getCurrentYield(bytes32 escrowId) external view returns (uint256) {
        EscrowData memory escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) return 0;
        
        // Obtener la posición actual del usuario en Morpho
        (uint256 currentSupplyShares, , ) = morpho.position(escrow.marketId, address(this));
        
        // Obtener información del mercado para calcular el valor actual
        (, , , , , ) = morpho.market(escrow.marketId);
        
        // Calcular el valor actual basado en las shares
        // Nota: Esta es una aproximación, el valor exacto depende de la implementación de Morpho
        uint256 currentValue = (currentSupplyShares * escrow.lendingAmount) / escrow.supplyShares;
        
        if (currentValue > escrow.lendingAmount) {
            return currentValue - escrow.lendingAmount;
        }
        return 0;
    }
    
    /**
     * @dev Obtiene la posición actual en Morpho Blue
     */
    function getCurrentPosition(bytes32 escrowId) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral) {
        EscrowData memory escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) return (0, 0, 0);
        
        return morpho.position(escrow.marketId, address(this));
    }
}
