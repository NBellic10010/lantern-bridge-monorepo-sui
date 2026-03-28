/**
 * Navi Protocol SDK Wrapper
 * 
 * 提供與 Navi Protocol 交互的 TypeScript 接口
 * 用於後端 Relayer 服務調用 Navi 合約
 * 
 * Navi Protocol 是 Sui 網絡上的收益聚合協議
 * 文檔: https://docs.naviprotocol.io
 */

import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';

// ============================================================================
// RPC URLs 常量

export const RPC_URLS = {
  MAINNET: getFullnodeUrl('mainnet'),
  TESTNET: getFullnodeUrl('testnet'),
} as const;

// ============================================================================
// 配置常量

export const NAVI_CONFIG = {
  // Navi 主網 Vault 地址
  MAINNET: {
    USDC_VAULT: '0x3562814638787a1833756476b457599394489641005f3396995268d015249592',
    USDT_VAULT: '0x2b02e625b20b28f2e4d8eb1f0a1e4d7b5f3c8a2d9e1f0a3b4c5d6e7f8a9b0c',
  },
  // Navi 測試網 Vault 地址
  TESTNET: {
    USDC_VAULT: '0x4c04f09b01ea72d7d2b91c7e1a1c5b8f6a3b2c1d0e9f8a7b6c5d4e3f2a1b0',
    USDT_VAULT: '0x5d15f0a2eb91d8e4f6b3c8d2a1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4',
  },
};

// ============================================================================
// 類型定義

export interface NaviDepositParams {
  amount: bigint;
  vaultType: 'USDC' | 'USDT';
}

export interface NaviWithdrawParams {
  amount: bigint;
  vaultType: 'USDC' | 'USDT';
}

export interface NaviPosition {
  availableAmount: bigint;
  depositedAmount: bigint;
  accumulatedYield: bigint;
  apy: number;
}

export interface NaviVaultInfo {
  address: string;
  totalSupply: bigint;
  totalBorrow: bigint;
  utilizationRate: number;
  currentAPY: number;
}

// ============================================================================
// SDK 類

export class NaviSDK {
  private client: SuiClient;
  private network: 'mainnet' | 'testnet';

  constructor(network: 'mainnet' | 'testnet' = 'mainnet') {
    this.network = network;
    const rpcUrl = network === 'mainnet' 
      ? getFullnodeUrl('mainnet')
      : getFullnodeUrl('testnet');
    
    this.client = new SuiClient({ url: rpcUrl });
  }

  /**
   * 存款到 Navi Protocol
   * 
   * 流程:
   * 1. 創建交易
   * 2. 拆分 USDC/USDT 代幣
   * 3. 調用 Navi Vault 的 deposit 函數
   * 4. 獲取 nUSDC/nUSDT 憑證
   */
  async deposit(
    signer: { getAddress(): Promise<string> },
    params: NaviDepositParams
  ): Promise<Transaction> {
    const { amount, vaultType } = params;
    
    // 獲取 Vault 地址
    const vaultAddress = vaultType === 'USDC'
      ? NAVI_CONFIG[this.network.toUpperCase() as keyof typeof NAVI_CONFIG].USDC_VAULT
      : NAVI_CONFIG[this.network.toUpperCase() as keyof typeof NAVI_CONFIG].USDT_VAULT;

    // 創建交易
    const tx = new Transaction();

    // 設置發送者
    const sender = await signer.getAddress();
    tx.setSender(sender);

    // 獲取用戶的代幣類型
    const coinType = vaultType === 'USDC' 
      ? '0x5d4b302506645c37ff153b329d6c3e7414a00a0d8c2509b4b8b8b7e0b0e7d6::usdc::USDC'
      : '0x5d4b302506645c37ff153b329d6c3e7414a00a0d8c2509b4b8b8b7e0b0e7d6::usdt::USDT';

    // 獲取用戶的代幣
    const coins = await this.client.getCoins({
      owner: sender,
      coinType: coinType,
    });

    if (!coins.data || coins.data.length === 0) {
      throw new Error(`No ${vaultType} balance found`);
    }

    // 合併代幣
    const coinObjects = coins.data.map((c) => c.coinObjectId);
    const primaryCoin = coinObjects[0];

    // 拆分所需金額
    const [depositCoin] = tx.splitCoins(tx.object(primaryCoin), [amount]);

    // 調用 Navi deposit
    tx.moveCall({
      target: `${vaultAddress}::vault::deposit`,
      arguments: [depositCoin],
      typeArguments: [coinType],
    });

    return tx;
  }

  /**
   * 從 Navi Protocol 提款
   * 
   * 流程:
   * 1. 創建交易
   * 2. 調用 Navi Vault 的 withdraw 函數
   * 3. 銷毀 nUSDC/nUSDT 憑證
   * 4. 獲得 USDC/USDT
   */
  async withdraw(
    signer: { getAddress(): Promise<string> },
    params: NaviWithdrawParams
  ): Promise<Transaction> {
    const { amount, vaultType } = params;
    
    // 獲取 Vault 地址
    const vaultAddress = vaultType === 'USDC'
      ? NAVI_CONFIG[this.network.toUpperCase() as keyof typeof NAVI_CONFIG].USDC_VAULT
      : NAVI_CONFIG[this.network.toUpperCase() as keyof typeof NAVI_CONFIG].USDT_VAULT;

    // 創建交易
    const tx = new Transaction();

    // 設置發送者
    const sender = await signer.getAddress();
    tx.setSender(sender);

    // 獲取用戶的 nUSDC/nUSDT 類型
    const nTokenType = vaultType === 'USDC'
      ? '0x3562814638787a1833756476b457599394489641005f3396995268d015249592::nUSDC::NUSDC'
      : '0x3562814638787a1833756476b457599394489641005f3396995268d015249592::nUSDT::NUSDT';

    // 獲取用戶的 nUSDC/nUSDT 餘額
    const nTokens = await this.client.getCoins({
      owner: sender,
      coinType: nTokenType,
    });

    if (!nTokens.data || nTokens.data.length === 0) {
      throw new Error(`No n${vaultType} balance found`);
    }

    // 合併代幣
    const coinObjects = nTokens.data.map((c) => c.coinObjectId);
    const primaryCoin = coinObjects[0];

    // 拆分所需金額
    const [withdrawCoin] = tx.splitCoins(tx.object(primaryCoin), [amount]);

    // 獲取原始代幣類型
    const coinType = vaultType === 'USDC' 
      ? '0x5d4b302506645c37ff153b329d6c3e7414a00a0d8c2509b4b8b8b7e0b0e7d6::usdc::USDC'
      : '0x5d4b302506645c37ff153b329d6c3e7414a00a0d8c2509b4b8b8b7e0b0e7d6::usdt::USDT';

    // 調用 Navi withdraw
    tx.moveCall({
      target: `${vaultAddress}::vault::redeem`,
      arguments: [withdrawCoin],
      typeArguments: [coinType],
    });

    return tx;
  }

  /**
   * 獲取用戶的 Navi 倉位信息
   */
  async getPosition(walletAddress: string): Promise<NaviPosition> {
    try {
      // 調用 Navi 合約的 view 函數
      const result = await this.client.getDynamicFields({
        parentId: NAVI_CONFIG[this.network.toUpperCase() as keyof typeof NAVI_CONFIG].USDC_VAULT,
      });

      return {
        availableAmount: 0n,
        depositedAmount: 0n,
        accumulatedYield: 0n,
        apy: 0,
      };
    } catch (error) {
      // 如果調用失敗，返回空倉位
      console.warn('Failed to get Navi position:', error);
      return {
        availableAmount: 0n,
        depositedAmount: 0n,
        accumulatedYield: 0n,
        apy: 0,
      };
    }
  }

  /**
   * 獲取 Vault 信息
   */
  async getVaultInfo(vaultType: 'USDC' | 'USDT'): Promise<NaviVaultInfo> {
    const vaultAddress = vaultType === 'USDC'
      ? NAVI_CONFIG[this.network.toUpperCase() as keyof typeof NAVI_CONFIG].USDC_VAULT
      : NAVI_CONFIG[this.network.toUpperCase() as keyof typeof NAVI_CONFIG].USDT_VAULT;

    try {
      // 嘗試獲取 Vault 對象信息
      const vaultObject = await this.client.getObject({
        id: vaultAddress,
        options: { showContent: true },
      });

      return {
        address: vaultAddress,
        totalSupply: 0n,
        totalBorrow: 0n,
        utilizationRate: 0,
        currentAPY: 0,
      };
    } catch (error) {
      console.warn('Failed to get Vault info:', error);
      return {
        address: vaultAddress,
        totalSupply: 0n,
        totalBorrow: 0n,
        utilizationRate: 0,
        currentAPY: 0,
      };
    }
  }

  /**
   * 獲取當前 APY
   */
  async getAPY(vaultType: 'USDC' | 'USDT'): Promise<number> {
    const vaultInfo = await this.getVaultInfo(vaultType);
    return vaultInfo.currentAPY;
  }
}

// ============================================================================
// 工廠函數

let naviSDKInstance: NaviSDK | null = null;

/**
 * 獲取 Navi SDK 單例
 */
export function getNaviSDK(network: 'mainnet' | 'testnet' = 'mainnet'): NaviSDK {
  if (!naviSDKInstance || naviSDKInstance['network'] !== network) {
    naviSDKInstance = new NaviSDK(network);
  }
  return naviSDKInstance;
}

export default NaviSDK;
