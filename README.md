# KipuBankV2 🏦

Una evolución completa del contrato KipuBank original, implementando arquitectura avanzada, soporte multi-token, integración con oráculos Chainlink y control de acceso basado en roles.

---

## 🎯 Resumen Ejecutivo

KipuBankV2 representa una mejora significativa sobre el contrato original, transformándolo de una bóveda simple de ETH a una plataforma bancaria multi-token completa con integración de precios en tiempo real y control administrativo avanzado.

### Estadísticas Clave

- **Líneas de código**: ~650 (vs ~200 en V1)
- **Funcionalidades nuevas**: 15+
- **Tokens soportados**: Ilimitado (configurable)
- **Integración de oráculos**: Chainlink Data Feeds
- **Patrones de seguridad**: 6 implementados

---

## 🚀 Mejoras Implementadas

### 1. Control de Acceso Basado en Roles

**Problema Original**: No existía diferenciación entre usuarios regulares y administradores.

**Solución V2**:
- Integración completa con Chainlink Data Feeds
- Límites del banco expresados en USD en lugar de cantidades de tokens
- Conversión automática de precios en tiempo real
- Protección contra precios obsoletos (stale prices)

```solidity
// Integración del oráculo
AggregatorV3Interface priceFeed = AggregatorV3Interface(tokenInfo.priceFeed);
(, int256 price, , uint256 updatedAt, ) = priceFeed.latestRoundData();

// Validaciones de seguridad
if (price <= 0) revert KipuBankV2__InvalidPrice();
if (block.timestamp - updatedAt > 3600) revert KipuBankV2__StalePrice();
```

**Direcciones de Oráculos**:
- **Sepolia Testnet ETH/USD**: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- **Ethereum Mainnet ETH/USD**: `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`

**Beneficio**: Los límites se mantienen consistentes en valor USD independientemente de la volatilidad de los precios de los tokens.

---

### 5. Conversión de Decimales

**Problema Original**: No consideraba diferentes decimales entre tokens.

**Solución V2**:
- Sistema de normalización a 6 decimales (estándar USDC)
- Conversión matemática precisa entre diferentes decimales
- Manejo de decimales de precios de Chainlink (8 decimales)

```solidity
// Constantes para conversión
uint8 public constant ACCOUNTING_DECIMALS = 6;
uint8 public constant PRICE_FEED_DECIMALS = 8;

// Función de conversión
function _convertToAccountingDecimals(
    uint256 _amount,
    uint256 _price,
    uint8 _tokenDecimals,
    uint8 _priceDecimals
) private pure returns (uint256 normalizedValue) {
    // ETH (18 decimals) * Price (8 decimals) = 26 decimals total
    // Normalizar a 6 decimales: (amount * price) / 10^20
    uint256 totalDecimals = uint256(_tokenDecimals) + uint256(_priceDecimals);
    
    if (totalDecimals > ACCOUNTING_DECIMALS) {
        normalizedValue = (_amount * _price) / (10 ** (totalDecimals - ACCOUNTING_DECIMALS));
    } else {
        normalizedValue = (_amount * _price) * (10 ** (ACCOUNTING_DECIMALS - totalDecimals));
    }
}
```

**Ejemplos de conversión**:
- **ETH (18 decimals)** → 6 decimals
- **USDC (6 decimals)** → 6 decimals (sin conversión)
- **WBTC (8 decimals)** → 6 decimals

**Beneficio**: Precisión matemática al comparar valores de diferentes tokens en la contabilidad interna.

---

### 6. Mejoras de Seguridad

**Nuevos patrones implementados**:

1. **ReentrancyGuard** de OpenZeppelin
   - Protección en todas las funciones de depósito/retiro
   - Previene ataques de reentrancia

2. **SafeERC20**
   - Transferencias seguras de tokens ERC20
   - Manejo de tokens no estándar

3. **Validación de Oráculos**
   - Verificación de price feeds antes de agregar tokens
   - Detección de precios obsoletos (> 1 hora)
   - Validación de precios negativos o cero

4. **Errores Descriptivos**
   - 11 custom errors específicos
   - Información detallada para debugging

```solidity
// Protección contra reentrancia
function depositETH() external payable nonReentrant { ... }

// Validación de price feed
function _validatePriceFeed(address _priceFeed) private view {
    try AggregatorV3Interface(_priceFeed).latestRoundData() returns (
        uint80, int256 price, uint256, uint256, uint80
    ) {
        if (price <= 0) revert KipuBankV2__InvalidPriceFeed(_priceFeed);
    } catch {
        revert KipuBankV2__InvalidPriceFeed(_priceFeed);
    }
}
```
---

## 🚀 Despliegue

### Opción 1: Foundry (Recomendado)

```bash
# Compilar
forge build

# Tests
forge test -vvv

# Desplegar en Sepolia
forge script script/DeployKipuBankV2.s.sol:DeployKipuBankV2 \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY

# Desplegar en Mainnet (¡CUIDADO!)
forge script script/DeployKipuBankV2.s.sol:DeployKipuBankV2 \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify
```

### Parámetros de Despliegue

```solidity
// Valores sugeridos para Sepolia
uint256 bankCapUSD = 100_000 * 10**6;           // $100,000 USD
uint256 withdrawalThresholdUSD = 10_000 * 10**6; // $10,000 USD
address ethPriceFeed = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
```

### Opción 2: Hardhat

```bash
# Compilar
npx hardhat compile

# Desplegar
npx hardhat run scripts/deploy.js --network sepolia

# Verificar
npx hardhat verify --network sepolia DEPLOYED_ADDRESS \
    "100000000000" "10000000000" "0x694AA1769357215DE4FAC081bf1f309aDC325306"
```

---

## 💻 Interacción con el Contrato

### Usando Cast (Foundry)

```bash
# Obtener el balance del banco
cast call $CONTRACT_ADDRESS "getBankStats()" --rpc-url $SEPOLIA_RPC_URL

# Depositar 0.1 ETH
cast send $CONTRACT_ADDRESS "depositETH()" \
    --value 0.1ether \
    --private-key $PRIVATE_KEY \
    --rpc-url $SEPOLIA_RPC_URL

# Consultar balance de usuario
cast call $CONTRACT_ADDRESS \
    "getUserBalance(address,address)" \
    $USER_ADDRESS \
    0x0000000000000000000000000000000000000000 \
    --rpc-url $SEPOLIA_RPC_URL

# Retirar 0.05 ETH
cast send $CONTRACT_ADDRESS \
    "withdrawETH(uint256)" \
    50000000000000000 \
    --private-key $PRIVATE_KEY \
    --rpc-url $SEPOLIA_RPC_URL
```

### Usando Ethers.js

```javascript
const { ethers } = require("ethers");

// Setup
const provider = new ethers.providers.JsonRpcProvider(SEPOLIA_RPC_URL);
const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, wallet);

// Depositar ETH
const depositTx = await contract.depositETH({ value: ethers.utils.parseEther("0.1") });
await depositTx.wait();
console.log("Depósito exitoso!");

// Consultar balance
const balance = await contract.getUserBalance(
    wallet.address,
    ethers.constants.AddressZero // address(0) para ETH
);
console.log("Balance:", ethers.utils.formatEther(balance), "ETH");

// Obtener precio actual de ETH
const ethPrice = await contract.getTokenPrice(ethers.constants.AddressZero);
console.log("Precio ETH/USD:", ethPrice.toString(), "($decimals 8)");

// Retirar ETH
const withdrawTx = await contract.withdrawETH(ethers.utils.parseEther("0.05"));
await withdrawTx.wait();
console.log("Retiro exitoso!");
```

### Funciones Administrativas (Solo Owner)

```javascript
// Agregar soporte para USDC
const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_PRICE_FEED = "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6";
const USDC_DECIMALS = 6;

const addTokenTx = await contract.addSupportedToken(
    USDC_ADDRESS,
    USDC_PRICE_FEED,
    USDC_DECIMALS
);
await addTokenTx.wait();

// Actualizar price feed
const updateTx = await contract.updatePriceFeed(
    USDC_ADDRESS,
    NEW_PRICE_FEED_ADDRESS
);
await updateTx.wait();

// Remover token
const removeTx = await contract.removeSupportedToken(TOKEN_ADDRESS);
await removeTx.wait();
```

---

## 🎯 Decisiones de Diseño

### 1. ¿Por qué Normalizar a 6 Decimales?

**Decisión**: Usar 6 decimales como estándar interno (USDC).

**Razones**:
- USDC es el stablecoin más utilizado en DeFi
- 6 decimales son suficientes para precisión monetaria
- Reduce complejidad computacional vs 18 decimales
- Facilita integración con sistemas financieros tradicionales

**Trade-off**:
- ✅ Mayor claridad en contabilidad USD
- ✅ Menor consumo de gas en cálculos
- ⚠️ Pequeña pérdida de precisión para tokens de 18 decimales en valores muy pequeños

### 2. ¿Por qué Separar depositETH() y depositERC20()?

**Decisión**: Funciones separadas en lugar de una función universal.

**Razones**:
- **Claridad**: Interfaz más intuitiva para usuarios
- **Seguridad**: Menos riesgo de confusión entre ETH y tokens
- **Gas**: Optimización específica por tipo de transacción
- **Errores más descriptivos**: Mensajes específicos según tipo de depósito

**Trade-off**:
- ✅ UX mejorada
- ✅ Código más mantenible
- ⚠️ Más funciones en el contrato (código duplicado mínimo)

### 3. ¿Por qué usar address(0) para ETH?

**Decisión**: Representar ETH nativo con `address(0)`.

**Razones**:
- **Estándar de facto** en la industria DeFi
- Simplifica el mapeo de balances (misma estructura para todos los activos)
- Compatible con contratos que usan WETH
- Evita confusión con direcciones de contratos reales

**Alternativas consideradas**:
- ❌ Usar dirección específica `0xEeeE...EEeE`
- ❌ Sistema separado para ETH vs tokens

### 4. ¿Por qué límite de 1 hora para precios?

**Decisión**: Rechazar precios con más de 1 hora de antigüedad.

**Razones**:
- Chainlink actualiza feeds cada ~1 hora en condiciones normales
- Protección contra oráculos inactivos o problemas de red
- Balance entre frescura de datos y disponibilidad

**Configurable para producción**:
```solidity
uint256 constant MAX_PRICE_STALENESS = 3600; // 1 hora

// Podría hacerse configurable por token:
struct TokenInfo {
    ...
    uint256 maxStaleness;
}
```

**Trade-off**:
- ✅ Seguridad contra datos obsoletos
- ⚠️ Posibles rechazos durante mantenimiento de Chainlink (raro)

### 5. ¿Por qué ReentrancyGuard en lugar de CEI puro?

**Decisión**: Usar ambos: patrón CEI + ReentrancyGuard.

**Razones**:
- **Defensa en profundidad**: Doble capa de protección
- **Facilidad de auditoría**: Modificador explícito visible
- **Costo mínimo**: ~2,400 gas adicional por transacción
- **Tranquilidad**: Protección probada de OpenZeppelin

**Ya implementamos CEI**:
```solidity
// ✅ CORRECTO: Checks-Effects-Interactions
function withdrawETH(uint256 _amount) external nonReentrant {
    // CHECKS
    _checkWithdrawalThreshold(valueUSD);
    
    // EFFECTS
    s_balances[msg.sender][NATIVE_TOKEN] -= _amount;
    s_totalValueUSD -= valueUSD;
    
    // INTERACTIONS
    (bool success, ) = payable(msg.sender).call{value: _amount}("");
}
```

### 6. ¿Por qué no implementar pausable?

**Decisión**: No incluir pausa de emergencia en V2.

**Razones**:
- Mantener simplicidad para el alcance del proyecto
- El owner ya puede remover tokens problemáticos
- Usuarios pueden retirar sus fondos en cualquier momento
- Evitar centralización excesiva

**Para V3 considerar**:
```solidity
// Pausable de OpenZeppelin
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

function depositETH() external payable whenNotPaused { ... }
```

---

## 📊 Comparación V1 vs V2

| Característica | V1 (Original) | V2 (Mejorado) |
|----------------|---------------|---------------|
| **Tokens soportados** | Solo ETH | ETH + ERC20 ilimitados |
| **Límites** | En cantidad de tokens | En valor USD |
| **Oráculos** | ❌ | ✅ Chainlink |
| **Control de acceso** | ❌ | ✅ Ownable |
| **Reentrancy protection** | Manual (CEI) | CEI + ReentrancyGuard |
| **Contabilidad** | Simple mapping | Mapeo anidado multi-token |
| **Conversión de decimales** | ❌ | ✅ Normalización a 6 decimals |
| **Eventos** | 2 eventos | 5 eventos con más datos |
| **Errores** | 7 custom errors | 11 custom errors |
| **Funciones view** | 2 | 7+ con múltiples consultas |
| **Gas optimización** | Básica | Avanzada (immutable, constant) |
| **Líneas de código** | ~200 | ~650 |
| **Complejidad** | Baja | Media-Alta |
| **Listo para producción** | No | Casi (requiere auditoría) |

---

## 🌐 Información de Despliegue

### Redes Testnet

#### Sepolia Testnet
```
Network: Sepolia
Chain ID: 11155111
RPC: https://sepolia.infura.io/v3/YOUR_KEY

Deployed Contracts:
├── KipuBankV2: [PENDING_DEPLOYMENT]
├── Bank Cap: $100,000 USD
├── Withdrawal Threshold: $10,000 USD
└── ETH Price Feed: 0x694AA1769357215DE4FAC081bf1f309aDC325306

Supported Tokens:
├── ETH (Native): address(0)
└── [Agregar más después del despliegue]

Explorer: https://sepolia.etherscan.io/address/[CONTRACT_ADDRESS]
```

#### Goerli Testnet (Deprecated)
⚠️ **Nota**: Goerli será discontinuada. Usar Sepolia.

### Mainnet (Producción)

⚠️ **ADVERTENCIA**: No desplegar en mainnet sin auditoría profesional completa.

```
Network: Ethereum Mainnet
Chain ID: 1

Chainlink Price Feeds:
├── ETH/USD: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
├── BTC/USD: 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c
├── LINK/USD: 0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c
└── USDC/USD: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6
```

---

## 🔗 Recursos Adicionales

### Documentación Oficial

- [Solidity Docs](https://docs.soliditylang.org/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Chainlink Data Feeds](https://docs.chain.link/data-feeds)
- [Foundry Book](https://book.getfoundry.sh/)

### Chainlink Price Feeds

**Sepolia Testnet**:
- [ETH/USD](https://sepolia.etherscan.io/address/0x694AA1769357215DE4FAC081bf1f309aDC325306)
- [Lista completa](https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1#sepolia-testnet)

**Ethereum Mainnet**:
- [ETH/USD](https://etherscan.io/address/0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)
- [BTC/USD](https://etherscan.io/address/0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c)
- [Lista completa](https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1)

### Herramientas de Desarrollo

- **Foundry**: Framework de desarrollo y testing
- **Remix**: IDE online para desarrollo rápido
- **Hardhat**: Framework alternativo con ecosystem rico
- **Tenderly**: Debugging y simulación
- **OpenZeppelin Defender**: Monitoreo y automatización

### Recursos de Aprendizaje

- [CryptoZombies](https://cryptozombies.io/) - Tutorial interactivo Solidity
- [Ethernaut](https://ethernaut.openzeppelin.com/) - Wargame de seguridad
- [Solidity by Example](https://solidity-by-example.org/) - Ejemplos prácticos
- [Smart Contract Programmer](https://www.youtube.com/@smartcontractprogrammer) - YouTube channel

---

## 👨‍💻 Autor

**Tomas Giardino**

---

## 🙏 Agradecimientos

- **OpenZeppelin** - Por los contratos base seguros y auditados
- **Chainlink** - Por la infraestructura de oráculos descentralizada
- **Foundry Team** - Por las herramientas de desarrollo de clase mundial
- **Ethereum Foundation** - Por la plataforma que hace esto posible
- **Comunidad Kipu** - Por el feedback y apoyo continuo
