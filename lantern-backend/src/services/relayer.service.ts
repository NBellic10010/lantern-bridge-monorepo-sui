/**
 * Relayer Service - 跨鏈中繼服務
 * 負責處理 EVM ↔ Sui 跨鏈消息
 * 
 * 使用 Wormhole SDK 進行跨鏈消息處理
 * 
 * 流程:
 * 1. 監聽 Wormhole VAA
 * 2. 解析跨鏈消息
 * 3. 在目標鏈執行對應操作
 */
import { ethers } from 'ethers';
import { wormhole, Chain } from '@wormhole-foundation/sdk';
import { logger } from './logger.service';
import { RedisService } from './redis.service';

// ============================================================================
// 類型定義

interface CrossChainMessage {
    msgType: number;
    sourceChain: number;
    destChain: number;
    user: string;
    amount: bigint;
    fee: bigint;
    timestamp: number;
}

/**
 * 跨鏈轉賬請求接口
 */
interface CrossChainRequest {
    sourceChain: 'Arbitrum' | 'Sui';
    destChain: 'Arbitrum' | 'Sui';
    amount: bigint;
    sender: string;
    recipient: string;
    sourceToken: 'USDC' | 'suiUSDe';
    destToken?: 'USDC' | 'suiUSDe'; // 預設與 sourceToken 相同
    yieldMode?: 'yield' | 'no_yield';
}

/**
 * 跨鏈轉賬響應接口
 */
interface CrossChainResponse {
    success: boolean;
    txHash?: string;
    messageId?: string;
    sourceToken: string;
    destToken: string;
    destTokenYieldInfo?: {
        token: 'suiUSDe';
        estimatedAPY: number;
        description: string;
    };
    message?: string;
}

interface RelayerConfig {
    // Sui 配置
    suiRpcUrl: string;
    suiPackageId: string;
    suiVaultId: string;
    
    // EVM 配置
    evmRpcUrl: string;
    evmVaultAddress: string;
    evmPrivateKey: string;
    
    // Wormhole 配置
    wormholeBridgeAddress: string;
    wormholeGuardianSetIndex: number;
    
    // 應用配置
    port: number;
    confirmations: number;
}

// ============================================================================
// 常量

const MSG_TYPE_DEPOSIT_EVM = 1;
const MSG_TYPE_WITHDRAW_EVM = 2;
const MSG_TYPE_DEPOSIT_SUI = 3;
const MSG_TYPE_WITHDRAW_SUI = 4;

// ============================================================================
// NTT 常量 (v2.0)

/**
 * Wormhole Chain IDs
 */
export const WORMHOLE_CHAIN_ID = {
    Ethereum: 2,
    Sui: 21,
    Arbitrum: 23,
    Optimism: 24,
    Base: 30,
} as const;

/**
 * NTT 模式
 */
export const NTT_MODE = {
    LOCKING: 0,
    BURNING: 1,
} as const;

/**
 * NTT 默認配置
 */
export const NTT_DEFAULTS = {
    // 默認速率限制窗口 (秒)
    RATE_LIMIT_WINDOW: 3600, // 1 小時
    // 默認最大流出量
    MAX_OUTFLOW: BigInt(100_000_000_000), // 100M (假設 6 decimals)
    // 默認 Gas 限制
    GAS_LIMIT: BigInt(500000),
    // 確認塊數
    CONFIRMATIONS: 3,
} as const;

// ============================================================================
// Relayer 服務類

export class RelayerService {
    private static instance: RelayerService;
    
    private config: RelayerConfig;
    private suiProvider: ethers.JsonRpcProvider;
    private evmProvider: ethers.JsonRpcProvider;
    private evmWallet: ethers.Wallet;
    private redis: RedisService;
    private isRunning: boolean = false;
    
    // Chain context
    private readonly SOURCE_CHAIN: Chain = 'Ethereum';
    private readonly DEST_CHAIN: Chain = 'Sui';
    
    private constructor() {
        this.config = this.loadConfig();
        this.suiProvider = new ethers.JsonRpcProvider(this.config.suiRpcUrl);
        this.evmProvider = new ethers.JsonRpcProvider(this.config.evmRpcUrl);
        this.evmWallet = new ethers.Wallet(this.config.evmPrivateKey, this.evmProvider);
        this.redis = RedisService.getInstance();
    }
    
    /**
     * 初始化 Wormhole SDK
     */
    private async initWormhole(): Promise<void> {
        try {
            logger.info('Wormhole SDK initialization skipped - using placeholder');
        } catch (error) {
            logger.error('Failed to initialize Wormhole SDK:', error);
            throw error;
        }
    }
    
    public static getInstance(): RelayerService {
        if (!RelayerService.instance) {
            RelayerService.instance = new RelayerService();
        }
        return RelayerService.instance;
    }
    
    private loadConfig(): RelayerConfig {
        return {
            suiRpcUrl: process.env.SUI_RPC_URL || 'https://sui-testnet-rpc.nodies.xyz',
            suiPackageId: process.env.SUI_PACKAGE_ID || '',
            suiVaultId: process.env.SUI_VAULT_ID || '',
            evmRpcUrl: process.env.EVM_RPC_URL || '',
            evmVaultAddress: process.env.EVM_VAULT_ADDRESS || '',
            evmPrivateKey: process.env.EVM_PRIVATE_KEY || '',
            wormholeBridgeAddress: process.env.WORMHOLE_BRIDGE_ADDRESS || '',
            wormholeGuardianSetIndex: 0,
            port: parseInt(process.env.RELAYER_PORT || '3001'),
            confirmations: parseInt(process.env.CONFIRMATIONS || '3'),
        };
    }
    
    // ============================================================================
    // 啟動/停止
    
    /**
     * 啟動 Relayer 服務
     */
    async start(): Promise<void> {
        if (this.isRunning) {
            logger.warn('Relayer is already running');
            return;
        }
        
        logger.info('Starting Relayer service...');
        
        try {
            // 連接區塊鏈節點
            await this.testConnections();
            
            // 啟動消息監聽
            await this.startListening();
            
            this.isRunning = true;
            logger.info('Relayer service started successfully');
        } catch (error) {
            logger.error('Failed to start Relayer:', error);
            throw error;
        }
    }
    
    /**
     * 停止 Relayer 服務
     */
    async stop(): Promise<void> {
        if (!this.isRunning) {
            return;
        }
        
        logger.info('Stopping Relayer service...');
        this.isRunning = false;
        logger.info('Relayer service stopped');
    }
    
    // ============================================================================
    // 連接測試
    
    private async testConnections(): Promise<void> {
        logger.info('Testing blockchain connections...');
        
        // Test Sui connection
        try {
            const suiChainId = await this.suiProvider.send('sui_getChainIdentifier', []);
            logger.info(`Sui connected: Chain ID ${suiChainId}`);
        } catch (error) {
            logger.error('Sui connection failed:', error);
            throw error;
        }
        
        // Test EVM connection
        try {
            const evmChainId = await this.evmProvider.send('eth_chainId', []);
            logger.info(`EVM connected: Chain ID ${evmChainId}`);
        } catch (error) {
            logger.error('EVM connection failed:', error);
            throw error;
        }
        
        // Test EVM wallet
        const evmBalance = await this.evmProvider.getBalance(this.evmWallet.address);
        logger.info(`EVM Wallet: ${this.evmWallet.address}, Balance: ${ethers.formatEther(evmBalance)} ETH`);
    }
    
    // ============================================================================
    // 消息監聽
    
    /**
     * 啟動跨鏈消息監聽
     */
    private async startListening(): Promise<void> {
        logger.info('Starting cross-chain message listening...');
        
        // 監聽 EVM → Sui 消息
        await this.listenEvmToSui();
        
        // 監聽 Sui → EVM 消息
        await this.listenSuiToEvm();
    }
    
    /**
     * 監聽 EVM → Sui 跨鏈消息
     * 流程: EVM 用戶存款 → Wormhole 發布消息 → Relayer 監聽 → 在 Sui 執行存款
     */
    private async listenEvmToSui(): Promise<void> {
        logger.info('Listening for EVM → Sui messages...');
        
        // 監控 EVM Vault 合約的 Deposit 事件
        // 實際實現需要監控 Wormhole 的 VAA
        
        // 模擬實現
        // const filter = {
        //     address: this.config.evmVaultAddress,
        //     topics: [
        //         ethers.id('CrossChainDeposit(address,uint256,uint256,bytes32)')
        //     ]
        // };
        // 
        // this.evmProvider.on(filter, async (log) => {
        //     try {
        //         await this.handleEvmToSuiDeposit(log);
        //     } catch (error) {
        //         logger.error('Error handling EVM → Sui deposit:', error);
        //     }
        // });
    }
    
    /**
     * 監聽 Sui → EVM 跨鏈消息
     */
    private async listenSuiToEvm(): Promise<void> {
        logger.info('Listening for Sui → EVM messages...');
        
        // 監控 Sui Vault 的跨鏈提款事件
        // 實際實現需要監控 Sui 事件
        
        // 模擬實現
        // const { unsubscribe } = await this.suiProvider.subscribe({
        //     method: 'suix_getEvents',
        //     params: ['eventType: 0x...::vault::CrossChainWithdrawEvent']
        // });
    }
    
    // ============================================================================
    // 消息處理
    
    /**
     * 處理 EVM → Sui 存款
     * 1. 解析 VAA
     * 2. 在 Sui 合約中執行存款
     */
    async handleEvmToSuiDeposit(vaa: Buffer): Promise<string> {
        logger.info('Processing EVM → Sui deposit...');
        
        // 1. 解析 VAA
        const message = this.parseVAA(vaa);
        
        // 2. 驗證消息類型
        if (message.msgType !== MSG_TYPE_DEPOSIT_EVM) {
            throw new Error(`Invalid message type: ${message.msgType}`);
        }
        
        // 3. 檢查是否已處理 (防重放)
        const cacheKey = `vaa:${message.sourceChain}:${message.timestamp}`;
        const exists = await this.redis.get(cacheKey);
        if (exists) {
            throw new Error('VAA already processed');
        }
        
        // 4. 在 Sui 執行存款
        const txDigest = await this.executeSuiDeposit(message);
        
        // 5. 標記已處理
        await this.redis.set(cacheKey, txDigest, 86400); // 24小時過期
        
        logger.info(`EVM → Sui deposit processed: ${txDigest}`);
        
        return txDigest;
    }
    
    /**
     * 處理 Sui → EVM 提款
     * 1. 解析 Sui 事件
     * 2. 在 EVM 合約中執行提款
     */
    async handleSuiToEvmWithdraw(event: unknown): Promise<string> {
        logger.info('Processing Sui → EVM withdraw...');
        
        // 1. 解析事件
        const message = this.parseSuiEvent(event);
        
        // 2. 驗證消息類型
        if (message.msgType !== MSG_TYPE_WITHDRAW_SUI) {
            throw new Error(`Invalid message type: ${message.msgType}`);
        }
        
        // 3. 在 EVM 執行提款
        const txHash = await this.executeEvmWithdraw(message);
        
        logger.info(`Sui → EVM withdraw processed: ${txHash}`);
        
        return txHash;
    }
    
    // ============================================================================
    // Sui 操作
    
    /**
     * 在 Sui 執行存款
     */
    private async executeSuiDeposit(message: CrossChainMessage): Promise<string> {
        // 構建 Sui PTB (Programmable Transaction Block)
        // 調用 cross_chain::receive_from_evm
        
        // 模擬實現
        // const txb = new TransactionBlock();
        // txb.moveCall({
        //     target: `${this.config.suiPackageId}::cross_chain::receive_from_evm`,
        //     arguments: [
        //         txb.object(this.config.suiVaultId),
        //         txb.pure(message.user),
        //         txb.pure(message.amount),
        //         txb.pure(vaaHash),
        //     ]
        // });
        
        // 發送交易
        // const result = await this.suiProvider.executeTransactionBlock({
        //     transactionBlock: txb,
        //     signature: // 後端簽名
        // });
        
        return 'simulated-tx-digest';
    }
    
    // ============================================================================
    // EVM 操作
    
    /**
     * 在 EVM 執行提款
     */
    private async executeEvmWithdraw(message: CrossChainMessage): Promise<string> {
        // 連接 EVM Vault 合約
        // 使用 ethers v6 Contract 類
        const vaultAbi = [
            'function depositFromSui(address user, uint256 amount) external',
            'function withdraw(address user, uint256 amount) external'
        ];
        
        const vault = new ethers.Contract(
            this.config.evmVaultAddress,
            vaultAbi,
            this.evmWallet
        );
        
        // 編碼 payload
        const payload = ethers.AbiCoder.defaultAbiCoder().encode(
            ['address', 'uint256'],
            [message.user, message.amount]
        );
        
        // 發送交易
        // const tx = await vault.depositFromSui(payload, signatures);
        // await tx.wait();
        
        return 'simulated-evm-tx-hash';
    }
    
    // ============================================================================
    // 工具函數
    
    /**
     * 解析 VAA
     */
    private parseVAA(vaa: Buffer): CrossChainMessage {
        // 解析 Wormhole VAA
        // 實際實現需要完整的 VAA 解析邏輯
        
        // 模擬實現
        return {
            msgType: MSG_TYPE_DEPOSIT_EVM,
            sourceChain: 2, // Ethereum
            destChain: 21, // Sui
            user: '0x1234567890123456789012345678901234567890',
            amount: BigInt(1000000), // 1 USDC
            fee: BigInt(500), // 0.5%
            timestamp: Math.floor(Date.now() / 1000),
        };
    }
    
    /**
     * 解析 Sui 事件
     */
    private parseSuiEvent(event: unknown): CrossChainMessage {
        // 解析 Sui 跨鏈事件
        
        return {
            msgType: MSG_TYPE_WITHDRAW_SUI,
            sourceChain: 21, // Sui
            destChain: 2, // Ethereum
            user: '0x1234567890123456789012345678901234567890',
            amount: BigInt(1000000),
            fee: BigInt(500),
            timestamp: Math.floor(Date.now() / 1000),
        };
    }
    
    // ============================================================================
    // NTT 跨鏈轉帳 (新版)
    // ============================================================================
    
    /**
     * 使用 NTT 進行跨鏈轉帳
     * 
     * @param sourceChain 源鏈
     * @param destChain 目標鏈
     * @param amount 轉帳金額
     * @param sender 發送者地址
     * @param recipient 接收者地址
     * @param sourceToken 源代幣: 'USDC' | 'suiUSDe'
     * @param yieldMode 生息模式:
     *   - 'yield': 生息跨鏈 - 持有 suiUSDe 自動收益 / USDC 存入 Navi
     *   - 'no_yield': 非生息跨鏈 - 資產直接轉入用戶錢包
     */
    async transferWithNTT(
        sourceChain: 'Arbitrum' | 'Sui',
        destChain: 'Arbitrum' | 'Sui',
        amount: bigint,
        sender: string,
        recipient: string,
        sourceToken: 'USDC' | 'suiUSDe',
        yieldMode: 'yield' | 'no_yield'
    ): Promise<CrossChainResponse> {
        // 延遲導入避免循環依賴
        const { NttTransferService, YieldMode } = require('./ntt-transfer.service');
        
        const nttService = NttTransferService.getInstance();
        
        // 轉換為 enum 值
        const nttYieldMode = yieldMode === 'yield' 
            ? YieldMode.YIELD 
            : YieldMode.NO_YIELD;
        
        // 目標代幣與源代幣相同
        const destToken = sourceToken;
        
        try {
            const result = await nttService.initiateTransfer({
                sourceChain,
                destChain,
                amount,
                sender,
                recipient,
                token: sourceToken,
                yieldMode: nttYieldMode,
            });
            
            logger.info('NTT transfer initiated', {
                sourceChain,
                destChain,
                amount: amount.toString(),
                sourceToken,
                destToken,
                yieldMode,
                messageId: result.messageId,
            });
            
            return {
                success: true,
                txHash: result.txHash,
                messageId: result.messageId,
                sourceToken: result.sourceToken,
                destToken: result.destToken,
                destTokenYieldInfo: result.destTokenYieldInfo,
                message: this.getYieldModeMessage(nttYieldMode, destToken),
            };
            
        } catch (error) {
            logger.error('NTT transfer failed', { error });
            return {
                success: false,
                sourceToken,
                destToken,
                message: `轉帳失敗: ${error}`,
            };
        }
    }
    
    /**
     * 根據生息模式和代幣獲取描述消息
     */
    private getYieldModeMessage(yieldMode: string, token?: string): string {
        const { YieldMode } = require('./ntt-transfer.service');
        
        // suiUSDe 內置生息
        if (token === 'suiUSDe') {
            return '跨鏈已完成。suiUSDe 已轉入您的錢包，Ethena 收益將自動累計 (~10-15% APY)。';
        }
        
        switch (yieldMode) {
            case YieldMode?.YIELD:
                return '生息跨鏈已完成。您的資產已存入 Navi 借貸協議，利息將自動累計。';
            case YieldMode?.NO_YIELD:
                return '非生息跨鏈已完成。資產已直接轉入您的錢包。';
            default:
                return '跨鏈轉賬已完成。';
        }
    }
    
    /**
     * 查詢跨鏈轉賬狀態
     */
    async getNttTransferStatus(messageId: string): Promise<{
        status: string;
        yieldMode: string;
        sourceToken: string;
        destToken: string;
        description: string;
        yieldInfo?: {
            isYieldBearing: boolean;
            estimatedAPY: number;
        };
    } | null> {
        const { NttTransferService, YieldMode } = require('./ntt-transfer.service');
        
        const nttService = NttTransferService.getInstance();
        const receipt = await nttService.getTransferStatus(messageId);
        
        if (!receipt) {
            return null;
        }
        
        // 獲取收益信息
        const yieldInfo = receipt.destToken === 'suiUSDe' 
            ? {
                isYieldBearing: true,
                estimatedAPY: await NttTransferService.getEstimatedYield('suiUSDe'),
              }
            : undefined;
        
        return {
            status: receipt.status,
            yieldMode: receipt.yieldMode,
            sourceToken: receipt.sourceToken,
            destToken: receipt.destToken,
            description: NttTransferService.getYieldModeDescription(receipt.yieldMode, receipt.destToken),
            yieldInfo,
        };
    }

    // ============================================================================
    // API 端點
    
    /**
     * 獲取 Relayer 狀態
     */
    getStatus(): object {
        return {
            running: this.isRunning,
            config: {
                suiPackageId: this.config.suiPackageId,
                evmVaultAddress: this.config.evmVaultAddress,
            },
        };
    }
    
    /**
     * 手動觸發消息處理 (用於調試)
     */
    async processMessage(vaa: string): Promise<string> {
        const vaaBuffer = Buffer.from(vaa, 'hex');
        return await this.handleEvmToSuiDeposit(vaaBuffer);
    }
    
    // ============================================================================
    // Wormhole SDK 跨鏈轉帳
    // ============================================================================
    
    /**
     * 從 EVM 轉帳到 Sui
     * 使用 Wormhole Token Bridge
     */
    async transferEvmToSui(
        tokenAddress: string,
        amount: bigint,
        recipientSuiAddress: string
    ): Promise<string> {
        logger.info(`Transferring ${amount} from EVM to Sui...`);
        
        // Get the source and destination chains
        const sourceChain = this.SOURCE_CHAIN;
        const destChain = this.DEST_CHAIN;
        
        logger.info(`Source chain: ${sourceChain}, Dest chain: ${destChain}`);
        
        // NOTE: Actual implementation would use:
        // const wh = await wormhole('Mainnet', [Ethereum, Sui]);
        // const transfer = await wh.token.transfer(
        //     tokenId,
        //     amount,
        //     recipientSuiAddress,
        //     destChain
        // );
        
        // For now, return a simulated transaction
        logger.info(`Transfer initiated (simulated): ${amount} to ${recipientSuiAddress}`);
        return 'simulated-wormhole-transfer-tx';
    }
    
    /**
     * 從 Sui 轉帳到 EVM
     */
    async transferSuiToEvm(
        tokenType: string,
        amount: bigint,
        recipientEvmAddress: string
    ): Promise<string> {
        logger.info(`Transferring ${amount} from Sui to EVM...`);
        
        // Get the source and destination chains
        const sourceChain = this.DEST_CHAIN;
        const destChain = this.SOURCE_CHAIN;
        
        logger.info(`Source chain: ${sourceChain}, Dest chain: ${destChain}`);
        
        // NOTE: Actual implementation would use Wormhole SDK
        // const wh = await wormhole('Mainnet', [Sui, Ethereum]);
        // const transfer = await wh.token.transfer(...)
        
        logger.info(`Transfer initiated (simulated): ${amount} to ${recipientEvmAddress}`);
        return 'simulated-wormhole-transfer-tx';
    }
    
    /**
     * 兌換 VAA (在目標鏈)
     */
    async redeemVAA(vaa: Uint8Array): Promise<string> {
        logger.info('Redeeming VAA on Sui...');
        
        // NOTE: Actual implementation would use:
        // const redeemer = await this.wormhole.sui.redeem(vaa);
        
        return 'simulated-redeem-tx';
    }
    
    /**
     * 獲取跨鏈轉帳狀態
     */
    async getTransferStatus(messageId: string): Promise<{
        status: 'pending' | 'completed' | 'failed';
        sourceChain: string;
        destChain: string;
    }> {
        // NOTE: Actual implementation would query Wormhole API
        return {
            status: 'pending',
            sourceChain: 'Ethereum',
            destChain: 'Sui',
        };
    }

    // ============================================================================
    // NTT Event Monitoring & Relay (v2.0)
    // ============================================================================

    // NTT Manager addresses (loaded from config)
    private nttManagers: Record<number, string> = {};

    // Sui SDK clients (initialized lazily)
    private suiClient: any = null;
    private suiKeypair: any = null;

    // Event unsubscribers
    private suiEventUnsubscribe: (() => void) | null = null;
    private evmEventUnsubscribe: (() => void) | null = null;

    /**
     * 初始化 Sui SDK 客户端
     */
    private async initSuiClient(): Promise<void> {
        if (this.suiClient) return;

        try {
            const { SuiClient, getFullnodeUrl } = require('@mysten/sui/client');
            let Ed25519Keypair: any;

            try {
                Ed25519Keypair = require('@mysten/wallet-standard').Ed25519Keypair;
            } catch {
                Ed25519Keypair = require('@mysten/sui/keypairs/ed25519').Ed25519Keypair;
            }

            this.suiClient = new SuiClient({
                url: this.config.suiRpcUrl || getFullnodeUrl('mainnet')
            });

            // 从私钥创建 keypair
            const privateKeyBase64 = process.env.SUI_PRIVATE_KEY;
            if (privateKeyBase64) {
                const privateKeyBytes = Buffer.from(privateKeyBase64, 'base64');
                this.suiKeypair = new Ed25519Keypair({ secretKey: privateKeyBytes });
            }

            // 加载 NTT Manager 地址
            this.nttManagers = {
                [WORMHOLE_CHAIN_ID.Arbitrum]: process.env.NTT_ARBITRUM_MANAGER || '',
                [WORMHOLE_CHAIN_ID.Sui]: process.env.NTT_SUI_MANAGER || '',
            };

            logger.info('Sui SDK client initialized', {
                nttManagers: Object.keys(this.nttManagers),
            });
        } catch (error) {
            logger.error('Failed to initialize Sui client:', error);
            throw error;
        }
    }

    /**
     * 監聽 Sui NttOutboundEvent 並 relay 到 EVM
     *
     * 流程:
     * 1. 監聽 Sui 上的 NttOutboundEvent
     * 2. 解析事件獲取目標鏈、金額、接收者
     * 3. 調用 NttManager.relay() 完成跨鏈
     */
    async listenNttOutboundEvents(): Promise<void> {
        logger.info('Listening for NTT Outbound events on Sui...');

        try {
            // 初始化 Sui 客户端
            await this.initSuiClient();

            if (!this.suiClient) {
                throw new Error('Sui client not initialized');
            }

            // 使用 sui client 的事件订阅功能
            // 监听 NttOutboundEvent 事件
            const packageId = this.config.suiPackageId;

            // 设置事件过滤器
            const eventFilter = {
                MoveEventType: `${packageId}::ntt_integration::NttOutboundEvent`,
            };

            logger.info('Subscribing to Sui NttOutboundEvent', {
                eventFilter,
                packageId,
            });

            // 使用 poll 方式监听事件 (Sui 的 subscribeEvent API)
            this.startPollingNttOutboundEvents(packageId);

        } catch (error) {
            logger.error('Failed to start Sui NTT event listening:', error);
            throw error;
        }
    }

    /**
     * 轮询 Sui 事件 (由于 Sui SDK 的 subscribeEvent 可能不可用)
     */
    private async startPollingNttOutboundEvents(packageId: string): Promise<void> {
        let lastSeq = 0;
        const pollInterval = 5000; // 5 秒轮询一次

        logger.info('Starting Sui NTT event polling', {
            packageId,
            pollInterval,
        });

        const poll = async () => {
            if (!this.isRunning || !this.suiClient) {
                return;
            }

            try {
                // 查询最近的事件
                const events = await this.suiClient.queryEvents({
                    query: {
                        MoveEventType: `${packageId}::ntt_integration::NttOutboundEvent`,
                    },
                    order: 'descending',
                    limit: 10,
                });

                for (const event of events.data) {
                    const parsedJson = event.parsedJson as any;
                    if (!parsedJson) continue;

                    // 跳过已处理的事件 (简单的去重)
                    const seq = parsedJson.sequence;
                    if (seq && seq > lastSeq) {
                        lastSeq = seq;

                        logger.info('Received NttOutboundEvent', {
                            sequence: seq,
                            destChain: parsedJson.dest_chain,
                            amount: parsedJson.amount,
                        });

                        // Relay 到目标链
                        await this.relayNttMessage({
                            sequence: BigInt(seq),
                            token: parsedJson.token || '',
                            amount: BigInt(parsedJson.amount || 0),
                            destChain: parsedJson.dest_chain,
                            recipient: parsedJson.recipient,
                            sender: parsedJson.sender,
                        });
                    }
                }

            } catch (error) {
                logger.error('Error polling Sui NTT events:', error);
            }

            // 继续轮询
            if (this.isRunning) {
                setTimeout(poll, pollInterval);
            }
        };

        // 开始轮询
        poll();
    }

    /**
     * 監聽 EVM NttManager 事件並 relay 到 Sui
     *
     * 流程:
     * 1. 監聽 EVM NttManager 的 TransferSent 事件
     * 2. 獲取 VAA
     * 3. 調用 Sui NttManager.receive() 完成跨鏈
     */
    async listenEvmNttEvents(): Promise<void> {
        logger.info('Listening for EVM NTT TransferSent events...');

        try {
            // 获取 NTT Manager 地址
            const nttManagerAddress = process.env.NTT_ARBITRUM_MANAGER;
            if (!nttManagerAddress) {
                throw new Error('NTT_ARBITRUM_MANAGER not configured');
            }

            // NTT Manager ABI (仅包含事件和 relay 相关函数)
            const nttManagerAbi = [
                // TransferSent 事件
                'event TransferSent(bytes32 indexed digest, uint256 amount, uint16 indexed destinationChain, uint64 sequence, address indexed sender)',
                // TransferRedeemed 事件
                'event TransferRedeemed(bytes32 indexed digest, uint16 indexed sourceChain, address indexed recipient, uint256 amount)',
                // 完成出队转账
                'function completeOutboundQueuedTransfer(uint64 messageSequence) external payable returns (uint64)',
            ];

            // 创建合约实例
            const nttManager = new ethers.Contract(
                nttManagerAddress,
                nttManagerAbi,
                this.evmProvider
            );

            logger.info('EVM NTT Manager contract connected', {
                address: nttManagerAddress,
            });

            // 监听 TransferSent 事件
            nttManager.on('TransferSent', async (
                digest: any,
                amount: any,
                destinationChain: any,
                sequence: any,
                sender: any,
                event: any
            ) => {
                try {
                    logger.info('Received EVM TransferSent event', {
                        digest: digest.toString(),
                        amount: amount.toString(),
                        destinationChain: destinationChain.toString(),
                        sequence: sequence.toString(),
                        sender: sender,
                        blockNumber: event.blockNumber,
                    });

                    // 如果目标是 Sui，触发 relay
                    if (destinationChain === WORMHOLE_CHAIN_ID.Sui) {
                        await this.relayEvmNttToSui({
                            digest: digest.toString(),
                            sequence: sequence.toBigInt(),
                            amount: amount.toBigInt(),
                            destChain: destinationChain.toString(),
                            sender: sender,
                        });
                    }

                } catch (error) {
                    logger.error('Error processing TransferSent event:', error);
                }
            });

            // 监听 TransferRedeemed 事件
            nttManager.on('TransferRedeemed', async (
                digest: any,
                sourceChain: any,
                recipient: any,
                amount: any,
                event: any
            ) => {
                logger.info('Received EVM TransferRedeemed event', {
                    digest: digest.toString(),
                    sourceChain: sourceChain.toString(),
                    recipient: recipient,
                    amount: amount.toString(),
                    blockNumber: event.blockNumber,
                });
            });

            // 保存 unsubscribe 函数
            this.evmEventUnsubscribe = () => {
                nttManager.removeAllListeners('TransferSent');
                nttManager.removeAllListeners('TransferRedeemed');
            };

            logger.info('EVM NTT event listeners registered successfully');

        } catch (error) {
            logger.error('Failed to start EVM NTT event listening:', error);
            throw error;
        }
    }

    /**
     * Relay Sui → EVM 的 NTT 消息
     *
     * @param event NttOutboundEvent 事件
     */
    async relayNttMessage(event: {
        sequence: bigint;
        token: string;
        amount: bigint;
        destChain: number;
        recipient: string;
        sender: string;
    }): Promise<string> {
        logger.info('Relaying NTT message to destination chain', {
            sequence: event.sequence.toString(),
            destChain: event.destChain,
            amount: event.amount.toString(),
            recipient: event.recipient,
        });

        try {
            // 获取目标链的 NttManager 地址
            const destNttManager = this.nttManagers[event.destChain];
            if (!destNttManager) {
                throw new Error(`NttManager not configured for chain ${event.destChain}`);
            }

            // NTT Manager ABI
            const nttManagerAbi = [
                'function completeOutboundQueuedTransfer(uint64 messageSequence) external payable returns (uint64)',
                'function getOutboundQueuedTransfer(uint64 sequence) external view returns (tuple(uint256 amount, uint64 releaseTime, bool completed))',
            ];

            // 使用钱包签名
            const wallet = new ethers.Wallet(this.config.evmPrivateKey, this.evmProvider);

            // 创建合约实例
            const nttManager = new ethers.Contract(
                destNttManager,
                nttManagerAbi,
                wallet
            );

            // 检查转账是否已完成
            try {
                const transferInfo = await nttManager.getOutboundQueuedTransfer(event.sequence);
                if (transferInfo.completed) {
                    logger.info('Transfer already completed, skipping relay', {
                        sequence: event.sequence.toString(),
                    });
                    return `already_completed_${event.sequence}`;
                }
            } catch {
                // 如果查询失败，继续尝试 relay
            }

            // 估算 gas 费用
            const gasEstimate = await nttManager.completeOutboundQueuedTransfer.estimateGas(event.sequence);
            const gasPrice = await this.evmProvider.getFeeData();
            const gasCost = gasEstimate * (gasPrice.gasPrice || BigInt(0));

            logger.info('Calling completeOutboundQueuedTransfer', {
                sequence: event.sequence.toString(),
                gasEstimate: gasEstimate.toString(),
                gasCost: gasCost.toString(),
            });

            // 调用 completeOutboundQueuedTransfer
            // 注意: 在 burning mode 下，可能不需要发送 ETH
            let tx;
            try {
                tx = await nttManager.completeOutboundQueuedTransfer(event.sequence, {
                    gasLimit: gasEstimate * BigInt(12) / BigInt(10), // 20% buffer
                });
            } catch (error: any) {
                // 如果失败，尝试带 value 调用 (某些实现需要)
                logger.warn('Failed without value, retrying with value', { error: error.message });
                tx = await nttManager.completeOutboundQueuedTransfer(event.sequence, {
                    value: event.amount,
                    gasLimit: gasEstimate * BigInt(12) / BigInt(10),
                });
            }

            // 等待交易确认
            const receipt = await tx.wait();

            logger.info('NTT message relayed successfully', {
                sequence: event.sequence.toString(),
                txHash: receipt.hash,
                blockNumber: receipt.blockNumber,
                status: receipt.status === 1 ? 'success' : 'failed',
            });

            return receipt.hash;

        } catch (error) {
            logger.error('Failed to relay NTT message:', {
                sequence: event.sequence.toString(),
                error,
            });
            throw error;
        }
    }

    /**
     * Relay EVM → Sui 的 NTT 消息
     *
     * @param params 轉账參數
     */
    async relayEvmNttToSui(params: {
        digest: string;
        sequence: bigint;
        amount: bigint;
        destChain: string;
        sender: string;
    }): Promise<string> {
        logger.info('Relaying NTT message from EVM to Sui', {
            digest: params.digest,
            sequence: params.sequence.toString(),
            amount: params.amount.toString(),
            sender: params.sender,
        });

        try {
            // 初始化 Sui 客户端
            await this.initSuiClient();

            if (!this.suiClient || !this.suiKeypair) {
                throw new Error('Sui client or keypair not initialized');
            }

            // 获取 VAA 从 Wormhole API
            const vaa = await this.getVAAFromApi(params.sequence, WORMHOLE_CHAIN_ID.Arbitrum);

            if (!vaa || vaa.length === 0) {
                throw new Error('Failed to retrieve VAA from Wormhole');
            }

            // 获取 Sui NttManager 地址
            const suiNttManager = this.nttManagers[WORMHOLE_CHAIN_ID.Sui];
            if (!suiNttManager) {
                throw new Error('Sui NttManager not configured');
            }

            // 动态导入 Sui SDK
            const { Transaction } = require('@mysten/sui/transactions');

            // 构建 Sui PTB 来完成跨链转账
            const tx = new Transaction();

            // 调用 NttManager.redeem() 来完成转账
            // 参数: vaa (signed VAA bytes)
            tx.moveCall({
                target: `${suiNttManager}::ntt_manager::redeem`,
                arguments: [
                    // NttManager object
                    tx.object(suiNttManager),
                    // VAA bytes
                    tx.pure.u8Array(Array.from(vaa)),
                ],
            });

            logger.info('Built Sui redeem PTB', {
                target: `${suiNttManager}::ntt_manager::redeem`,
                vaaLength: vaa.length,
            });

            // 发送交易
            const result = await this.suiClient.signAndExecuteTransaction({
                transaction: tx,
                signer: this.suiKeypair,
                options: {
                    showEffects: true,
                    showEvents: true,
                },
                requestType: 'WaitForLocalExecution',
            });

            logger.info('Sui redeem transaction submitted', {
                txHash: result.digest,
                status: result.effects?.status?.status,
            });

            // 检查交易状态
            if (result.effects?.status?.status !== 'success') {
                const errorMsg = result.effects?.status?.error || 'Unknown error';
                throw new Error(`Sui redeem transaction failed: ${errorMsg}`);
            }

            // === Yield 模式处理：跨链完成后的 Navi 存款 ===
            const messageId = `ntt_evm_${params.sequence}`;
            const receipt = await this.getTransferReceiptByMessageId(messageId);

            if (receipt && receipt.yieldMode === 'yield') {
                // 从 objectChanges 中提取刚 mint 出来的 USDC Coin object ID
                const mintedCoin = result.objectChanges?.find(
                    (change: any) =>
                        change.type === 'created' &&
                        change.objectType?.includes('Coin') &&
                        change.objectType?.includes('USDC')
                );

                if (mintedCoin?.objectId) {
                    await this.depositToNavi({
                        coinObjectId: mintedCoin.objectId,
                        amount: params.amount,
                        recipient: receipt.recipient,
                        messageId,
                    });
                } else {
                    logger.warn('Yield mode enabled but could not find minted USDC coin in objectChanges', {
                        objectChanges: result.objectChanges,
                        messageId,
                    });
                }
            }

            return result.digest;

        } catch (error) {
            logger.error('Failed to relay EVM NTT message to Sui:', {
                sequence: params.sequence.toString(),
                error,
            });
            throw error;
        }
    }

    /**
     * 从 Wormhole API 获取 VAA
     */
    private async getVAAFromApi(sequence: bigint, sourceChain: number): Promise<Uint8Array> {
        const wormholeApiUrl = process.env.WORMHOLE_RPC_URL || 'https://wormhole-v2-mainnet-api.securenode.xyz';

        try {
            // 构建 API URL
            // Wormhole VAA API: /v1/signed_vaa/{emitterChain}/{emitterAddress}/{sequence}
            const emitterAddress = process.env.NTT_ARBITRUM_MANAGER?.toLowerCase().replace('0x', '') || '';
            const apiUrl = `${wormholeApiUrl}/v1/signed_vaa/${sourceChain}/${emitterAddress}/${sequence}`;

            logger.info('Fetching VAA from Wormhole API', {
                url: apiUrl,
                sequence: sequence.toString(),
            });

            const response = await fetch(apiUrl);

            if (!response.ok) {
                if (response.status === 404) {
                    logger.warn('VAA not found yet, may need to wait for guardian observation');
                    return new Uint8Array();
                }
                throw new Error(`Wormhole API error: ${response.status}`);
            }

            // VAA API 返回 base64 编码的数据
            const data = await response.json() as { vaaBytes?: string };
            const vaaBase64 = data.vaaBytes;

            if (!vaaBase64) {
                throw new Error('No vaaBytes in response');
            }

            // 解码 base64
            const vaaBuffer = Buffer.from(vaaBase64, 'base64');
            return new Uint8Array(vaaBuffer);

        } catch (error) {
            logger.error('Failed to fetch VAA from Wormhole API:', {
                sequence: sequence.toString(),
                error,
            });
            return new Uint8Array();
        }
    }

    // ============================================================================
    // NTT Rate Limit Management
    // ============================================================================

    /**
     * 查詢目標鏈的速率限制狀態
     */
    async getNttRateLimitStatus(chainId: number): Promise<{
        maxOutflow: bigint;
        currentOutflow: bigint;
        windowStart: bigint;
        windowSecs: bigint;
    }> {
        // TODO: 實現實際的查詢邏輯
        // 
        // const nttManager = new ethers.Contract(
        //     this.config.nttManagerAddress,
        //     NTT_MANAGER_ABI,
        //     this.evmProvider
        // );
        // 
        // const capacity = await nttManager.getCurrentInboundCapacity(chainId);
        // return capacity;

        return {
            maxOutflow: BigInt(100_000_000_000),
            currentOutflow: BigInt(0),
            windowStart: BigInt(Math.floor(Date.now() / 1000)),
            windowSecs: BigInt(3600),
        };
    }

    /**
     * 取消超時的排隊轉賬
     */
    async completeQueuedTransfers(): Promise<string[]> {
        logger.info('Checking for queued transfers to complete...');

        // TODO: 實現實際的完成排隊轉賬邏輯
        // 
        // 1. 查詢 NttManager 的排隊轉账
        // const queuedTransfers = await this.getQueuedTransfers();
        // 
        // 2. 遍歷並完成超時的轉账
        // const completed: string[] = [];
        // for (const transfer of queuedTransfers) {
        //     if (this.isTransferTimedOut(transfer)) {
        //         const txHash = await this.completeQueuedTransfer(transfer.sequence);
        //         completed.push(txHash);
        //     }
        // }

        logger.info('Queued transfers check completed');
        return [];
    }

    // ============================================================================
    // Navi Yield 集成
    // ============================================================================

    /**
     * 根据 messageId 查询转账记录
     */
    private async getTransferReceiptByMessageId(messageId: string): Promise<any> {
        try {
            const redis = RedisService.getInstance();
            const key = `ntt:receipt:${messageId}`;
            const data = await redis.get(key);
            return data ? JSON.parse(data) : null;
        } catch (error) {
            logger.warn('Failed to get transfer receipt from Redis:', error);
            return null;
        }
    }

    /**
     * 将 USDC 存入 Navi 获取收益
     *
     * 在跨链完成（USDC 已 mint 到用户地址）后执行
     * 注意：存入 Navi 后凭证 nUSDC 归 Relayer 地址持有
     */
    private async depositToNavi(params: {
        coinObjectId: string;
        amount: bigint;
        recipient: string;
        messageId: string;
    }): Promise<void> {
        try {
            // 动态导入 Navi SDK 和 Sui Transaction
            const { Transaction } = require('@mysten/sui/transactions');
            const { depositCoinPTB } = require('@naviprotocol/lending');

            // Navi nUSDC 的 coinType（主网）
            const USDC_COIN_TYPE =
                '0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC';

            // 构建存款 PTB
            const tx = new Transaction();

            depositCoinPTB(tx, 'nUSDC', { objectId: params.coinObjectId }, {
                amount: Number(params.amount),
                market: 'main',
            });

            logger.info('Built Navi deposit PTB', {
                coinObjectId: params.coinObjectId,
                amount: params.amount.toString(),
                recipient: params.recipient,
            });

            // 执行存款
            const result = await this.suiClient.signAndExecuteTransaction({
                transaction: tx,
                signer: this.suiKeypair,
                options: {
                    showEffects: true,
                    showEvents: true,
                },
                requestType: 'WaitForLocalExecution',
            });

            if (result.effects?.status?.status === 'success') {
                logger.info('Navi deposit successful', {
                    txHash: result.digest,
                    messageId: params.messageId,
                    originalRecipient: params.recipient,
                    note: 'nUSDC retained by relayer address',
                });
            } else {
                logger.error('Navi deposit failed', {
                    error: result.effects?.status?.error,
                    messageId: params.messageId,
                });
            }
        } catch (error) {
            logger.error('Failed to deposit to Navi:', {
                error,
                messageId: params.messageId,
                coinObjectId: params.coinObjectId,
            });
            // 不抛出错误：跨链已完成，Navi 存款失败不应阻断主流程
        }
    }
}

export default RelayerService;
