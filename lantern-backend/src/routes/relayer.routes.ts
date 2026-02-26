/**
 * Relayer API Routes - 跨鏈中繼 API 路由
 */
import { Router, Request, Response } from 'express';
import { RelayerService } from '../services/relayer.service';
import { logger } from '../services/logger.service';

const router = Router();
const relayerService = RelayerService.getInstance();

// ============================================================================
// 路由

/**
 * GET /relayer/status
 * 獲取 Relayer 狀態
 */
router.get('/status', (_req: Request, res: Response) => {
    try {
        const status = relayerService.getStatus();
        res.json({
            success: true,
            data: status,
        });
    } catch (error) {
        logger.error('Error getting relayer status:', error);
        res.status(500).json({
            success: false,
            error: 'Failed to get status',
        });
    }
});

/**
 * POST /relayer/process
 * 手動觸發消息處理
 */
router.post('/process', async (req: Request, res: Response) => {
    try {
        const { vaa } = req.body;
        
        if (!vaa) {
            return res.status(400).json({
                success: false,
                error: 'Missing VAA',
            });
        }
        
        const txDigest = await relayerService.processMessage(vaa);
        
        res.json({
            success: true,
            data: {
                txDigest,
            },
        });
    } catch (error) {
        logger.error('Error processing message:', error);
        res.status(500).json({
            success: false,
            error: 'Failed to process message',
        });
    }
});

/**
 * POST /relayer/start
 * 啟動 Relayer 服務
 */
router.post('/start', async (_req: Request, res: Response) => {
    try {
        await relayerService.start();
        
        res.json({
            success: true,
            message: 'Relayer started',
        });
    } catch (error) {
        logger.error('Error starting relayer:', error);
        res.status(500).json({
            success: false,
            error: 'Failed to start relayer',
        });
    }
});

/**
 * POST /relayer/stop
 * 停止 Relayer 服務
 */
router.post('/stop', async (_req: Request, res: Response) => {
    try {
        await relayerService.stop();
        
        res.json({
            success: true,
            message: 'Relayer stopped',
        });
    } catch (error) {
        logger.error('Error stopping relayer:', error);
        res.status(500).json({
            success: false,
            error: 'Failed to stop relayer',
        });
    }
});

/**
 * GET /relayer/health
 * Relayer 健康檢查
 */
router.get('/health', (_req: Request, res: Response) => {
    res.json({
        success: true,
        status: 'healthy',
        timestamp: Date.now(),
    });
});

export default router;
