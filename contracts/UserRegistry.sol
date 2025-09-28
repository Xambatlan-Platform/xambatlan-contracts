// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./WorldIDVerifier.sol";

/**
 * @title UserRegistry
 * @dev Registro de usuarios del marketplace con verificación de World ID
 */
contract UserRegistry is Ownable, ReentrancyGuard {
    
    // Tipos de usuario
    enum UserType { 
        ServiceSeeker,  // Usuario que busca servicios
        ServiceProvider // Usuario que ofrece servicios
    }
    
    // Estados del usuario
    enum UserStatus {
        Inactive,       // Usuario inactivo
        Active,         // Usuario activo
        Suspended,      // Usuario suspendido
        Banned          // Usuario baneado
    }
    
    struct UserProfile {
        address userAddress;
        UserType userType;
        UserStatus status;
        string name;
        string description;
        string[] skills;           // Solo para ServiceProviders
        string location;           // Ubicación del usuario
        uint256 rating;           // Rating promedio (0-100)
        uint256 totalJobs;        // Total de trabajos completados
        uint256 totalEarnings;    // Total ganado (para ServiceProviders)
        bool isVerified;          // Verificado con World ID
        uint256 createdAt;
        uint256 lastActiveAt;
        string profileImageHash;  // Hash de la imagen de perfil
        string[] certifications;  // Certificaciones (opcional)
    }
    
    // Mapeos
    mapping(address => UserProfile) public userProfiles;
    mapping(UserType => address[]) public usersByType;
    mapping(string => address) public nameToAddress; // Para evitar nombres duplicados
    mapping(address => bool) public isRegistered;
    
    // Referencia al verificador de World ID
    WorldIDVerifier public immutable worldIdVerifier;
    
    // Configuración
    uint256 public registrationFee = 0; // Fee de registro (puede ser 0)
    address public feeRecipient;
    
    // Eventos
    event UserRegistered(
        address indexed user,
        UserType userType,
        string name,
        bool isVerified
    );
    
    event UserProfileUpdated(
        address indexed user,
        string name,
        string description
    );
    
    event UserStatusChanged(
        address indexed user,
        UserStatus oldStatus,
        UserStatus newStatus
    );
    
    event UserRatingUpdated(
        address indexed user,
        uint256 newRating,
        uint256 totalJobs
    );
    
    event RegistrationFeeUpdated(uint256 newFee);
    event FeeRecipientUpdated(address newRecipient);
    
    // Errores
    error UserAlreadyRegistered(address user);
    error UserNotRegistered(address user);
    error UserNotVerified(address user);
    error UserSuspended(address user);
    error UserBanned(address user);
    error InvalidUserType();
    error InvalidName(string name);
    error NameAlreadyTaken(string name);
    error InvalidRating(uint256 rating);
    error UnauthorizedAccess();
    error WorldIdNotVerified(address user);
    
    constructor(
        address initialOwner,
        address worldIdVerifierAddress
    ) Ownable(initialOwner) {
        worldIdVerifier = WorldIDVerifier(worldIdVerifierAddress);
        feeRecipient = initialOwner;
    }
    
    /**
     * @dev Registra un ServiceSeeker
     */
    function registerServiceSeeker(
        string memory name,
        string memory description,
        string memory location,
        string memory profileImageHash
    ) external payable nonReentrant {
        // Validaciones básicas
        _validateRegistration(msg.sender, name);
        
        // Verificar World ID
        bool isWorldIdVerified = worldIdVerifier.isUserVerified(msg.sender);
        if (!isWorldIdVerified) revert WorldIdNotVerified(msg.sender);
        
        // Procesar fee de registro
        _processRegistrationFee();
        
        // Crear perfil
        UserProfile memory profile = UserProfile({
            userAddress: msg.sender,
            userType: UserType.ServiceSeeker,
            status: UserStatus.Active,
            name: name,
            description: description,
            skills: new string[](0), // ServiceSeekers no tienen skills
            location: location,
            rating: 0,
            totalJobs: 0,
            totalEarnings: 0,
            isVerified: true, // Verificado por World ID
            createdAt: block.timestamp,
            lastActiveAt: block.timestamp,
            profileImageHash: profileImageHash,
            certifications: new string[](0)
        });
        
        // Guardar perfil
        userProfiles[msg.sender] = profile;
        usersByType[UserType.ServiceSeeker].push(msg.sender);
        nameToAddress[name] = msg.sender;
        isRegistered[msg.sender] = true;
        
        emit UserRegistered(msg.sender, UserType.ServiceSeeker, name, true);
    }
    
    /**
     * @dev Registra un ServiceProvider
     */
    function registerServiceProvider(
        string memory name,
        string memory description,
        string memory location,
        string[] memory skills,
        string memory profileImageHash,
        string[] memory certifications
    ) external payable nonReentrant {
        // Validaciones básicas
        _validateRegistration(msg.sender, name);
        
        // Verificar World ID
        bool isWorldIdVerified = worldIdVerifier.isUserVerified(msg.sender);
        if (!isWorldIdVerified) revert WorldIdNotVerified(msg.sender);
        
        // Procesar fee de registro
        _processRegistrationFee();
        
        // Crear perfil
        UserProfile memory profile = UserProfile({
            userAddress: msg.sender,
            userType: UserType.ServiceProvider,
            status: UserStatus.Active,
            name: name,
            description: description,
            skills: skills,
            location: location,
            rating: 0,
            totalJobs: 0,
            totalEarnings: 0,
            isVerified: true, // Verificado por World ID
            createdAt: block.timestamp,
            lastActiveAt: block.timestamp,
            profileImageHash: profileImageHash,
            certifications: certifications
        });
        
        // Guardar perfil
        userProfiles[msg.sender] = profile;
        usersByType[UserType.ServiceProvider].push(msg.sender);
        nameToAddress[name] = msg.sender;
        isRegistered[msg.sender] = true;
        
        emit UserRegistered(msg.sender, UserType.ServiceProvider, name, true);
    }
    
    /**
     * @dev Actualiza el perfil del usuario
     */
    function updateProfile(
        string memory newName,
        string memory newDescription,
        string memory newLocation,
        string memory newProfileImageHash
    ) external nonReentrant {
        UserProfile storage profile = userProfiles[msg.sender];
        
        if (!isRegistered[msg.sender]) revert UserNotRegistered(msg.sender);
        if (profile.status == UserStatus.Suspended) revert UserSuspended(msg.sender);
        if (profile.status == UserStatus.Banned) revert UserBanned(msg.sender);
        
        // Verificar que el nuevo nombre no esté tomado
        if (keccak256(bytes(profile.name)) != keccak256(bytes(newName))) {
            if (nameToAddress[newName] != address(0)) {
                revert NameAlreadyTaken(newName);
            }
            
            // Actualizar mapeo de nombres
            delete nameToAddress[profile.name];
            nameToAddress[newName] = msg.sender;
        }
        
        // Actualizar perfil
        profile.name = newName;
        profile.description = newDescription;
        profile.location = newLocation;
        profile.profileImageHash = newProfileImageHash;
        profile.lastActiveAt = block.timestamp;
        
        emit UserProfileUpdated(msg.sender, newName, newDescription);
    }
    
    /**
     * @dev Actualiza las skills de un ServiceProvider
     */
    function updateSkills(string[] memory newSkills) external {
        UserProfile storage profile = userProfiles[msg.sender];
        
        if (!isRegistered[msg.sender]) revert UserNotRegistered(msg.sender);
        if (profile.userType != UserType.ServiceProvider) revert InvalidUserType();
        if (profile.status == UserStatus.Suspended) revert UserSuspended(msg.sender);
        if (profile.status == UserStatus.Banned) revert UserBanned(msg.sender);
        
        profile.skills = newSkills;
        profile.lastActiveAt = block.timestamp;
        
        emit UserProfileUpdated(msg.sender, profile.name, profile.description);
    }
    
    /**
     * @dev Actualiza el rating de un usuario (solo puede ser llamado por contratos autorizados)
     */
    function updateRating(
        address user,
        uint256 newRating,
        uint256 jobValue
    ) external onlyOwner {
        UserProfile storage profile = userProfiles[user];
        
        if (!isRegistered[user]) revert UserNotRegistered(user);
        
        // Validar rating (0-100)
        if (newRating > 100) revert InvalidRating(newRating);
        
        // Actualizar rating promedio
        uint256 totalRating = profile.rating * profile.totalJobs;
        profile.totalJobs += 1;
        profile.rating = (totalRating + newRating) / profile.totalJobs;
        
        // Actualizar earnings para ServiceProviders
        if (profile.userType == UserType.ServiceProvider) {
            profile.totalEarnings += jobValue;
        }
        
        profile.lastActiveAt = block.timestamp;
        
        emit UserRatingUpdated(user, profile.rating, profile.totalJobs);
    }
    
    /**
     * @dev Cambia el estado de un usuario (solo owner)
     */
    function changeUserStatus(address user, UserStatus newStatus) external onlyOwner {
        UserProfile storage profile = userProfiles[user];
        
        if (!isRegistered[user]) revert UserNotRegistered(user);
        
        UserStatus oldStatus = profile.status;
        profile.status = newStatus;
        profile.lastActiveAt = block.timestamp;
        
        emit UserStatusChanged(user, oldStatus, newStatus);
    }
    
    /**
     * @dev Obtiene el perfil completo de un usuario
     */
    function getUserProfile(address user) external view returns (UserProfile memory) {
        return userProfiles[user];
    }
    
    /**
     * @dev Verifica si un usuario está activo y verificado
     */
    function isUserActiveAndVerified(address user) external view returns (bool) {
        UserProfile memory profile = userProfiles[user];
        
        return isRegistered[user] && 
               profile.status == UserStatus.Active && 
               profile.isVerified;
    }
    
    /**
     * @dev Obtiene todos los usuarios de un tipo específico
     */
    function getUsersByType(UserType userType) external view returns (address[] memory) {
        return usersByType[userType];
    }
    
    /**
     * @dev Busca usuarios por skill (para ServiceProviders)
     */
    function getServiceProvidersBySkill(string memory skill) 
        external 
        view 
        returns (address[] memory) 
    {
        address[] memory providers = usersByType[UserType.ServiceProvider];
        address[] memory matchingProviders = new address[](providers.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < providers.length; i++) {
            UserProfile memory profile = userProfiles[providers[i]];
            
            if (profile.status == UserStatus.Active) {
                for (uint256 j = 0; j < profile.skills.length; j++) {
                    if (keccak256(bytes(profile.skills[j])) == keccak256(bytes(skill))) {
                        matchingProviders[count] = providers[i];
                        count++;
                        break;
                    }
                }
            }
        }
        
        // Crear array del tamaño correcto
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = matchingProviders[i];
        }
        
        return result;
    }
    
    /**
     * @dev Funciones de administración
     */
    function setRegistrationFee(uint256 newFee) external onlyOwner {
        registrationFee = newFee;
        emit RegistrationFeeUpdated(newFee);
    }
    
    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }
    
    /**
     * @dev Funciones internas
     */
    function _validateRegistration(address user, string memory name) internal view {
        if (isRegistered[user]) revert UserAlreadyRegistered(user);
        if (bytes(name).length == 0) revert InvalidName(name);
        if (nameToAddress[name] != address(0)) revert NameAlreadyTaken(name);
    }
    
    function _processRegistrationFee() internal {
        if (registrationFee > 0) {
            require(msg.value >= registrationFee, "Insufficient registration fee");
            
            if (msg.value > registrationFee) {
                // Devolver cambio
                payable(msg.sender).transfer(msg.value - registrationFee);
            }
            
            // Enviar fee al recipient
            if (feeRecipient != address(0)) {
                payable(feeRecipient).transfer(registrationFee);
            }
        }
    }
}
