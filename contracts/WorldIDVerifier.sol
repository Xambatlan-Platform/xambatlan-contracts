// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title WorldIDVerifier
 * @dev Contrato para verificación de World ID de usuarios
 * @notice Mantiene la lógica de verificación separada para fácil mantenimiento
 */
contract WorldIDVerifier is Ownable, ReentrancyGuard {
    
    // Estados de verificación
    enum VerificationStatus {
        NotVerified,    // Usuario no verificado
        Pending,        // Verificación en proceso
        Verified,       // Usuario verificado
        Revoked         // Verificación revocada
    }
    
    struct UserVerification {
        address userAddress;
        string worldIdHash;        // Hash del World ID (para privacidad)
        VerificationStatus status;
        uint256 verifiedAt;
        uint256 expiresAt;         // Opcional: fecha de expiración
        string metadata;           // Metadatos adicionales (opcional)
    }
    
    // Mapeos
    mapping(address => UserVerification) public userVerifications;
    mapping(string => address) public worldIdToAddress; // worldIdHash => address
    mapping(address => bool) public isVerified;
    
    // Configuración
    uint256 public verificationExpiry = 365 days; // 1 año por defecto
    bool public allowExpiredVerifications = true;
    
    // Eventos
    event UserVerified(
        address indexed user,
        string indexed worldIdHash,
        uint256 verifiedAt,
        uint256 expiresAt
    );
    
    event VerificationRevoked(
        address indexed user,
        string indexed worldIdHash,
        uint256 revokedAt
    );
    
    event VerificationExpired(
        address indexed user,
        string indexed worldIdHash,
        uint256 expiredAt
    );
    
    event VerificationExpiryUpdated(uint256 newExpiry);
    event ExpiredVerificationsToggled(bool allowed);
    
    // Errores
    error UserAlreadyVerified(address user);
    error UserNotVerified(address user);
    error WorldIdAlreadyUsed(string worldIdHash);
    error UserVerificationExpired(address user);
    error InvalidWorldIdHash(string worldIdHash);
    error UnauthorizedAccess();
    
    constructor(address initialOwner) Ownable(initialOwner) {}
    
    /**
     * @dev Verifica un usuario con World ID
     * @param user Dirección del usuario a verificar
     * @param worldIdHash Hash del World ID del usuario
     * @param metadata Metadatos adicionales (opcional)
     */
    function verifyUser(
        address user,
        string memory worldIdHash,
        string memory metadata
    ) public onlyOwner nonReentrant {
        // Validaciones
        if (bytes(worldIdHash).length == 0) revert InvalidWorldIdHash(worldIdHash);
        if (isVerified[user]) revert UserAlreadyVerified(user);
        if (worldIdToAddress[worldIdHash] != address(0)) {
            revert WorldIdAlreadyUsed(worldIdHash);
        }
        
        // Calcular fechas
        uint256 verifiedAt = block.timestamp;
        uint256 expiresAt = verifiedAt + verificationExpiry;
        
        // Crear verificación
        UserVerification memory verification = UserVerification({
            userAddress: user,
            worldIdHash: worldIdHash,
            status: VerificationStatus.Verified,
            verifiedAt: verifiedAt,
            expiresAt: expiresAt,
            metadata: metadata
        });
        
        // Actualizar mapeos
        userVerifications[user] = verification;
        worldIdToAddress[worldIdHash] = user;
        isVerified[user] = true;
        
        emit UserVerified(user, worldIdHash, verifiedAt, expiresAt);
    }
    
    /**
     * @dev Verifica múltiples usuarios en lote (para eficiencia)
     */
    function verifyUsersBatch(
        address[] calldata users,
        string[] calldata worldIdHashes,
        string[] calldata metadata
    ) external onlyOwner nonReentrant {
        require(
            users.length == worldIdHashes.length && 
            users.length == metadata.length,
            "Arrays length mismatch"
        );
        
        for (uint256 i = 0; i < users.length; i++) {
            verifyUser(users[i], worldIdHashes[i], metadata[i]);
        }
    }
    
    /**
     * @dev Revoca la verificación de un usuario
     */
    function revokeVerification(address user) external onlyOwner {
        UserVerification storage verification = userVerifications[user];
        
        if (verification.status != VerificationStatus.Verified) {
            revert UserNotVerified(user);
        }
        
        // Actualizar estado
        verification.status = VerificationStatus.Revoked;
        isVerified[user] = false;
        
        emit VerificationRevoked(user, verification.worldIdHash, block.timestamp);
    }
    
    /**
     * @dev Verifica si un usuario está verificado y no ha expirado
     */
    function isUserVerified(address user) external view returns (bool) {
        UserVerification memory verification = userVerifications[user];
        
        if (verification.status != VerificationStatus.Verified) {
            return false;
        }
        
        // Verificar expiración
        if (block.timestamp > verification.expiresAt) {
            if (!allowExpiredVerifications) {
                return false;
            }
        }
        
        return true;
    }
    
    /**
     * @dev Obtiene información completa de verificación de un usuario
     */
    function getUserVerification(address user) 
        external 
        view 
        returns (UserVerification memory) 
    {
        return userVerifications[user];
    }
    
    /**
     * @dev Verifica si una dirección está asociada a un World ID específico
     */
    function isWorldIdVerified(string memory worldIdHash) 
        external 
        view 
        returns (bool) 
    {
        address user = worldIdToAddress[worldIdHash];
        if (user == address(0)) return false;
        
        return this.isUserVerified(user);
    }
    
    /**
     * @dev Obtiene la dirección asociada a un World ID
     */
    function getAddressByWorldId(string memory worldIdHash) 
        external 
        view 
        returns (address) 
    {
        return worldIdToAddress[worldIdHash];
    }
    
    /**
     * @dev Actualiza el tiempo de expiración de las verificaciones
     */
    function setVerificationExpiry(uint256 newExpiry) external onlyOwner {
        verificationExpiry = newExpiry;
        emit VerificationExpiryUpdated(newExpiry);
    }
    
    /**
     * @dev Permite o no el uso de verificaciones expiradas true by default
     */
    function setAllowExpiredVerifications(bool allowed) external onlyOwner {
        allowExpiredVerifications = allowed;
        emit ExpiredVerificationsToggled(allowed);
    }
    
}
