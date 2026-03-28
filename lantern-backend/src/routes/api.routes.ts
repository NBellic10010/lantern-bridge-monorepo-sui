/**
 * API 路由入口
 */
import { Router, Request, Response } from 'express';
import depositRouter from './deposit.routes';
import yieldRouter from './yield.routes';
import vaultRouter from './vault.routes';

const router = Router();

// 路由
router.use('/deposit', depositRouter);
router.use('/yield', yieldRouter);
router.use('/vault', vaultRouter);

// 健康檢查
router.get('/ping', (_req: Request, res: Response) => {
  res.json({ pong: Date.now() });
});

export default router;
