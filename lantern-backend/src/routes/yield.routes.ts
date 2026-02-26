/**
 * Yield 路由 - 收益相關接口
 */
import { Router, Request, Response } from 'express';
import { YieldAggregator } from '../services/yield-aggregator.service';

const router = Router();

const yieldAggregator = new YieldAggregator();

/**
 * GET /api/v1/yield/current
 * 獲取當前收益
 */
router.get('/current', async (_req: Request, res: Response) => {
  try {
    const yieldInfo = await yieldAggregator.getCurrentYield();

    res.json({
      success: true,
      data: yieldInfo,
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Failed to fetch yield data',
    });
  }
});

/**
 * GET /api/v1/yield/calculate
 * 計算預估收益
 */
router.get('/calculate', async (req: Request, res: Response) => {
  try {
    const { principal, days } = req.query;

    const principalBigInt = BigInt(principal as string);
    const daysNum = parseInt(days as string, 10);

    const calculation = await yieldAggregator.calculateProjectedYield(
      principalBigInt,
      daysNum
    );

    res.json({
      success: true,
      data: {
        principal: principalBigInt.toString(),
        projectedInterest: calculation.daily,
        projectedTotal: (principalBigInt + BigInt(calculation.daily)).toString(),
        breakdown: calculation,
      },
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: 'Failed to calculate yield',
    });
  }
});

export default router;
