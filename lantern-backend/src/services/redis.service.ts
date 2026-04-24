/**
 * Redis Service - Redis 緩存服務
 */
import Redis from 'ioredis';
import { config } from '../config';
import { logger } from './logger.service';

export class RedisService {
  private static instance: RedisService;
  private client: Redis | null = null;

  private constructor() {}

  public static getInstance(): RedisService {
    if (!RedisService.instance) {
      RedisService.instance = new RedisService();
    }
    return RedisService.instance;
  }

  public async connect(): Promise<void> {
    try {
      this.client = new Redis({
        host: config.redis.host,
        port: config.redis.port,
        password: config.redis.password,
        retryStrategy: (times: number) => {
          const delay = Math.min(times * 50, 2000);
          return delay;
        },
      });

      this.client.on('connect', () => {
        logger.info('Redis connected');
      });

      this.client.on('error', (err: Error) => {
        logger.error('Redis error:', err);
      });

      await this.client.ping();
    } catch (error) {
      logger.error('Redis connection failed:', error);
      throw error;
    }
  }

  public async disconnect(): Promise<void> {
    if (this.client) {
      await this.client.quit();
    }
  }

  public getClient(): Redis {
    if (!this.client) {
      logger.warn('Redis client not initialized, creating lazy client');
      // Return a mock client or create a lazy connection
      this.client = new Redis({
        host: config.redis.host,
        port: config.redis.port,
        password: config.redis.password,
        lazyConnect: true,
        maxRetriesPerRequest: 1,
        retryStrategy: () => null, // Disable retries
        connectTimeout: 5000,
      });
      
      // Don't wait for connection - just log warning
      this.client.connect().catch((err) => {
        logger.warn('Redis lazy connect failed (non-blocking)', { error: err.message });
      });
    }
    return this.client;
  }

  // 便捷方法

  public async get(key: string): Promise<string | null> {
    try {
      return await this.getClient().get(key);
    } catch (error) {
      logger.warn('Redis get failed, returning null', { key, error });
      return null;
    }
  }

  public async set(key: string, value: string, ttlSeconds?: number): Promise<void> {
    try {
      if (ttlSeconds) {
        await this.getClient().setex(key, ttlSeconds, value);
      } else {
        await this.getClient().set(key, value);
      }
    } catch (error) {
      logger.warn('Redis set failed', { key, error });
    }
  }

  public async del(key: string): Promise<void> {
    try {
      await this.getClient().del(key);
    } catch (error) {
      logger.warn('Redis del failed', { key, error });
    }
  }

  public async incr(key: string): Promise<number> {
    try {
      return await this.getClient().incr(key);
    } catch (error) {
      logger.warn('Redis incr failed, returning 0', { key, error });
      return 0;
    }
  }

  public async expire(key: string, seconds: number): Promise<void> {
    await this.getClient().expire(key, seconds);
  }
}
