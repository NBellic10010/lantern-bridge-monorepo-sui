/**
 * RPC Load Balancer - RPC 負載均衡服務
 * 負責管理多個 Sui RPC 節點
 */
import { config } from '../config';
import { logger } from './logger.service';

interface RPCNode {
  url: string;
  weight: number;
  healthy: boolean;
  latency: number;
  failures: number;
}

export class RPCLoadBalancer {
  private nodes: RPCNode[];

  constructor() {
    // 初始化 RPC 節點
    this.nodes = [
      { url: config.sui.rpcUrl, weight: 2, healthy: true, latency: 0, failures: 0 },
      { url: 'https://rpc.mainnet.sui.io', weight: 1, healthy: true, latency: 0, failures: 0 },
      { url: 'https://quicknode.rpc.sui', weight: 1, healthy: true, latency: 0, failures: 0 },
    ];
  }

  /**
   * 執行 RPC 請求
   */
  async execute<T>(fn: (rpc: string) => Promise<T>): Promise<T> {
    // 選擇最健康的節點
    const sorted = [...this.nodes]
      .filter(n => n.healthy)
      .sort((a, b) => {
        const scoreA = a.latency * (1 / a.weight);
        const scoreB = b.latency * (1 / b.weight);
        return scoreA - scoreB;
      });

    const errors: Error[] = [];

    for (const node of sorted) {
      try {
        const start = Date.now();
        const result = await fn(node.url);
        node.latency = Date.now() - start;
        node.failures = 0;
        return result;
      } catch (error) {
        node.failures++;
        errors.push(error as Error);

        if (node.failures >= 3) {
          node.healthy = false;
          logger.warn(`RPC node ${node.url} marked unhealthy after ${node.failures} failures`);
        }
      }
    }

    // 所有節點都失敗，嘗試恢復最舊的節點
    if (errors.length > 0) {
      const oldestFailed = this.nodes.find(n => !n.healthy && n.failures > 0);
      if (oldestFailed) {
        oldestFailed.healthy = true;
        oldestFailed.failures = 0;
        logger.info(`Recovered RPC node ${oldestFailed.url}`);
      }
    }

    throw new Error(`All RPC nodes failed: ${errors.map(e => e.message).join(', ')}`);
  }

  /**
   * 獲取當前健康的節點數量
   */
  getHealthyCount(): number {
    return this.nodes.filter(n => n.healthy).length;
  }

  /**
   * 獲取節點狀態
   */
  getNodeStatus(): Array<{ url: string; healthy: boolean; latency: number }> {
    return this.nodes.map(n => ({
      url: n.url,
      healthy: n.healthy,
      latency: n.latency,
    }));
  }
}
