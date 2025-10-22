// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ========== IMPORTS ==========
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/*
 * @title KipuBankV2
 * @author Tomas Giardino
 * @notice Un smart contract de bóveda bancaria avanzada que permite depositar y retirar múltiples tokens
 * @dev Implementa control de acceso, soporte multi-token, oráculos Chainlink y conversión de decimales
 */
contract KipuBankV2 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========== TYPE DECLARATIONS ==========
    
    /**
     * @notice Estructura para almacenar información de tokens soportados
     * @param isSupported Indica si el token está activo en el banco
     * @param priceFeed Dirección del oráculo Chainlink para el token
     * @param decimals Decimales del token (para conversión)
     */
    struct TokenInfo {
        bool isSupported;
        address priceFeed;
        uint8 decimals;
    }

    /**
     * @notice Estructura para estadísticas por token
     * @param totalDeposited Total depositado de este token
     * @param depositCount Número de depósitos realizados
     * @param withdrawalCount Número de retiros realizados
     */
    struct TokenStats {
        uint256 totalDeposited;
        uint256 depositCount;
        uint256 withdrawalCount;
    }

    // ========== STATE VARIABLES ==========

    // Constants

    /*
     * @notice Dirección especial que representa ETH nativo
     * @dev Usamos address(0) para representar ETH en la contabilidad interna
     */
    address public constant NATIVE_TOKEN = address(0);

    /*
     * @notice Decimales de referencia para la contabilidad interna (USDC = 6 decimales)
     * @dev Todos los valores se normalizan a 6 decimales para consistencia
     */
    uint8 public constant ACCOUNTING_DECIMALS = 6;

    /*
     * @notice Precisión adicional para cálculos de precio (8 decimales de Chainlink)
     */
    uint8 public constant PRICE_FEED_DECIMALS = 8;

    // Immutable

    /*
     * @notice Umbral máximo de retiro en USD (normalizado a 6 decimales)
     * @dev Valor fijo establecido durante el despliegue
     */
    uint256 public immutable i_withdrawalThresholdUSD;

    /*
     * @notice Límite máximo del banco en USD (normalizado a 6 decimales)
     * @dev Definido durante el despliegue del contrato, no puede ser modificado
     */
    uint256 public immutable i_bankCapUSD;

    // Storage

    /*
     * @notice Total de valor depositado en el banco en USD (normalizado)
     * @dev Se actualiza con cada depósito y retiro usando valores convertidos
     */
    uint256 private s_totalValueUSD;

    /*
     * @notice Mapeo de información de tokens soportados
     * @dev token address => TokenInfo
     */
    mapping(address token => TokenInfo info) private s_tokenInfo;

    /*
     * @notice Mapeo anidado de balances de usuarios por token
     * @dev user address => token address => balance
     */
    mapping(address user => mapping(address token => uint256 balance)) private s_balances;

    /*
     * @notice Mapeo de estadísticas por token
     * @dev token address => TokenStats
     */
    mapping(address token => TokenStats stats) private s_tokenStats;

    /*
     * @notice Lista de tokens soportados para iteración
     */
    address[] private s_supportedTokens;

    // ========== EVENTS ==========

    /*
     * @notice Emitido cuando un usuario realiza un depósito exitoso
     * @param user Dirección del usuario
     * @param token Dirección del token (address(0) para ETH)
     * @param amount Cantidad depositada en unidades del token
     * @param valueUSD Valor equivalente en USD
     * @param newBalance Nuevo balance del usuario
     */
    event DepositMade(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUSD,
        uint256 newBalance
    );

    /*
     * @notice Emitido cuando un usuario realiza un retiro exitoso
     * @param user Dirección del usuario
     * @param token Dirección del token (address(0) para ETH)
     * @param amount Cantidad retirada
     * @param valueUSD Valor equivalente en USD
     * @param remainingBalance Balance restante
     */
    event WithdrawalMade(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUSD,
        uint256 remainingBalance
    );

    /*
     * @notice Emitido cuando se agrega un nuevo token soportado
     * @param token Dirección del token
     * @param priceFeed Dirección del oráculo
     * @param decimals Decimales del token
     */
    event TokenAdded(address indexed token, address priceFeed, uint8 decimals);

    /*
     * @notice Emitido cuando se remueve un token
     * @param token Dirección del token removido
     */
    event TokenRemoved(address indexed token);

    /*
     * @notice Emitido cuando se actualiza el price feed de un token
     * @param token Dirección del token
     * @param newPriceFeed Nueva dirección del oráculo
     */
    event PriceFeedUpdated(address indexed token, address newPriceFeed);

    // ========== ERRORS ==========

    error KipuBankV2__ZeroAmount();
    error KipuBankV2__ZeroAddress();
    error KipuBankV2__TokenNotSupported(address token);
    error KipuBankV2__TokenAlreadySupported(address token);
    error KipuBankV2__InsufficientBalance(uint256 requested, uint256 available);
    error KipuBankV2__ExceedsBankCapacity(uint256 attempted, uint256 available);
    error KipuBankV2__ExceedsWithdrawalThreshold(uint256 requested, uint256 maxAllowed);
    error KipuBankV2__TransferFailed();
    error KipuBankV2__InvalidPriceFeed(address priceFeed);
    error KipuBankV2__StalePrice();
    error KipuBankV2__InvalidPrice();

    // ========== MODIFIERS ==========

    /*
     * @notice Valida que la cantidad no sea cero
     */
    modifier nonZeroAmount(uint256 _amount) {
        if (_amount == 0) revert KipuBankV2__ZeroAmount();
        _;
    }

    /*
     * @notice Valida que el token esté soportado
     */
    modifier onlySupportedToken(address _token) {
        if (!s_tokenInfo[_token].isSupported) {
            revert KipuBankV2__TokenNotSupported(_token);
        }
        _;
    }

    /*
     * @notice Valida que el usuario tenga balance suficiente
     */
    modifier hasSufficientBalance(address _user, address _token, uint256 _amount) {
        if (s_balances[_user][_token] < _amount) {
            revert KipuBankV2__InsufficientBalance(_amount, s_balances[_user][_token]);
        }
        _;
    }

    

    // ========== CONSTRUCTOR ==========

    /*
     * @notice Inicializa KipuBankV2 con los parámetros especificados
     * @param _bankCapUSD Límite máximo del banco en USD (en 6 decimales)
     * @param _withdrawalThresholdUSD Límite de retiro por transacción en USD (en 6 decimales)
     * @param _ethPriceFeed Dirección del oráculo Chainlink para ETH/USD
     * @dev El owner puede agregar más tokens después del despliegue
     */
    constructor(uint256 _bankCapUSD, uint256 _withdrawalThresholdUSD, address _ethPriceFeed) Ownable(msg.sender) {
        if (_bankCapUSD == 0 || _withdrawalThresholdUSD == 0) {
            revert KipuBankV2__ZeroAmount();
        }
        if (_ethPriceFeed == address(0)) {
            revert KipuBankV2__ZeroAddress();
        }

        i_bankCapUSD = _bankCapUSD;
        i_withdrawalThresholdUSD = _withdrawalThresholdUSD;

        // Configurar ETH nativo como primer token soportado
        s_tokenInfo[NATIVE_TOKEN] = TokenInfo({
            isSupported: true,
            priceFeed: _ethPriceFeed,
            decimals: 18 // ETH tiene 18 decimales
        });

        s_supportedTokens.push(NATIVE_TOKEN);

        emit TokenAdded(NATIVE_TOKEN, _ethPriceFeed, 18);
    }

    // ========== EXTERNAL FUNCTIONS ==========

    /*
     * @notice Deposita ETH nativo en el banco
     * @dev Función payable que acepta ETH y actualiza el balance
     */
    function depositETH() external payable nonZeroAmount(msg.value) onlySupportedToken(NATIVE_TOKEN) nonReentrant {
        uint256 valueUSD = _getValueInUSD(NATIVE_TOKEN, msg.value);

        // Checks: Verificar capacidad del banco
        _checkBankCapacity(valueUSD);

        // Effects: Actualizar estado
        s_balances[msg.sender][NATIVE_TOKEN] += msg.value;
        s_totalValueUSD += valueUSD;
        s_tokenStats[NATIVE_TOKEN].totalDeposited += msg.value;
        s_tokenStats[NATIVE_TOKEN].depositCount++;

        emit DepositMade(
            msg.sender,
            NATIVE_TOKEN,
            msg.value,
            valueUSD,
            s_balances[msg.sender][NATIVE_TOKEN]
        );
    }

    /*
     * @notice Deposita tokens ERC20 en el banco
     * @param _token Dirección del token ERC20
     * @param _amount Cantidad de tokens a depositar
     */
    function depositERC20(address _token, uint256 _amount) external nonZeroAmount(_amount) onlySupportedToken(_token) nonReentrant {
        if (_token == NATIVE_TOKEN) revert KipuBankV2__TokenNotSupported(_token);

        uint256 valueUSD = _getValueInUSD(_token, _amount);

        // Checks: Verificar capacidad del banco
        _checkBankCapacity(valueUSD);

        // Effects: Actualizar estado
        s_balances[msg.sender][_token] += _amount;
        s_totalValueUSD += valueUSD;
        s_tokenStats[_token].totalDeposited += _amount;
        s_tokenStats[_token].depositCount++;

        // Interactions: Transferir tokens
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        emit DepositMade(msg.sender, _token, _amount, valueUSD, s_balances[msg.sender][_token]);
    }

    /*
     * @notice Retira ETH nativo del banco
     * @param _amount Cantidad de ETH a retirar
     */
    function withdrawETH(uint256 _amount) external nonZeroAmount(_amount)  onlySupportedToken(NATIVE_TOKEN) hasSufficientBalance(msg.sender, NATIVE_TOKEN, _amount) nonReentrant{
        uint256 valueUSD = _getValueInUSD(NATIVE_TOKEN, _amount);

        // Checks: Verificar umbral de retiro
        _checkWithdrawalThreshold(valueUSD);

        // Effects: Actualizar estado
        s_balances[msg.sender][NATIVE_TOKEN] -= _amount;
        s_totalValueUSD -= valueUSD;
        s_tokenStats[NATIVE_TOKEN].withdrawalCount++;

        // Interactions: Transferir ETH
        (bool success, ) = payable(msg.sender).call{value: _amount}("");
        if (!success) revert KipuBankV2__TransferFailed();

        emit WithdrawalMade(
            msg.sender,
            NATIVE_TOKEN,
            _amount,
            valueUSD,
            s_balances[msg.sender][NATIVE_TOKEN]
        );
    }

    /*
     * @notice Retira tokens ERC20 del banco
     * @param _token Dirección del token ERC20
     * @param _amount Cantidad de tokens a retirar
     */
    function withdrawERC20(address _token, uint256 _amount) external nonZeroAmount(_amount) onlySupportedToken(_token) hasSufficientBalance(msg.sender, _token, _amount) nonReentrant {
        if (_token == NATIVE_TOKEN) revert KipuBankV2__TokenNotSupported(_token);

        uint256 valueUSD = _getValueInUSD(_token, _amount);

        // Checks: Verificar umbral de retiro
        _checkWithdrawalThreshold(valueUSD);

        // Effects: Actualizar estado
        s_balances[msg.sender][_token] -= _amount;
        s_totalValueUSD -= valueUSD;
        s_tokenStats[_token].withdrawalCount++;

        // Interactions: Transferir tokens
        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit WithdrawalMade(msg.sender, _token, _amount, valueUSD, s_balances[msg.sender][_token]);
    }

    // ========== ADMIN FUNCTIONS ==========

    /*
     * @notice Agrega un nuevo token soportado (solo owner)
     * @param _token Dirección del token
     * @param _priceFeed Dirección del oráculo Chainlink
     * @param _decimals Decimales del token
     */
    function addSupportedToken(address _token, address _priceFeed, uint8 _decimals) external onlyOwner {
        if (_token == address(0) || _priceFeed == address(0)) {
            revert KipuBankV2__ZeroAddress();
        }
        if (s_tokenInfo[_token].isSupported) {
            revert KipuBankV2__TokenAlreadySupported(_token);
        }

        // Verificar que el price feed sea válido
        _validatePriceFeed(_priceFeed);

        s_tokenInfo[_token] = TokenInfo({
            isSupported: true,
            priceFeed: _priceFeed,
            decimals: _decimals
        });

        s_supportedTokens.push(_token);

        emit TokenAdded(_token, _priceFeed, _decimals);
    }

    /*
     * @notice Remueve un token soportado (solo owner)
     * @param _token Dirección del token a remover
     */
    function removeSupportedToken(address _token) external onlyOwner {
        if (!s_tokenInfo[_token].isSupported) {
            revert KipuBankV2__TokenNotSupported(_token);
        }

        s_tokenInfo[_token].isSupported = false;

        emit TokenRemoved(_token);
    }

    /*
     * @notice Actualiza el price feed de un token (solo owner)
     * @param _token Dirección del token
     * @param _newPriceFeed Nueva dirección del oráculo
     */
    function updatePriceFeed(address _token, address _newPriceFeed) external onlyOwner {
        if (!s_tokenInfo[_token].isSupported) {
            revert KipuBankV2__TokenNotSupported(_token);
        }
        if (_newPriceFeed == address(0)) {
            revert KipuBankV2__ZeroAddress();
        }

        _validatePriceFeed(_newPriceFeed);

        s_tokenInfo[_token].priceFeed = _newPriceFeed;

        emit PriceFeedUpdated(_token, _newPriceFeed);
    }

    // ========== INTERNAL/PRIVATE FUNCTIONS ==========

    /*
     * @notice Obtiene el valor en USD de una cantidad de tokens
     * @param _token Dirección del token
     * @param _amount Cantidad de tokens
     * @return valueUSD Valor en USD normalizado a ACCOUNTING_DECIMALS
     */
    function _getValueInUSD(address _token, uint256 _amount) private view returns (uint256 valueUSD){
        TokenInfo memory tokenInfo = s_tokenInfo[_token];
        
        // Obtener precio del oráculo
        (, int256 price, , uint256 updatedAt, ) = AggregatorV3Interface(tokenInfo.priceFeed).latestRoundData();

        // Validar precio
        if (price <= 0) revert KipuBankV2__InvalidPrice();
        if (block.timestamp - updatedAt > 3600) revert KipuBankV2__StalePrice(); // 1 hora

        // Convertir a USD normalizado
        valueUSD = _convertToAccountingDecimals(_amount, uint256(price), tokenInfo.decimals, PRICE_FEED_DECIMALS);

        return valueUSD;
    }

    /*
     * @notice Convierte valores entre diferentes decimales
     * @param _amount Cantidad original
     * @param _price Precio del token (en decimales del price feed)
     * @param _tokenDecimals Decimales del token
     * @param _priceDecimals Decimales del precio
     * @return normalizedValue Valor normalizado a ACCOUNTING_DECIMALS
     */
    function _convertToAccountingDecimals(uint256 _amount, uint256 _price, uint8 _tokenDecimals, uint8 _priceDecimals) private pure returns (uint256 normalizedValue) {
        // Fórmula: (amount * price) / (10^tokenDecimals * 10^priceDecimals) * 10^ACCOUNTING_DECIMALS
        // Simplificado: (amount * price * 10^ACCOUNTING_DECIMALS) / (10^(tokenDecimals + priceDecimals))

        uint256 totalDecimals = uint256(_tokenDecimals) + uint256(_priceDecimals);
        
        if (totalDecimals > ACCOUNTING_DECIMALS) {
            normalizedValue = (_amount * _price) / (10 ** (totalDecimals - ACCOUNTING_DECIMALS));
        } else {
            normalizedValue = (_amount * _price) * (10 ** (ACCOUNTING_DECIMALS - totalDecimals));
        }

        return normalizedValue;
    }

    /*
     * @notice Verifica que no se exceda la capacidad del banco
     * @param _valueUSD Valor a agregar en USD
     */
    function _checkBankCapacity(uint256 _valueUSD) private view {
        uint256 newTotalValue = s_totalValueUSD + _valueUSD;
        if (newTotalValue > i_bankCapUSD) {
            revert KipuBankV2__ExceedsBankCapacity(_valueUSD, i_bankCapUSD - s_totalValueUSD);
        }
    }

    /*
     * @notice Verifica que no se exceda el umbral de retiro
     * @param _valueUSD Valor a retirar en USD
     */
    function _checkWithdrawalThreshold(uint256 _valueUSD) private view {
        if (_valueUSD > i_withdrawalThresholdUSD) {
            revert KipuBankV2__ExceedsWithdrawalThreshold(_valueUSD, i_withdrawalThresholdUSD);
        }
    }

    /*
     * @notice Valida que un price feed sea funcional
     * @param _priceFeed Dirección del price feed a validar
     */
    function _validatePriceFeed(address _priceFeed) private view {
        try AggregatorV3Interface(_priceFeed).latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256,
            uint80
        ) {
            if (price <= 0) revert KipuBankV2__InvalidPriceFeed(_priceFeed);
        } catch {
            revert KipuBankV2__InvalidPriceFeed(_priceFeed);
        }
    }

    // ========== VIEW/PURE FUNCTIONS ==========

    /*
     * @notice Obtiene el balance de un usuario para un token específico
     * @param _user Dirección del usuario
     * @param _token Dirección del token
     * @return balance Balance del usuario
     */
    function getUserBalance(address _user, address _token) external view returns (uint256 balance) {
        return s_balances[_user][_token];
    }

    /*
     * @notice Obtiene todos los balances de un usuario
     * @param _user Dirección del usuario
     * @return tokens Array de direcciones de tokens
     * @return balances Array de balances correspondientes
     */
    function getAllUserBalances(address _user) external view returns (address[] memory tokens, uint256[] memory balances) {
        uint256 length = s_supportedTokens.length;
        tokens = new address[](length);
        balances = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            tokens[i] = s_supportedTokens[i];
            balances[i] = s_balances[_user][s_supportedTokens[i]];
        }

        return (tokens, balances);
    }

    /*
     * @notice Obtiene estadísticas generales del banco
     * @return totalValueUSD Valor total en USD
     * @return remainingCapacityUSD Capacidad restante en USD
     * @return supportedTokensCount Cantidad de tokens soportados
     */
    function getBankStats() external view returns (uint256 totalValueUSD, uint256 remainingCapacityUSD, uint256 supportedTokensCount){
        return (
            s_totalValueUSD,
            i_bankCapUSD - s_totalValueUSD,
            s_supportedTokens.length
        );
    }

    /*
     * @notice Obtiene estadísticas de un token específico
     * @param _token Dirección del token
     * @return stats Estructura TokenStats con las estadísticas
     */
    function getTokenStats(address _token) external view returns (TokenStats memory stats) {
        return s_tokenStats[_token];
    }

    /*
     * @notice Obtiene información de un token
     * @param _token Dirección del token
     * @return info Estructura TokenInfo con la información
     */
    function getTokenInfo(address _token) external view returns (TokenInfo memory info) {
        return s_tokenInfo[_token];
    }

    /*
     * @notice Obtiene la lista de tokens soportados
     * @return tokens Array de direcciones de tokens soportados
     */
    function getSupportedTokens() external view returns (address[] memory tokens) {
        return s_supportedTokens;
    }

    /*
     * @notice Obtiene el precio actual de un token en USD
     * @param _token Dirección del token
     * @return price Precio en USD (8 decimales de Chainlink)
     */
    function getTokenPrice(address _token) external view returns (uint256 price) {
        if (!s_tokenInfo[_token].isSupported) {
            revert KipuBankV2__TokenNotSupported(_token);
        }

        (, int256 answer, , , ) = AggregatorV3Interface(s_tokenInfo[_token].priceFeed)
            .latestRoundData();

        if (answer <= 0) revert KipuBankV2__InvalidPrice();

        return uint256(answer);
    }

    /*
     * @notice Calcula el valor en USD de una cantidad de tokens
     * @param _token Dirección del token
     * @param _amount Cantidad de tokens
     * @return valueUSD Valor en USD normalizado
     */
    function calculateValueInUSD(address _token, uint256 _amount) external view onlySupportedToken(_token) returns (uint256 valueUSD){
        return _getValueInUSD(_token, _amount);
    }

    // ========== RECEIVE/FALLBACK ==========

    receive() external payable {
        revert("Use la funcion depositETH().");
    }

    fallback() external {
        revert("No se esta realiazando ninguna accion.");
    }
}