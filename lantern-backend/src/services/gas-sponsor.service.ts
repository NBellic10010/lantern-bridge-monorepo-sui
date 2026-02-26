/**
 * Gas Sponsor Service - Gas 代付服務
 * 負責處理 Shinami Gas Station 集成
 */
import axios from 'axios';
import { config } from '../config';
import { logger } from './logger.service';

export interface GasSponsorRequest {
  userAddress: string;
  unsignedPTB: string; // Base64 encoded
  depositAmount: number;
  gasBudget?: number;
}

export interface SponsoredTransaction {
  txBytes: string;
  sponsorSignature: string;
  backendSignature: string;
  gasUsed: number;
}

export class GasSponsorService {
  private shinamiApiKey: string;
  private shinamiGasStationId: string;

  constructor() {
    this.shinamiApiKey = config.shinami.apiKey;
    this.shinamiGasStationId = config.shinami.gasStationId;
  }

  /**
   * 請求 Gas 代付
   */
  async sponsorTransaction(req: GasSponsorRequest): Promise<SponsoredTransaction> {
    try {
      logger.info('Requesting gas sponsorship', { userAddress: req.userAddress });

      // 1. 調用 Shinami Gas Station API
      const sponsorResponse = await this.callShinamiSponsorship({
        sender: req.userAddress,
        tx: req.unsignedPTB,
        gasBudget: req.gasBudget || 1000000, // 1 SUI
      });

      // 2. 後端簽名（使用服務器私鑰）
      const backendSignature = await this.signWithBackendKey(sponsorResponse.txBytes);

      logger.info('Gas sponsorship completed', {
        userAddress: req.userAddress,
        gasUsed: sponsorResponse.gasUsed,
      });

      return {
        txBytes: sponsorResponse.txBytes,
        sponsorSignature: sponsorResponse.signature,
        backendSignature,
        gasUsed: sponsorResponse.gasUsed,
      };
    } catch (error) {
      logger.error('Gas sponsorship failed:', error);
      throw error;
    }
  }

  /**
   * 調用 Shinami API
   */
  private async callShinamiSponsorship(params: {
    sender: string;
    tx: string;
    gasBudget: number;
  }): Promise<{ txBytes: string; signature: string; gasUsed: number }> {
    // Shinami API 調用（示例）
    // 實際實現需要根據 Shinami 文檔調整
    const response = await axios.post(
      `https://api.shinami.com/gas/v1/${this.shinamiGasStationId}/sponsorTransaction`,
      {
        ...params,
        sponsorshipKey: this.shinamiApiKey,
      },
      {
        headers: {
          'Content-Type': 'application/json',
        },
      }
    );

    return response.data;
  }

  /**
   * 使用後端私鑰簽名
   */
  private async signWithBackendKey(txBytes: string): Promise<string> {
    // 實際實現需要使用 secp256k1 簽名
    // 這裡是佔位實現
    const privateKey = Buffer.from(config.backend.privateKey, 'hex');

    // TODO: 實現實際的簽名邏輯
    // const message = new Uint8Array(Buffer.from(txBytes, 'base64'));
    // const signature = secp256k1.sign(message, privateKey);

    logger.warn('Backend signature is a placeholder');

    return 'placeholder_signature';
  }
}
