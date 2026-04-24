// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Lantern Vault - EVM Side
/// @notice Cross-chain yield-bearing vault on Ethereum/ EVM chains
/// @dev Implements ERC-4626-like vault standard with Wormhole cross-chain support
contract LanternVault is ERC20, Ownable, ReentrancyGuard {
    
    // ============================================================================
    // Constants
    
    // Chain IDs (Wormhole format)
    uint16 public constant CHAIN_ID_SUI = 21;
    uint16 public constant CHAIN_ID_ETHEREUM = 2;
    
    // Fee settings (in basis points)
    uint256 public constant MAX_FEE_BPS = 500; // 5% max
    uint256 public constant DEPOSIT_FEE_BPS = 0; // No deposit fee
    uint256 public constant WITHDRAW_FEE_BPS = 50; // 0.5% withdraw fee
    
    // ============================================================================
    // State Variables
    
    // Token contracts
    IERC20 public immutable underlying; // USDC
    address public wormholeBridge;
    address public aavePool;
    
    // Vault state
    uint256 public totalUnderlying; // Total assets in vault (including yields)
    uint256 public totalShares; // Total vault shares
    uint256 public feeBps = 50; // Protocol fee (0.5%)
    address public treasury; // Fee recipient
    
    // Cross-chain
    mapping(bytes32 => bool) public consumedVAAs; // Prevent replay attacks
    mapping(address => uint256) public userShares; // User's share balance
    address public suiVaultAddress; // Sui vault address (bytes32)
    bool public crossChainEnabled = true;
    
    // ============================================================================
    // Events
    
    event Deposit(address indexed user, uint256 amount, uint256 shares);
    event Withdraw(address indexed user, uint256 amount, uint256 shares, uint256 fee);
    event YieldGenerated(uint256 amount, uint256 newTotalUnderlying);
    event FeeCollected(address indexed recipient, uint256 amount);
    
    // Cross-chain events
    event CrossChainDeposit(address indexed user, uint256 amount, uint256 shares, bytes32 indexed vaaHash);
    event CrossChainWithdraw(address indexed user, uint256 amount, uint256 shares, uint16 destChain, bytes32 recipient);
    event CrossChainMessageSent(bytes32 indexed messageId, uint16 destChain, bytes32 recipient, uint256 amount);
    event CrossChainMessageReceived(bytes32 indexed vaaHash, address indexed user, uint256 amount);
    
    // Admin events
    event FeeRateUpdated(uint256 oldRate, uint256 newRate);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event WormholeBridgeUpdated(address oldBridge, address newBridge);
    event AavePoolUpdated(address oldPool, address newPool);
    event SuiVaultUpdated(address oldVault, address newVault);
    event CrossChainToggled(bool enabled);
    
    // ============================================================================
    // Errors
    
    error InvalidToken();
    error InsufficientBalance();
    error ZeroAmount();
    error FeeExceedsMaximum();
    error CrossChainDisabled();
    error VAAAlreadyConsumed();
    error InvalidChain();
    error InvalidMessageType();
    
    // ============================================================================
    // Constructor
    
    /// @param _underlying USDC token address
    /// @param _wormhole Wormhole bridge address
    /// @param _aave Aave pool address
    /// @param _treasury Fee recipient address
    constructor(
        address _underlying,
        address _wormhole,
        address _aave,
        address _treasury
    ) ERC20("Lantern USDC", "lUSDC") Ownable(msg.sender) {
        require(_underlying != address(0), "Invalid underlying");
        require(_wormhole != address(0), "Invalid wormhole");
        
        underlying = IERC20(_underlying);
        wormholeBridge = _wormhole;
        aavePool = _aave;
        treasury = _treasury;
    }
    
    // ============================================================================
    // Deposit Functions
    
    /// @notice Deposit USDC and receive vault shares
    /// @param amount Amount of USDC to deposit
    /// @return shares Amount of vault shares received
    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        require(amount > 0, ZeroAmount());
        
        // Transfer USDC from user
        require(underlying.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Calculate shares
        shares = _mintShares(msg.sender, amount);
        
        // Update state
        totalUnderlying += amount;
        
        // Deposit to Aave for yield
        _depositToAave(amount);
        
        emit Deposit(msg.sender, amount, shares);
    }
    
    /// @notice Deposit with permit (for gasless approvals)
    function depositWithPermit(
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 shares) {
        require(amount > 0, ZeroAmount());
        
        // Permit
        IERC20Permit(address(underlying)).permit(msg.sender, address(this), amount, deadline, v, r, s);
        
        // Transfer USDC
        require(underlying.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // Calculate shares
        shares = _mintShares(msg.sender, amount);
        
        // Update state
        totalUnderlying += amount;
        
        // Deposit to Aave
        _depositToAave(amount);
        
        emit Deposit(msg.sender, amount, shares);
    }
    
    // ============================================================================
    // Withdraw Functions
    
    /// @notice Burn shares and receive USDC
    /// @param shares Amount of shares to burn
    /// @return amount Amount of USDC received
    function withdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        require(shares > 0, ZeroAmount());
        require(userShares[msg.sender] >= shares, InsufficientBalance());
        
        // Calculate amount to receive
        amount = _burnShares(msg.sender, shares);
        
        // Calculate fee
        uint256 fee = (amount * WITHDRAW_FEE_BPS) / 10000;
        uint256 netAmount = amount - fee;
        
        // Update state
        totalUnderlying -= amount;
        
        // Withdraw from Aave
        _withdrawFromAave(netAmount);
        
        // Transfer to user
        require(underlying.transfer(msg.sender, netAmount), "Transfer failed");
        
        // Transfer fee to treasury
        if (fee > 0) {
            require(underlying.transfer(treasury, fee), "Fee transfer failed");
            emit FeeCollected(treasury, fee);
        }
        
        emit Withdraw(msg.sender, amount, shares, fee);
    }
    
    /// @notice Withdraw to specific address
    function withdrawTo(uint256 shares, address recipient) external nonReentrant returns (uint256 amount) {
        require(shares > 0, ZeroAmount());
        require(userShares[msg.sender] >= shares, InsufficientBalance());
        
        // Calculate amount
        amount = _burnShares(msg.sender, shares);
        
        // Calculate fee
        uint256 fee = (amount * WITHDRAW_FEE_BPS) / 10000;
        uint256 netAmount = amount - fee;
        
        // Update state
        totalUnderlying -= amount;
        
        // Withdraw from Aave
        _withdrawFromAave(netAmount);
        
        // Transfer to recipient
        require(underlying.transfer(recipient, netAmount), "Transfer failed");
        
        // Transfer fee
        if (fee > 0) {
            require(underlying.transfer(treasury, fee), "Fee transfer failed");
        }
        
        emit Withdraw(msg.sender, amount, shares, fee);
    }
    
    // ============================================================================
    // Cross-Chain Functions (EVM → Sui)
    
    /// @notice Deposit from Sui chain (called by Relayer)
    /// @param payload Encoded payload from Wormhole
    /// @param vaaSignature Wormhole VAA signatures
    function depositFromSui(
        bytes calldata payload,
        bytes[] calldata vaaSignature
    ) external nonReentrant returns (uint256 shares) {
        require(crossChainEnabled, CrossChainDisabled());
        
        // Parse payload
        (address recipient, uint256 amount) = abi.decode(payload, (address, uint256));
        
        // Verify VAA (simplified - in production use proper Wormhole verification)
        bytes32 vaaHash = keccak256(abi.encode(payload, vaaSignature));
        require(!consumedVAAs[vaaHash], VAAAlreadyConsumed());
        consumedVAAs[vaaHash] = true;
        
        // Calculate shares
        shares = _mintShares(recipient, amount);
        
        // Update state
        totalUnderlying += amount;
        
        // Deposit to Aave
        _depositToAave(amount);
        
        emit CrossChainDeposit(recipient, amount, shares, vaaHash);
    }
    
    // ============================================================================
    // Cross-Chain Functions (EVM → Sui)
    
    /// @notice Withdraw to Sui chain
    /// @param shares Amount of shares to burn
    /// @param recipient Recipient address on Sui (bytes32 format)
    function withdrawToSui(
        uint256 shares,
        bytes32 recipient
    ) external nonReentrant returns (bytes32 messageId) {
        require(crossChainEnabled, CrossChainDisabled());
        require(shares > 0, ZeroAmount());
        require(userShares[msg.sender] >= shares, InsufficientBalance());
        
        // Calculate amount
        uint256 amount = _burnShares(msg.sender, shares);
        
        // Calculate fee
        uint256 fee = (amount * WITHDRAW_FEE_BPS) / 10000;
        uint256 netAmount = amount - fee;
        
        // Update state
        totalUnderlying -= amount;
        
        // Withdraw from Aave
        _withdrawFromAave(netAmount);
        
        // Build cross-chain message
        bytes memory messagePayload = abi.encode(
            msg.sender, // Original sender
            netAmount,
            fee
        );
        
        // Send via Wormhole (simplified - actual implementation would call Wormhole)
        // messageId = IWormhole(wormholeBridge).publishMessage(...);
        
        // Transfer fee to treasury
        if (fee > 0) {
            require(underlying.transfer(treasury, fee), "Fee transfer failed");
        }
        
        emit CrossChainWithdraw(msg.sender, netAmount, shares, CHAIN_ID_SUI, recipient);
        
        return messageId;
    }
    
    // ============================================================================
    // Internal Functions
    
    /// @dev Calculate and mint shares for user
    function _mintShares(address user, uint256 amount) internal returns (uint256 shares) {
        if (totalShares == 0) {
            // Initial deposit: 1:1 ratio
            shares = amount;
        } else {
            // Calculate based on current ratio
            shares = (amount * totalShares) / totalUnderlying;
        }
        
        require(shares > 0, ZeroAmount());
        
        userShares[user] += shares;
        totalShares += shares;
    }
    
    /// @dev Burn shares and return underlying amount
    function _burnShares(address user, uint256 shares) internal returns (uint256 amount) {
        amount = (shares * totalUnderlying) / totalShares;
        
        userShares[user] -= shares;
        totalShares -= shares;
        
        require(amount > 0, ZeroAmount());
    }
    
    /// @dev Deposit USDC to Aave
    function _depositToAave(uint256 amount) internal {
        // Approve Aave pool
        underlying.approve(aavePool, amount);
        
        // In production, call Aave pool deposit
        // IAavePool(aavePool).deposit(address(underlying), amount, address(this), 0);
    }
    
    /// @dev Withdraw USDC from Aave
    function _withdrawFromAave(uint256 amount) internal {
        // In production, call Aave pool withdraw
        // IAavePool(aavePool).withdraw(address(underlying), amount, address(this));
    }
    
    // ============================================================================
    // View Functions
    
    /// @notice Calculate shares for given amount
    function convertToShares(uint256 assets) external view returns (uint256) {
        if (totalShares == 0) return assets;
        return (assets * totalShares) / totalUnderlying;
    }
    
    /// @notice Calculate underlying for given shares
    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (totalShares == 0) return shares;
        return (shares * totalUnderlying) / totalShares;
    }
    
    /// @notice Get user's share balance
    function balanceOf(address user) public view override returns (uint256) {
        return userShares[user];
    }
    
    /// @notice Get total shares
    function totalSupply() public view override returns (uint256) {
        return totalShares;
    }
    
    // ============================================================================
    // Admin Functions
    
    /// @notice Update fee rate
    function setFeeRate(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, FeeExceedsMaximum());
        emit FeeRateUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }
    
    /// @notice Update treasury address
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury");
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }
    
    /// @notice Update Wormhole bridge
    function setWormholeBridge(address newBridge) external onlyOwner {
        require(newBridge != address(0), "Invalid bridge");
        emit WormholeBridgeUpdated(wormholeBridge, newBridge);
        wormholeBridge = newBridge;
    }
    
    /// @notice Update Aave pool
    function setAavePool(address newPool) external onlyOwner {
        require(newPool != address(0), "Invalid pool");
        emit AavePoolUpdated(aavePool, newPool);
        aavePool = newPool;
    }
    
    /// @notice Update Sui vault address
    function setSuiVaultAddress(address newVault) external onlyOwner {
        require(newVault != address(0), "Invalid vault");
        emit SuiVaultUpdated(suiVaultAddress, newVault);
        suiVaultAddress = newVault;
    }
    
    /// @notice Toggle cross-chain functionality
    function toggleCrossChain(bool enabled) external onlyOwner {
        crossChainEnabled = enabled;
        emit CrossChainToggled(enabled);
    }
    
    /// @notice Rescue stranded tokens
    function rescueTokens(address token, uint256 amount) external onlyOwner {
        require(token != address(underlying), "Cannot rescue underlying");
        IERC20(token).transfer(owner(), amount);
    }
    
    // ============================================================================
    // Yield Functions
    
    /// @notice Harvest yield from Aave (called by keeper)
    function harvestYield() external onlyOwner returns (uint256) {
        // In production, calculate yield from Aave
        // This is simplified
        uint256 currentBalance = underlying.balanceOf(address(this));
        uint256 yieldAmount = 0;
        
        if (currentBalance > totalUnderlying) {
            yieldAmount = currentBalance - totalUnderlying;
            totalUnderlying = currentBalance;
            emit YieldGenerated(yieldAmount, totalUnderlying);
        }
        
        return yieldAmount;
    }
}

// Interface for ERC20 Permit
interface IERC20Permit is IERC20 {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

// Minimal Aave Pool interface
interface IAavePool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
