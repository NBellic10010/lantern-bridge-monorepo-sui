/**
 * Anti-Sybil Engine - 防女巫風控引擎
 * 負責驗證用戶資格，防止女巫攻擊
 */
import { config } from '../config';
import { DatabaseService } from './database.service';
import { RedisService } from './redis.service';
import { logger } from './logger.service';

export interface CheckResult {
  allowed: boolean;
  reason?: 'MIN_DEPOSIT_NOT_MET' | 'DAILY_LIMIT_EXCEEDED' | 'IP_BLOCKED' | 'INVALID_REQUEST';
  retryAfter?: number;
}

export interface SybilCheckRule {
  minDepositAmount: number;
  maxDailySponsorPerAddress: number;
  maxDailySponsorPerIP: number;
}

export class AntiSybilEngine {
  private rules: SybilCheckRule;
  private db: DatabaseService;
  private redis: RedisService;

  constructor() {
    this.rules = {
      minDepositAmount: config.sybil.minDepositAmount,
      maxDailySponsorPerAddress: config.sybil.maxDailySponsorPerAddress,
      maxDailySponsorPerIP: config.sybil.maxDailySponsorPerIP,
    };
    this.db = DatabaseService.getInstance();
    this.redis = RedisService.getInstance();
  }

  /**
   * 執行風控檢查
   */
  async check(
    userAddress: string,
    depositAmount: number,
    clientIP: string
  ): Promise<CheckResult> {
    logger.info('Running sybil check', { userAddress, depositAmount, clientIP });

    // 1. 檢查存款金額
    if (depositAmount < this.rules.minDepositAmount) {
      await this.logBlocked(userAddress, clientIP, 'MIN_DEPOSIT_NOT_MET');
      return { allowed: false, reason: 'MIN_DEPOSIT_NOT_MET' };
    }

    // 2. 檢查 Redis 緩存（高性能）
    const dateKey = this.getDateKey();
    const addressKey = `sponsor:${userAddress}:${dateKey}`;
    const ipKey = `sponsor:ip:${clientIP}:${dateKey}`;

    if (await this.redis.get(addressKey)) {
      await this.logBlocked(userAddress, clientIP, 'DAILY_LIMIT_EXCEEDED');
      return { allowed: false, reason: 'DAILY_LIMIT_EXCEEDED' };
    }

    // 3. 檢查 IP 限制
    const ipCount = await this.redis.incr(ipKey);
    if (ipCount === 1) {
      await this.redis.expire(ipKey, 86400); // 24小時過期
    }
    if (ipCount > this.rules.maxDailySponsorPerIP) {
      await this.logBlocked(userAddress, clientIP, 'IP_BLOCKED');
      return { allowed: false, reason: 'IP_BLOCKED' };
    }

    // 4. 持久化記錄到 PostgreSQL
    await this.db.client.sponsorRecord.create({
      data: {
        userAddress,
        depositAmount,
        ipAddress: clientIP,
        userAgent: '',
      },
    });

    // 5. 寫入 Redis 緩存
    await this.redis.set(addressKey, '1', 86400);

    logger.info('Sybil check passed', { userAddress });

    return { allowed: true };
  }

  /**
   * 記錄攔截日誌
   */
  private async logBlocked(userAddress: string, ip: string, reason: string) {
    logger.warn('Sybil check blocked', { userAddress, ip, reason });

    await this.db.client.sybilBlock.create({
      data: {
        userAddress,
        ipAddress: ip,
        reason,
      },
    });
  }

  /**
   * 獲取當前日期鍵
   */
  private getDateKey(): string {
    const now = new Date();
    return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
  }
}
