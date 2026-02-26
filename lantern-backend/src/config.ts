/**
 * 配置文件
 */
export const config = {
  // 環境
  env: process.env.NODE_ENV || 'development',
  port: parseInt(process.env.PORT || '3000', 10),

  // CORS
  corsOrigin: process.env.CORS_ORIGIN || 'http://localhost:3001',

  // 數據庫
  database: {
    url: process.env.DATABASE_URL || 'postgresql://localhost:5432/lantern',
  },

  // Redis
  redis: {
    host: process.env.REDIS_HOST || 'localhost',
    port: parseInt(process.env.REDIS_PORT || '6379', 10),
    password: process.env.REDIS_PASSWORD,
  },

  // Sui RPC
  sui: {
    rpcUrl: process.env.SUI_RPC_URL || 'https://rpc.mainnet.sui.io',
    wsUrl: process.env.SUI_WS_URL,
  },

  // Shinami Gas Station
  shinami: {
    apiKey: process.env.SHINAMI_API_KEY || '',
    gasStationId: process.env.SHINAMI_GAS_STATION_ID || '',
  },

  // 後端私鑰（用於簽名）
  backend: {
    privateKey: process.env.BACKEND_PRIVATE_KEY || '',
  },

  // Navi Protocol
  navi: {
    apiUrl: process.env.NAVI_API_URL || 'https://api.naviprotocol.fi',
  },

  // Wormhole
  wormhole: {
    apiUrl: process.env.WORMHOLE_API_URL || 'https://api.wormholescan.io',
  },

  // 風控規則
  sybil: {
    minDepositAmount: parseInt(process.env.MIN_DEPOSIT_AMOUNT || '50', 10), // $50
    maxDailySponsorPerAddress: parseInt(process.env.MAX_DAILY_SPONSOR_PER_ADDRESS || '1', 10),
    maxDailySponsorPerIP: parseInt(process.env.MAX_DAILY_SPONSOR_PER_IP || '3', 10),
  },

  // 手續費
  fee: {
    rate: parseInt(process.env.FEE_RATE || '100', 10), // 1% = 100 basis points
    treasury: process.env.FEE_TREASURY || '',
  },
};
