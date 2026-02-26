/**
 * Deposit 路由 - 存款相關接口
 */
import { Router, Request, Response } from 'express';
import { GasSponsorService } from '../services/gas-sponsor.service';
import { AntiSybilEngine } from '../services/anti-sybil.service';
import { logger } from '../services/logger.service';

const router = Router();

const gasSponsorService = new GasSponsorService();
const antiSybilEngine = new AntiSybilEngine();

/**
 * POST /api/v1/deposit/sponsor
 * 請求 Gas 代付
 */
router.post('/sponsor', async (req: Request, res: Response) => {
  try {
    const { userAddress, unsignedPTB, depositAmount } = req.body;

    // 1. 風控檢查
    const clientIP = req.ip || req.socket.remoteAddress || 'unknown';
    const sybilResult = await antiSybilEngine.check(userAddress, depositAmount, clientIP);

    if (!sybilResult.allowed) {
      return res.status(403).json({
        success: false,
        error: sybilResult.reason,
      });
    }

    // 2. 請求 Gas 代付
    const sponsoredTx = await gasSponsorService.sponsorTransaction({
      userAddress,
      unsignedPTB,
      depositAmount,
    });

    res.json({
      success: true,
      data: {
        txBytes: sponsoredTx.txBytes,
        sponsorSignature: sponsoredTx.sponsorSignature,
        backendSignature: sponsoredTx.backendSignature,
        gasUsed: sponsoredTx.gasUsed,
      },
    });
  } catch (error) {
    logger.error('Deposit sponsor error:', error);
    res.status(500).json({
      success: false,
      error: 'Internal server error',
    });
  }
});

export default router;
