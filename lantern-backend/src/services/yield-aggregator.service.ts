/**
 * Yield Aggregator - 收益聚合服務
 * 負責從 Navi Protocol 獲取收益數據
 */
import axios from 'axios';
import { config } from '../config';
import { RedisService } from './redis.service';
import { logger } from './logger.service';

export interface NaviPoolData {
  poolAddress: string;
  apy: number;
  tvl: number;
  tokenA: string;
  tokenB: string;
}

export interface YieldInfo {
  apy: number;
  source: string;
  lastUpdated: number;
  totalValueLocked: string;
}

export interface YieldCalculation {
  daily: string;
  weekly: string;
  monthly: string;
  yearly: string;
}

export class YieldAggregator {
  private cache: Map<string, { data: YieldInfo; timestamp: number }> = new Map();
  private readonly CACHE_TTL = 60 * 1000; // 1 分鐘
  private redis: RedisService;

  constructor() {
    this.redis = RedisService.getInstance();
  }

  /**
   * 獲取當前收益信息
   */
  async getCurrentYield(): Promise<YieldInfo> {
    const cached = this.cache.get('navi-usdc');
    if (cached && Date.now() - cached.timestamp < this.CACHE_TTL) {
      return cached.data;
    }

    try {
      // 從 Navi API 獲取
      const response = await axios.get<NaviPoolData>(
        `${config.navi.apiUrl}/pools/usdc`,
        {
          timeout: 5000,
        }
      );

      const yieldInfo: YieldInfo = {
        apy: response.data.apy / 100, // 轉換為小數
        source: 'Navi Protocol',
        lastUpdated: Date.now(),
        totalValueLocked: response.data.tvl.toString(),
      };

      this.cache.set('navi-usdc', { data: yieldInfo, timestamp: Date.now() });

      // 同步到 Redis
      await this.redis.set('yield:navi-usdc', JSON.stringify(yieldInfo), 300);

      return yieldInfo;
    } catch (error) {
      logger.error('Failed to fetch yield data:', error);

      // 嘗試從 Redis 獲取
      const cached = await this.redis.get('yield:navi-usdc');
      if (cached) {
        return JSON.parse(cached);
      }

      // 返回默認值
      return {
        apy: 0.05, // 5% 默認 APY
        source: 'Navi Protocol',
        lastUpdated: Date.now(),
        totalValueLocked: '0',
      };
    }
  }

  /**
   * 計算預估收益
   */
  async calculateProjectedYield(
    principal: bigint,
    days: number,
    apy?: number
  ): Promise<YieldCalculation> {
    const yieldInfo = apy ? { apy } : await this.getCurrentYield();

    const dailyRate = yieldInfo.apy / 365;
    const weeklyRate = yieldInfo.apy / 52;
    const monthlyRate = yieldInfo.apy / 12;

    const daily = (principal * BigInt(Math.floor(dailyRate * 10000)) / BigInt(10000)) * BigInt(days);
    const weekly = principal * BigInt(Math.floor(weeklyRate * 10000)) / BigInt(10000);
    const monthly = principal * BigInt(Math.floor(monthlyRate * 10000)) / BigInt(10000);
    const yearly = principal * BigInt(Math.floor(yieldInfo.apy * 10000)) / BigInt(10000);

    return {
      daily: daily.toString(),
      weekly: weekly.toString(),
      monthly: monthly.toString(),
      yearly: yearly.toString(),
    };
  }

  /**
   * 計算用戶實際收益
   */
  async calculateUserYield(
    userShares: bigint,
    totalShares: bigint,
    totalAssets: bigint
  ): Promise<{ principal: string; accruedYield: string; totalValue: string }> {
    if (totalShares === 0n) {
      return {
        principal: '0',
        accruedYield: '0',
        totalValue: '0',
      };
    }

    // 計算用戶本金份額
    const userShareRatio = Number(userShares) / Number(totalShares);
    const principal = BigInt(Math.floor(Number(totalAssets) * userShareRatio));

    // 從 Navi 獲取當前餘額
    const yieldInfo = await this.getCurrentYield();

    // 計算利息（簡化版本）
    const dailyRate = yieldInfo.apy / 365 / 100; // 轉換為每日小數
    const daysSinceDeposit = 1; // 簡化：假設每天計算
    const accruedYield = principal * BigInt(Math.floor(dailyRate * 10000 * daysSinceDeposit)) / BigInt(10000);

    const totalValue = principal + accruedYield;

    return {
      principal: principal.toString(),
      accruedYield: accruedYield.toString(),
      totalValue: totalValue.toString(),
    };
  }
}
