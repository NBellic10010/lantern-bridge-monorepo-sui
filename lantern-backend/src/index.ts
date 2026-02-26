/**
 * Lantern Backend - 主入口文件
 * 跨鏈生息金庫後端服務
 */
import express, { Express, Request, Response, NextFunction } from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';
import dotenv from 'dotenv';

// 路由
import apiRouter from './routes/api.routes';

// 服務
import { logger } from './services/logger.service';
import { RedisService } from './services/redis.service';
import { DatabaseService } from './services/database.service';

// 配置
import { config } from './config';

// 加載環境變量
dotenv.config();

const app: Express = express();

// ============================================================================
// 中間件

// 安全頭部
app.use(helmet());

// CORS
app.use(cors({
  origin: config.corsOrigin,
  credentials: true,
}));

// 請求日誌
app.use(morgan('combined', {
  stream: {
    write: (message: string) => {
      logger.info(message.trim());
    },
  },
}));

// JSON 解析
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// ============================================================================
// 路由

app.get('/health', (_req: Request, res: Response) => {
  res.json({ status: 'ok', timestamp: Date.now() });
});

app.use('/api/v1', apiRouter);

// ============================================================================
// 錯誤處理

app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
  logger.error('Unhandled error:', err);
  res.status(500).json({
    success: false,
    error: 'Internal server error',
  });
});

// ============================================================================
// 啟動服務

async function startServer() {
  try {
    // 初始化數據庫
    await DatabaseService.getInstance().connect();
    logger.info('Database connected');

    // 初始化 Redis
    await RedisService.getInstance().connect();
    logger.info('Redis connected');

    // 啟動 HTTP 服務
    app.listen(config.port, () => {
      logger.info(`Server running on port ${config.port}`);
      logger.info(`Environment: ${config.env}`);
    });
  } catch (error) {
    logger.error('Failed to start server:', error);
    process.exit(1);
  }
}

// 優雅關閉
process.on('SIGTERM', async () => {
  logger.info('SIGTERM received, shutting down...');
  await RedisService.getInstance().disconnect();
  await DatabaseService.getInstance().disconnect();
  process.exit(0);
});

startServer();

export default app;
