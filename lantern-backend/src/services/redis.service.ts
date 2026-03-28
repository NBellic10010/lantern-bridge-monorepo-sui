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
      throw new Error('Redis client not initialized');
    }
    return this.client;
  }

  // 便捷方法

  public async get(key: string): Promise<string | null> {
    return this.getClient().get(key);
  }

  public async set(key: string, value: string, ttlSeconds?: number): Promise<void> {
    if (ttlSeconds) {
      await this.getClient().setex(key, ttlSeconds, value);
    } else {
      await this.getClient().set(key, value);
    }
  }

  public async del(key: string): Promise<void> {
    await this.getClient().del(key);
  }

  public async incr(key: string): Promise<number> {
    return this.getClient().incr(key);
  }

  public async expire(key: string, seconds: number): Promise<void> {
    await this.getClient().expire(key, seconds);
  }
}
