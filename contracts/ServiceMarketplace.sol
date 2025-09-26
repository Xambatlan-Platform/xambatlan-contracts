// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./UserRegistry.sol";
import "./EscrowWithLending.sol";

/**
 * @title ServiceMarketplace
 * @dev Marketplace principal que integra todos los componentes del sistema
 */
contract ServiceMarketplace is Ownable, ReentrancyGuard {
    
    // Referencias a contratos
    UserRegistry public immutable userRegistry;
    EscrowWithLending public immutable escrowWithLending;
    
    // Estados de órdenes
    enum OrderStatus {
        Open,           // Orden abierta para ofertas
        Bidding,        // Recibiendo ofertas
        Accepted,       // Oferta aceptada
        InProgress,     // Servicio en progreso
        Completed,      // Servicio completado
        Cancelled,      // Orden cancelada
        Disputed        // En disputa
    }
    
    // Estados de ofertas
    enum BidStatus {
        Pending,        // Oferta pendiente
        Accepted,       // Oferta aceptada
        Rejected,       // Oferta rechazada
        Withdrawn       // Oferta retirada
    }
    
    // Solo escrow para protección del usuario
    // enum PaymentType eliminado - solo usamos escrow
    
    // Estructura de orden de servicio
    struct ServiceOrder {
        bytes32 orderId;
        address creator;            // ServiceSeeker
        string title;
        string description;
        string category;            // "plomeria", "asesoria", etc.
        string location;
        uint256 maxBudget;
        uint256 deadline;
        OrderStatus status;
        bytes32 acceptedBidId;
        address tokenAddress;       // Token para el pago
        uint256 totalAmount;        // Monto total acordado
        bytes32 escrowId;           // ID del escrow
        uint256 createdAt;
        uint256 updatedAt;
    }
    
    // Estructura de oferta de servicio
    struct ServiceBid {
        bytes32 bidId;
        bytes32 orderId;
        address bidder;             // ServiceProvider
        uint256 proposedPrice;
        string proposal;
        uint256 estimatedDuration;  // en días
        BidStatus status;
        uint256 createdAt;
        uint256 updatedAt;
    }
    
    // Mapeos principales
    mapping(bytes32 => ServiceOrder) public serviceOrders;
    mapping(bytes32 => ServiceBid) public serviceBids;
    mapping(bytes32 => bytes32[]) public orderBids; // orderId => bidIds[]
    mapping(address => bytes32[]) public userOrders; // user => orderIds[]
    mapping(address => bytes32[]) public userBids; // user => bidIds[]
    
    // Configuración
    uint256 public platformFeePercentage = 5; // 5% por defecto
    address public feeRecipient;
    uint256 public minOrderValue = 1e6; // 1 USDC mínimo
    uint256 public maxOrderValue = 1000000e6; // 1M USDC máximo
    
    // Contadores
    uint256 public totalOrders;
    uint256 public totalBids;
    
    // Eventos
    event ServiceOrderCreated(
        bytes32 indexed orderId,
        address indexed creator,
        string title,
        string category,
        uint256 maxBudget
    );
    
    event ServiceBidSubmitted(
        bytes32 indexed bidId,
        bytes32 indexed orderId,
        address indexed bidder,
        uint256 proposedPrice,
        string proposal
    );
    
    event ServiceBidAccepted(
        bytes32 indexed bidId,
        bytes32 indexed orderId,
        address indexed bidder,
        uint256 finalPrice
    );
    
    event ServiceBidRejected(
        bytes32 indexed bidId,
        bytes32 indexed orderId,
        address indexed bidder
    );
    
    event ServiceBidWithdrawn(
        bytes32 indexed bidId,
        bytes32 indexed orderId,
        address indexed bidder
    );
    
    event PaymentInitiated(
        bytes32 indexed orderId,
        bytes32 indexed bidId,
        address tokenAddress,
        uint256 amount
    );
    
    event ServiceCompleted(
        bytes32 indexed orderId,
        bytes32 indexed bidId,
        address indexed serviceProvider,
        uint256 finalAmount
    );
    
    event ServiceDisputed(
        bytes32 indexed orderId,
        bytes32 indexed bidId,
        address indexed initiator
    );
    
    event ServiceCancelled(
        bytes32 indexed orderId,
        address indexed creator,
        string reason
    );
    
    event PlatformFeeUpdated(uint256 newFeePercentage);
    event FeeRecipientUpdated(address newRecipient);
    event OrderLimitsUpdated(uint256 minValue, uint256 maxValue);
    
    // Errores
    error UserNotRegistered(address user);
    error UserNotActive(address user);
    error InvalidUserType();
    error OrderNotFound(bytes32 orderId);
    error BidNotFound(bytes32 bidId);
    error OrderNotOpen(bytes32 orderId);
    error OrderNotAccepted(bytes32 orderId);
    error OrderNotInProgress(bytes32 orderId);
    error BidNotPending(bytes32 bidId);
    error BidNotAccepted(bytes32 bidId);
    error UnauthorizedAccess();
    error InvalidAmount(uint256 amount);
    error InvalidDeadline(uint256 deadline);
    error InvalidCategory(string category);
    error PaymentAlreadyInitiated(bytes32 orderId);
    error ServiceNotCompleted(bytes32 orderId);
    // error InvalidPaymentType(); // Eliminado - solo usamos escrow
    
    constructor(
        address initialOwner,
        address userRegistryAddress,
        address escrowWithLendingAddress
    ) Ownable(initialOwner) {
        userRegistry = UserRegistry(userRegistryAddress);
        escrowWithLending = EscrowWithLending(escrowWithLendingAddress);
        feeRecipient = initialOwner;
    }
    
    /**
     * @dev Crea una nueva orden de servicio
     */
    function createServiceOrder(
        string memory title,
        string memory description,
        string memory category,
        string memory location,
        uint256 maxBudget,
        uint256 deadline,
        address tokenAddress
    ) external nonReentrant returns (bytes32) {
        // Validaciones de usuario
        _validateServiceSeeker(msg.sender);
        
        // Validaciones de parámetros
        if (maxBudget < minOrderValue || maxBudget > maxOrderValue) {
            revert InvalidAmount(maxBudget);
        }
        if (deadline <= block.timestamp) {
            revert InvalidDeadline(deadline);
        }
        if (bytes(category).length == 0) {
            revert InvalidCategory(category);
        }
        
        // Generar ID único
        bytes32 orderId = keccak256(
            abi.encodePacked(
                msg.sender,
                title,
                description,
                block.timestamp,
                totalOrders
            )
        );
        
        // Crear orden
        ServiceOrder memory order = ServiceOrder({
            orderId: orderId,
            creator: msg.sender,
            title: title,
            description: description,
            category: category,
            location: location,
            maxBudget: maxBudget,
            deadline: deadline,
            status: OrderStatus.Open,
            acceptedBidId: bytes32(0),
            tokenAddress: tokenAddress,
            totalAmount: 0,
            escrowId: bytes32(0),
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });
        
        // Guardar orden
        serviceOrders[orderId] = order;
        userOrders[msg.sender].push(orderId);
        totalOrders++;
        
        emit ServiceOrderCreated(
            orderId,
            msg.sender,
            title,
            category,
            maxBudget
        );
        
        return orderId;
    }
    
    /**
     * @dev Envía una oferta para una orden
     */
    function submitBid(
        bytes32 orderId,
        uint256 proposedPrice,
        string memory proposal,
        uint256 estimatedDuration
    ) external nonReentrant returns (bytes32) {
        // Validaciones de usuario
        _validateServiceProvider(msg.sender);
        
        // Validaciones de orden
        ServiceOrder storage order = serviceOrders[orderId];
        if (order.creator == address(0)) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.Open) revert OrderNotOpen(orderId);
        if (proposedPrice > order.maxBudget) revert InvalidAmount(proposedPrice);
        if (proposedPrice < minOrderValue) revert InvalidAmount(proposedPrice);
        
        // Generar ID único para la oferta
        bytes32 bidId = keccak256(
            abi.encodePacked(
                orderId,
                msg.sender,
                proposedPrice,
                block.timestamp,
                totalBids
            )
        );
        
        // Crear oferta
        ServiceBid memory bid = ServiceBid({
            bidId: bidId,
            orderId: orderId,
            bidder: msg.sender,
            proposedPrice: proposedPrice,
            proposal: proposal,
            estimatedDuration: estimatedDuration,
            status: BidStatus.Pending,
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });
        
        // Guardar oferta
        serviceBids[bidId] = bid;
        orderBids[orderId].push(bidId);
        userBids[msg.sender].push(bidId);
        totalBids++;
        
        // Actualizar estado de la orden
        order.status = OrderStatus.Bidding;
        order.updatedAt = block.timestamp;
        
        emit ServiceBidSubmitted(bidId, orderId, msg.sender, proposedPrice, proposal);
        
        return bidId;
    }
    
    /**
     * @dev Acepta una oferta
     */
    function acceptBid(bytes32 bidId) external nonReentrant {
        ServiceBid storage bid = serviceBids[bidId];
        ServiceOrder storage order = serviceOrders[bid.orderId];
        
        // Validaciones
        if (bid.bidder == address(0)) revert BidNotFound(bidId);
        if (order.creator != msg.sender) revert UnauthorizedAccess();
        if (bid.status != BidStatus.Pending) revert BidNotPending(bidId);
        if (order.status != OrderStatus.Bidding) revert OrderNotOpen(bid.orderId);
        
        // Actualizar oferta
        bid.status = BidStatus.Accepted;
        bid.updatedAt = block.timestamp;
        
        // Actualizar orden
        order.status = OrderStatus.Accepted;
        order.acceptedBidId = bidId;
        order.totalAmount = bid.proposedPrice;
        order.updatedAt = block.timestamp;
        
        emit ServiceBidAccepted(bidId, bid.orderId, bid.bidder, bid.proposedPrice);
    }
    
    /**
     * @dev Rechaza una oferta
     */
    function rejectBid(bytes32 bidId) external nonReentrant {
        ServiceBid storage bid = serviceBids[bidId];
        ServiceOrder storage order = serviceOrders[bid.orderId];
        
        // Validaciones
        if (bid.bidder == address(0)) revert BidNotFound(bidId);
        if (order.creator != msg.sender) revert UnauthorizedAccess();
        if (bid.status != BidStatus.Pending) revert BidNotPending(bidId);
        
        // Actualizar oferta
        bid.status = BidStatus.Rejected;
        bid.updatedAt = block.timestamp;
        
        emit ServiceBidRejected(bidId, bid.orderId, bid.bidder);
    }
    
    /**
     * @dev Retira una oferta
     */
    function withdrawBid(bytes32 bidId) external nonReentrant {
        ServiceBid storage bid = serviceBids[bidId];
        
        // Validaciones
        if (bid.bidder == address(0)) revert BidNotFound(bidId);
        if (bid.bidder != msg.sender) revert UnauthorizedAccess();
        if (bid.status != BidStatus.Pending) revert BidNotPending(bidId);
        
        // Actualizar oferta
        bid.status = BidStatus.Withdrawn;
        bid.updatedAt = block.timestamp;
        
        emit ServiceBidWithdrawn(bidId, bid.orderId, bid.bidder);
    }
    
    /**
     * @dev Inicia el pago con escrow para una orden aceptada
     */
    function initiatePayment(
        bytes32 orderId,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external nonReentrant returns (bytes32) {
        ServiceOrder storage order = serviceOrders[orderId];
        ServiceBid storage bid = serviceBids[order.acceptedBidId];
        
        // Validaciones
        if (order.creator == address(0)) revert OrderNotFound(orderId);
        if (order.creator != msg.sender) revert UnauthorizedAccess();
        if (order.status != OrderStatus.Accepted) revert OrderNotAccepted(orderId);
        if (order.totalAmount == 0) revert PaymentAlreadyInitiated(orderId);
        
        // Crear escrow (único método de pago)
        bytes32 escrowId = escrowWithLending.createEscrowWithPermit(
            bid.bidder,
            order.tokenAddress,
            order.totalAmount,
            string(abi.encodePacked("ORDER_", orderId)),
            permit,
            signature
        );
        
        // Actualizar orden
        order.escrowId = escrowId;
        order.status = OrderStatus.InProgress;
        order.updatedAt = block.timestamp;
        
        emit PaymentInitiated(
            orderId,
            order.acceptedBidId,
            order.tokenAddress,
            order.totalAmount
        );
        
        return escrowId;
    }
    
    /**
     * @dev Marca un servicio como completado
     */
    function completeService(bytes32 orderId) external nonReentrant {
        ServiceOrder storage order = serviceOrders[orderId];
        ServiceBid storage bid = serviceBids[order.acceptedBidId];
        
        // Validaciones
        if (order.creator == address(0)) revert OrderNotFound(orderId);
        if (bid.bidder != msg.sender) revert UnauthorizedAccess();
        if (order.status != OrderStatus.InProgress) revert OrderNotInProgress(orderId);
        
        // Confirmar escrow (único método de pago)
        escrowWithLending.confirmService(order.escrowId);
        
        // Actualizar estado
        order.status = OrderStatus.Completed;
        order.updatedAt = block.timestamp;
        
        // Actualizar rating del ServiceProvider
        userRegistry.updateRating(bid.bidder, 95, order.totalAmount); // 95/100 por defecto
        
        emit ServiceCompleted(orderId, order.acceptedBidId, bid.bidder, order.totalAmount);
    }
    
    /**
     * @dev Inicia una disputa
     */
    function initiateDispute(bytes32 orderId) external nonReentrant {
        ServiceOrder storage order = serviceOrders[orderId];
        
        // Validaciones
        if (order.creator == address(0)) revert OrderNotFound(orderId);
        if (order.creator != msg.sender && serviceBids[order.acceptedBidId].bidder != msg.sender) {
            revert UnauthorizedAccess();
        }
        if (order.status != OrderStatus.InProgress) revert OrderNotInProgress(orderId);
        
        // Actualizar estado
        order.status = OrderStatus.Disputed;
        order.updatedAt = block.timestamp;
        
        // Iniciar disputa en escrow (único método de pago)
        escrowWithLending.initiateDispute(order.escrowId);
        
        emit ServiceDisputed(orderId, order.acceptedBidId, msg.sender);
    }
    
    /**
     * @dev Cancela una orden
     */
    function cancelOrder(bytes32 orderId, string memory reason) external nonReentrant {
        ServiceOrder storage order = serviceOrders[orderId];
        
        // Validaciones
        if (order.creator == address(0)) revert OrderNotFound(orderId);
        if (order.creator != msg.sender) revert UnauthorizedAccess();
        if (order.status == OrderStatus.Completed || order.status == OrderStatus.Cancelled) {
            revert OrderNotOpen(orderId);
        }
        
        // Actualizar estado
        order.status = OrderStatus.Cancelled;
        order.updatedAt = block.timestamp;
        
        emit ServiceCancelled(orderId, msg.sender, reason);
    }
    
    /**
     * @dev Funciones de consulta
     */
    function getServiceOrder(bytes32 orderId) external view returns (ServiceOrder memory) {
        return serviceOrders[orderId];
    }
    
    function getServiceBid(bytes32 bidId) external view returns (ServiceBid memory) {
        return serviceBids[bidId];
    }
    
    function getOrderBids(bytes32 orderId) external view returns (bytes32[] memory) {
        return orderBids[orderId];
    }
    
    function getUserOrders(address user) external view returns (bytes32[] memory) {
        return userOrders[user];
    }
    
    function getUserBids(address user) external view returns (bytes32[] memory) {
        return userBids[user];
    }
    
    /**
     * @dev Funciones de administración
     */
    function setPlatformFee(uint256 newFeePercentage) external onlyOwner {
        require(newFeePercentage <= 20, "Fee too high"); // Máximo 20%
        platformFeePercentage = newFeePercentage;
        emit PlatformFeeUpdated(newFeePercentage);
    }
    
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }
    
    function setOrderLimits(uint256 minValue, uint256 maxValue) external onlyOwner {
        require(minValue < maxValue, "Invalid limits");
        minOrderValue = minValue;
        maxOrderValue = maxValue;
        emit OrderLimitsUpdated(minValue, maxValue);
    }
    
    /**
     * @dev Funciones internas
     */
    function _validateServiceSeeker(address user) internal view {
        if (!userRegistry.isRegistered(user)) revert UserNotRegistered(user);
        if (!userRegistry.isUserActiveAndVerified(user)) revert UserNotActive(user);
        
        UserRegistry.UserProfile memory profile = userRegistry.getUserProfile(user);
        if (profile.userType != UserRegistry.UserType.ServiceSeeker) {
            revert InvalidUserType();
        }
    }
    
    function _validateServiceProvider(address user) internal view {
        if (!userRegistry.isRegistered(user)) revert UserNotRegistered(user);
        if (!userRegistry.isUserActiveAndVerified(user)) revert UserNotActive(user);
        
        UserRegistry.UserProfile memory profile = userRegistry.getUserProfile(user);
        if (profile.userType != UserRegistry.UserType.ServiceProvider) {
            revert InvalidUserType();
        }
    }
}
