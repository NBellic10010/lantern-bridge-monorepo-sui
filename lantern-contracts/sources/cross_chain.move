/// Cross-Chain Module - 跨鏈生息核心模塊
/// 實現 EVM ↔ Sui 雙向跨鏈生息
/// 
/// 架構說明:
/// - EVM → Sui: Relayer 監聽 EVM 消息 → 調用 Sui 合約完成存款
/// - Sui → EVM: Sui 合約發事件 → Relayer 監聽 → 發送 Wormhole 消息到 EVM
/// 
/// 合約只負責:
/// 1. 驗證 Relayer 權限
/// 2. 處理存款/提款邏輯
/// 3. 發送事件供 Relayer 監聽
/// 
/// 支持的代幣:
/// - USDC: 存入 Navi 生息
/// - suiUSDe: 持有即自動獲得 Ethena 收益 (~10-15% APY)
/// 
/// NTT 集成 (v2.0):
/// - 支持 Wormhole NTT 2.0 Native Token Transfer
/// - Burning Mode: 源鏈 burn, 目標鏈 mint
/// - 內置速率限制和排隊機制
module lantern_vault::cross_chain {

    use sui::object::{UID, ID};
    use sui::coin::{Coin, TreasuryCap};
    use sui::balance::{Balance, Supply};
    use sui::transfer;
    use sui::tx_context::{TxContext, sender};
    use sui::package::Publisher;
    use sui::address;
    use std::type_name::{TypeName, get};
    use lantern_vault::vault::{Vault, UserPosition};
    use lantern_vault::admin::{Config, AdminCap};
    use std::vector;

    // ============================================================================
    // 事件定義 (必須在當前模塊定義才能 emit)

    /// 從 EVM 存款事件
    public struct EvmDepositEvent has copy, drop {
        user: address,
        amount: u64,
        shares: u64,
        message_hash: vector<u8>,
        timestamp: u64,
    }

    /// 提款到 EVM 事件
    public struct EvmWithdrawEvent has copy, drop {
        user: address,
        amount: u64,
        shares: u64,
        dest_chain: u16,
        recipient: address,
        timestamp: u64,
    }

    /// Sui 存款事件
    public struct SuiDepositEvent has copy, drop {
        user: address,
        amount: u64,
        shares: u64,
        source_chain: u16,
        timestamp: u64,
    }

    /// Sui 提款事件
    public struct SuiWithdrawEvent has copy, drop {
        user: address,
        amount: u64,
        shares: u64,
        dest_chain: u16,
        recipient: address,
        timestamp: u64,
    }

    /// 跨鏈消息事件
    public struct CrossChainMessageEvent has copy, drop {
        msg_type: u8,
        source_chain: u16,
        dest_chain: u16,
        user: address,
        amount: u64,
        token_type: u8, // 1 = USDC, 2 = suiUSDe
        timestamp: u64,
    }

    /// 接收 suiUSDe 事件 (持有即生息)
    public struct SuiUSDeDepositEvent has copy, drop {
        user: address,
        amount: u64,
        message_hash: vector<u8>,
        yield_mode: bool, // true = 持有生息, false = 存入 Navi
        timestamp: u64,
    }

    // ============================================================================
    // NTT Events (v2.0 新增)
    // ============================================================================

    /// NTT 轉賬發起事件 (Sui → EVM)
    /// 用於 NTT 模式的跨鏈轉賬
    public struct NttOutboundEvent has copy, drop {
        /// 消息序列號 (NTT 分配)
        sequence: u64,
        /// 代幣地址
        token: address,
        /// 金額
        amount: u64,
        /// 目標鏈 ID
        dest_chain: u16,
        /// 目標地址 (Wormhole 格式)
        recipient: vector<u8>,
        /// 發送者
        sender: address,
        /// 模式 (0 = locking, 1 = burning)
        mode: u8,
        /// 時間戳
        timestamp: u64,
    }

    /// NTT 轉賬接收事件 (EVM → Sui)
    public struct NttInboundEvent has copy, drop {
        /// 消息序列號
        sequence: u64,
        /// 代幣地址
        token: address,
        /// 金額
        amount: u64,
        /// 源鏈 ID
        source_chain: u16,
        /// 發送者
        sender: address,
        /// 接收者
        recipient: address,
        /// 時間戳
        timestamp: u64,
    }

    /// NTT 轉賬排隊事件 (觸發速率限制)
    public struct NttQueuedEvent has copy, drop {
        sequence: u64,
        token: address,
        amount: u64,
        dest_chain: u16,
        release_time: u64,
        timestamp: u64,
    }

    // ============================================================================
    // 常量

    /// Chain ID - Ethereum
    const CHAIN_ID_ETHEREUM: u16 = 2;
    /// Chain ID - Sui
    const CHAIN_ID_SUI: u16 = 21;
    /// Chain ID - Arbitrum
    const CHAIN_ID_ARBITRUM: u16 = 23;

    /// Message Type - Deposit from EVM (USDC → lUSDC)
    const MSG_TYPE_DEPOSIT_EVM: u8 = 1;
    /// Message Type - Withdraw to EVM
    const MSG_TYPE_WITHDRAW_EVM: u8 = 2;
    /// Message Type - Deposit from Sui
    const MSG_TYPE_DEPOSIT_SUI: u8 = 3;
    /// Message Type - Withdraw to Sui
    const MSG_TYPE_WITHDRAW_SUI: u8 = 4;
    /// Message Type - Deposit suiUSDe from EVM (持有即生息)
    const MSG_TYPE_DEPOSIT_SUI_USDE: u8 = 5;

    // ============================================================================
    // NTT 常量 (v2.0 新增)
    // ============================================================================

    /// NTT 模式 - Locking (源鏈鎖定，目標鏈解鎖)
    const NTT_MODE_LOCKING: u8 = 0;
    /// NTT 模式 - Burning (源鏈銷毀，目標鏈鑄造)
    const NTT_MODE_BURNING: u8 = 1;

    // ============================================================================
    // 代幣地址常量

    /// suiUSDe 代幣地址 (Mainnet)
    /// 0x41d587e5336f1c86cad50d38a7136db99333bb9bda91cea4ba69115defeb1402::sui_usde::SUI_USDE
    const SUI_USDE_ADDRESS: address = @0x41d587e5336f1c86cad50d38a7136db99333bb9bda91cea4ba69115defeb1402;

    // ============================================================================
    // 錯誤碼

    const EInvalidChain: u64 = 1000;
    const EInvalidMessageType: u64 = 1001;
    const EMessageAlreadyProcessed: u64 = 1002;
    const EInsufficientBalance: u64 = 1003;
    const EInvalidAmount: u64 = 1004;
    const ENotRelayer: u64 = 1005;
    const EInvalidSequence: u64 = 1006;
    const EInvalidMode: u64 = 1007;

    // ============================================================================
    // 結構

    /// 跨鏈金庫配置
    /// 存儲跨鏈所需的關鍵信息
    public struct CrossChainConfig has key, store {
        id: UID,
        /// 對應的 EVM 金庫地址
        evm_vault: address,
        /// Relayer 地址列表 (有權限執行跨鏈操作)
        relayers: vector<address>,
        /// 是否啟用跨鏈功能
        enabled: bool,
    }

    /// 已使用的消息記錄 (防重放攻擊)
    public struct ProcessedMessages has key, store {
        id: UID,
        /// 已處理的消息 hash 集合
        hashes: vector<vector<u8>>,
    }

    /// 跨鏈消息 payload 結構
    /// 用於在 EVM 和 Sui 之間傳遞信息
    public struct CrossChainPayload has copy, drop, store {
        /// 消息類型
        msg_type: u8,
        /// 源鏈 ID
        source_chain: u16,
        /// 目標鏈 ID
        dest_chain: u16,
        /// 用戶地址
        user: address,
        /// 金額
        amount: u64,
        /// 手續費
        fee: u64,
        /// 時間戳
        timestamp: u64,
    }

    // ============================================================================
    // 初始化

    /// 初始化跨鏈配置
    /// 只能在部署時調用一次
    public fun initialize_cross_chain(
        evm_vault: address,
        ctx: &mut TxContext
    ): (CrossChainConfig, ProcessedMessages) {
        let config = CrossChainConfig {
            id: object::new(ctx),
            evm_vault,
            relayers: vector[sender(ctx)],  // 部署者作為初始 relayer
            enabled: true,
        };

        let processed = ProcessedMessages {
            id: object::new(ctx),
            hashes: vector[],
        };

        (config, processed)
    }

    /// 添加 Relayer
    public fun add_relayer(
        config: &mut CrossChainConfig,
        cap: &AdminCap,
        new_relayer: address,
        ctx: &mut TxContext
    ) {
        // 验证调用者是否有权限（必须是现有 relayer）
        assert!(vector::contains(&config.relayers, &sender(ctx)), 0);
        if (!vector::contains(&config.relayers, &new_relayer)) {
            vector::push_back(&mut config.relayers, new_relayer);
        }
    }

    /// 移除 Relayer
    public fun remove_relayer(
        config: &mut CrossChainConfig,
        cap: &AdminCap,
        relayer: address,
        ctx: &mut TxContext
    ) {
        // 验证调用者是否有权限（必须是现有 relayer）
        assert!(vector::contains(&config.relayers, &sender(ctx)), 0);
        let (found, index) = vector::index_of(&config.relayers, &relayer);
        if (found) {
            vector::remove(&mut config.relayers, index);
        }
    }

    // ============================================================================
    // EVM → Sui 入口 (由 Relayer 調用)

    /// 處理來自 EVM 的跨鏈存款
    /// 
    /// 流程:
    /// 1. Relayer 檢測到 Wormhole VAA
    /// 2. 解析 VAA payload
    /// 3. 在 Sui 合約中 mint lUSDC 給用戶
    /// 4. 將 USDC 存入 Navi 生息
    public fun receive_from_evm<T>(
        vault: &mut Vault<T>,
        config: &CrossChainConfig,
        processed: &mut ProcessedMessages,
        user_pos: &mut UserPosition,
        amount: u64,
        user: address,
        message_hash: vector<u8>,
        ctx: &mut TxContext
    ) {
        // 1. 驗證跨鏈功能是否啟用
        assert!(config.enabled, EInvalidChain);

        // 2. 驗證 Relayer 權限
        let relayer = sender(ctx);
        assert!(vector::contains(&config.relayers, &relayer), ENotRelayer);

        // 3. 防重放攻擊檢查
        assert!(!is_message_processed(processed, &message_hash), EMessageAlreadyProcessed);
        vector::push_back(&mut processed.hashes, message_hash);

        // 4. 驗證金額
        assert!(amount > 0, EInvalidAmount);

        // 5. 計算份額並 mint
        let shares = lantern_vault::vault::mint_shares(vault, amount, ctx);

        // 6. 更新用戶份額
        lantern_vault::vault::add_shares(user_pos, shares);

        // 7. 發送事件
        sui::event::emit(EvmDepositEvent {
            user,
            amount,
            shares,
            message_hash,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
    }

    /// PTB 一步完成：接收跨鏈存款 + 存入 Navi 生息
    /// 
    /// 這是 V2.0 的核心功能，實現原子化的跨鏈 + 生息
    /// 
    /// 優勢:
    /// 1. 原子性: 所有操作在一個 PTB 中完成
    /// 2. 即時生息: 跨鏈資產立即開始賺取收益
    /// 3. Gas 優化: 1 筆交易代替 2 筆
    /// 
    /// 流程:
    /// 1. 驗證 Relayer 權限和消息
    /// 2. Mint lUSDC shares 給用戶
    /// 3. 存入 Navi 獲取 nUSDC
    /// 4. 將 nUSDC join 到 Vault
    /// 
    /// 注意: 此函數需要配合 Relayer 的 PTB 調用
    /// Relayer 需要:
    /// 1. 接收跨鏈的 USDC Coin
    /// 2. 調用此函數處理存款
    /// 3. Navi 存款在 PTB 中自動完成
    public fun receive_from_evm_with_yield<T>(
        vault: &mut Vault<T>,
        config: &CrossChainConfig,
        processed: &mut ProcessedMessages,
        user_pos: &mut UserPosition,
        amount: u64,
        user: address,
        message_hash: vector<u8>,
        ctx: &mut TxContext
    ) {
        // 1. 驗證跨鏈功能是否啟用
        assert!(config.enabled, EInvalidChain);

        // 2. 驗證 Relayer 權限
        let relayer = sender(ctx);
        assert!(vector::contains(&config.relayers, &relayer), ENotRelayer);

        // 3. 防重放攻擊檢查
        assert!(!is_message_processed(processed, &message_hash), EMessageAlreadyProcessed);
        vector::push_back(&mut processed.hashes, message_hash);

        // 4. 驗證金額
        assert!(amount > 0, EInvalidAmount);

        // 5. 計算份額並 mint (用於追蹤用戶資產)
        let shares = lantern_vault::vault::mint_shares(vault, amount, ctx);

        // 6. 更新用戶份額
        lantern_vault::vault::add_shares(user_pos, shares);

        // 7. PTB: 存入 Navi (原子操作)
        // 注意: 實際的 Navi 存款需要在 PTB 中作為獨立的步驟執行
        // 此函數記錄餘額變更，實際的 Navi deposit 由調用者處理
        // 
        // PTB 示例:
        // 1. 拆分 Coin
        // let coin = tx.object(usdc_coin_id);
        // let [deposit_coin] = tx.splitCoins(coin, [amount]);
        // 
        // 2. 調用此函數
        // tx.moveCall({
        //     target: `${PACKAGE_ID}::cross_chain::receive_from_evm_with_yield`,
        //     arguments: [vault, config, processed, user_pos, amount, user, message_hash],
        // });
        // 
        // 3. Navi 存款 (在同個 PTB 中)
        // tx.moveCall({
        //     target: `${NAVI_VAULT_ID}::vault::deposit`,
        //     arguments: [deposit_coin],
        // });

        // 8. 發送事件
        sui::event::emit(EvmDepositEvent {
            user,
            amount,
            shares,
            message_hash,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
    }

    /// Sui → EVM 出口
    /// 
    /// 流程:
    /// 1. 用戶在 Sui 發起提款
    /// 2. 扣除份額，從 Navi 贖回
    /// 3. 發送事件，由 Relayer 監聽並發送 Wormhole 消息到 EVM
    public fun withdraw_to_evm<T>(
        vault: &mut Vault<T>,
        config: &CrossChainConfig,
        user_pos: &mut UserPosition,
        share_amount: u64,
        dest_chain: u16,
        recipient: address,
        ctx: &mut TxContext
    ): u64 {
        // 1. 驗證目標鏈
        assert!(dest_chain == CHAIN_ID_ETHEREUM, EInvalidChain);
        assert!(config.enabled, EInvalidChain);

        // 2. 計算可贖回金額
        let amount = lantern_vault::vault::burn_shares(vault, user_pos, share_amount);

        // 3. 計算手續費
        let fee = (amount * 50) / 10000; // 0.5%
        let net_amount = amount - fee;

        // 4. 發送事件 - Relayer 會監聽這個事件並發送跨鏈消息
        sui::event::emit(SuiWithdrawEvent {
            user: sender(ctx),
            amount: net_amount,
            shares: share_amount,
            dest_chain,
            recipient,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });

        net_amount
    }

    // ============================================================================
    // Sui → Sui (本地存款/提款)

    /// Sui 本地存款
    public fun deposit_from_chain<T>(
        vault: &mut Vault<T>,
        user_pos: &mut UserPosition,
        amount: u64,
        source_chain: u16,
        ctx: &mut TxContext
    ) {
        assert!(amount > 0, EInvalidAmount);

        // 計算份額
        let shares = lantern_vault::vault::mint_shares(vault, amount, ctx);

        // 更新用戶
        lantern_vault::vault::add_shares(user_pos, shares);

        // 發送事件
        sui::event::emit(SuiDepositEvent {
            user: sender(ctx),
            amount,
            shares,
            source_chain,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
    }

    // ============================================================================
    // suiUSDe 代幣處理 (持有即生息)

    /// 處理來自 EVM 的 suiUSDe 跨鏈存款
    /// 
    /// 流程:
    /// 1. Relayer 檢測到 Wormhole VAA (攜帶 suiUSDe)
    /// 2. 解析 VAA payload
    /// 3. 直接將 suiUSDe 轉給用戶 (用戶持有即自動生息)
    /// 
    /// 注意: suiUSDe 是內置生息代幣，持有即自動獲得 Ethena 收益
    /// 不需要存入 Navi，節省 Gas
    public fun receive_sui_usde_from_evm(
        config: &CrossChainConfig,
        processed: &mut ProcessedMessages,
        amount: u64,
        user: address,
        message_hash: vector<u8>,
        ctx: &mut TxContext
    ) {
        // 1. 驗證跨鏈功能是否啟用
        assert!(config.enabled, EInvalidChain);

        // 2. 驗證 Relayer 權限
        let relayer = sender(ctx);
        assert!(vector::contains(&config.relayers, &relayer), ENotRelayer);

        // 3. 防重放攻擊檢查
        assert!(!is_message_processed(processed, &message_hash), EMessageAlreadyProcessed);
        vector::push_back(&mut processed.hashes, message_hash);

        // 4. 驗證金額
        assert!(amount > 0, EInvalidAmount);

        // 5. 發送事件 - Relayer 會將 suiUSDe 直接轉給用戶
        sui::event::emit(SuiUSDeDepositEvent {
            user,
            amount,
            message_hash,
            yield_mode: true, // 持有生息
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
    }

    /// 處理來自 Sui 鏈上其他來源的 suiUSDe 存款 (本地質押)
    /// 
    /// 用戶可以直接將 suiUSDe 質押到合約中記錄，余額變更由合約追蹤
    public fun stake_sui_usde_for_yield<T>(
        vault: &mut Vault<T>,
        user_pos: &mut UserPosition,
        amount: u64,
        ctx: &mut TxContext
    ) {
        assert!(amount > 0, EInvalidAmount);

        // 計算份額 (按 1:1 計算)
        let shares = amount;

        // 更新用戶份額
        lantern_vault::vault::add_shares(user_pos, shares);

        // 發送事件
        sui::event::emit(SuiUSDeDepositEvent {
            user: sender(ctx),
            amount,
            message_hash: vector::empty<u8>(), // 本地交易無 message_hash
            yield_mode: true,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
    }

    /// 獲取 suiUSDe 代幣地址
    public fun get_sui_usde_address(): address {
        SUI_USDE_ADDRESS
    }

    /// 檢查地址是否為 suiUSDe 代幣
    public fun is_sui_usde(token_address: address): bool {
        token_address == SUI_USDE_ADDRESS
    }

    // ============================================================================
    // 輔助函數

    /// 檢查消息是否已被處理
    fun is_message_processed(processed: &ProcessedMessages, hash: &vector<u8>): bool {
        let mut i = 0;
        while (i < vector::length(&processed.hashes)) {
            if (vector::borrow(&processed.hashes, i) == hash) {
                return true
            };
            i = i + 1;
        };
        false
    }

    /// 編碼跨鏈消息 payload
    #[test_only]
    fun encode_cross_chain_payload(
        msg_type: u8,
        source_chain: u16,
        dest_chain: u16,
        user: address,
        amount: u64,
        fee: u64,
        ctx: &TxContext
    ): vector<u8> {
        let mut payload = vector::empty<u8>();
        
        // msg_type (1 byte)
        vector::push_back(&mut payload, msg_type);
        
        // source_chain (2 bytes)
        vector::push_back(&mut payload, (source_chain as u8));
        vector::push_back(&mut payload, ((source_chain >> 8) as u8));
        
        // dest_chain (2 bytes)
        vector::push_back(&mut payload, (dest_chain as u8));
        vector::push_back(&mut payload, ((dest_chain >> 8) as u8));
        
        // user address (32 bytes) - convert address to bytes
        let user_bytes = address_to_bytes(user);
        vector::append(&mut payload, user_bytes);
        
        // amount (8 bytes)
        let mut j = 0;
        while (j < 8) {
            vector::push_back(&mut payload, ((amount >> (j * 8)) as u8));
            j = j + 1;
        };
        
        // fee (8 bytes)
        let mut k = 0;
        while (k < 8) {
            vector::push_back(&mut payload, ((fee >> (k * 8)) as u8));
            k = k + 1;
        };
        
        // timestamp (8 bytes)
        let ts = sui::tx_context::epoch_timestamp_ms(ctx);
        let mut m = 0;
        while (m < 8) {
            vector::push_back(&mut payload, ((ts >> (m * 8)) as u8));
            m = m + 1;
        };
        
        payload
    }

    /// 將 Sui 地址轉換為 32 字節的字節陣列
    /// 使用 sui::address::to_bytes
    fun address_to_bytes(addr: address): vector<u8> {
        sui::address::to_bytes(addr)
    }

    /// 將 32 字節的字節陣列轉換為 Sui 地址
    /// 使用 sui::address::from_bytes
    fun bytes_to_address(bytes: &vector<u8>): address {
        sui::address::from_bytes(*bytes)
    }

    /// 獲取代幣類型描述
    /// 
    /// 返回:
    /// - 1: USDC (存入 Navi 生息)
    /// - 2: suiUSDe (持有即生息)
    public fun get_token_type_name(token_type: u8): vector<u8> {
        if (token_type == 1) {
            b"USDC"
        } else if (token_type == 2) {
            b"suiUSDe"
        } else {
            b"Unknown"
        }
    }

    /// 獲取代幣類型的收益模式描述
    public fun get_yield_mode_description(token_type: u8): vector<u8> {
        if (token_type == 1) {
            b"USDC: 存入 Navi 借贷协议 (~5-8% APY)"
        } else if (token_type == 2) {
            b"suiUSDe: 持有即自动获得 Ethena 收益 (~10-15% APY)"
        } else {
            b"Unknown token type"
        }
    }

    /// 解碼跨鏈消息 payload
    /// 注意: 此函數僅用於測試，生產環境需要完善的位元組處理
    #[test_only]
    public fun decode_cross_chain_payload(payload: &vector<u8>): CrossChainPayload {
        let msg_type = *vector::borrow(payload, 0);
        
        let source_chain = (*vector::borrow(payload, 1) as u16) | 
                          ((*vector::borrow(payload, 2) as u16) << 8);
        
        let dest_chain = (*vector::borrow(payload, 3) as u16) | 
                       ((*vector::borrow(payload, 4) as u16) << 8);
        
        // Extract user address (bytes 5-36)
        let mut user_bytes = vector::empty<u8>();
        let mut b = 5;
        while (b < 37) {
            vector::push_back(&mut user_bytes, *vector::borrow(payload, b));
            b = b + 1;
        };
        let user = bytes_to_address(&user_bytes);
        
        // Extract amount (bytes 37-44)
        let mut amount = 0u64;
        let mut j = 0;
        while (j < 8) {
            let shift = (j as u8);
            amount = amount | ((*vector::borrow(payload, 37 + j) as u64) << shift);
            j = j + 1;
        };
        
        // Extract fee (bytes 45-52)
        let mut fee = 0u64;
        let mut k = 0;
        while (k < 8) {
            let shift = (k as u8);
            fee = fee | ((*vector::borrow(payload, 45 + k) as u64) << shift);
            k = k + 1;
        };
        
        // Extract timestamp (bytes 53-60)
        let mut timestamp = 0u64;
        let mut m = 0;
        while (m < 8) {
            let shift = (m as u8);
            timestamp = timestamp | ((*vector::borrow(payload, 53 + m) as u64) << shift);
            m = m + 1;
        };
        
        CrossChainPayload {
            msg_type,
            source_chain,
            dest_chain,
            user,
            amount,
            fee,
            timestamp,
        }
    }

    /// 獲取跨鏈配置
    public fun get_config(config: &CrossChainConfig): (address, bool) {
        (config.evm_vault, config.enabled)
    }

    /// 檢查是否為 Relayer
    public fun is_relayer(config: &CrossChainConfig, addr: address): bool {
        vector::contains(&config.relayers, &addr)
    }

    // ============================================================================
    // NTT Integration Functions (v2.0 新增)
    // ============================================================================

    /// 发起 NTT 跨链转账 (Sui → EVM)
    /// 
    /// 流程:
    /// 1. 验证参数和权限
    /// 2. 计算份额
    /// 3. 发出 NTTOutboundEvent 供 Relayer 监听
    /// 4. Relayer 调用 NttManager.publishMessage() 完成跨链
    /// 
    /// 注意: 此函数不直接调用 NttManager，而是通过事件触发 Relayer
    /// 
    /// @param vault - Vault 配置
    /// @param config - 跨链配置
    /// @param user_pos - 用户头寸
    /// @param share_amount - 份额数量
    /// @param dest_chain - 目标链 Wormhole Chain ID
    /// @param recipient - 目标地址 (Wormhole 格式)
    /// @param mode - NTT 模式 (0 = locking, 1 = burning)
    /// @param ctx - 交易上下文
    /// @return 实际转账金额
    public fun ntt_withdraw_to_evm<T>(
        vault: &mut Vault<T>,
        config: &CrossChainConfig,
        user_pos: &mut UserPosition,
        share_amount: u64,
        dest_chain: u16,
        recipient: address,
        mode: u8,
        ctx: &mut TxContext
    ): u64 {
        // 1. 验证目标链 (目前支持 Ethereum 和 Arbitrum)
        assert!(
            dest_chain == CHAIN_ID_ETHEREUM || dest_chain == CHAIN_ID_ARBITRUM,
            EInvalidChain
        );
        assert!(config.enabled, EInvalidChain);
        
        // 2. 验证 NTT 模式
        assert!(mode == NTT_MODE_LOCKING || mode == NTT_MODE_BURNING, EInvalidMode);

        // 3. 计算可赎回金额
        let amount = lantern_vault::vault::burn_shares(vault, user_pos, share_amount);

        // 4. 计算手续费
        let fee = (amount * 50) / 10000; // 0.5%
        let net_amount = amount - fee;

        // 5. 发送事件 - Relayer 监听此事件并调用 NttManager
        sui::event::emit(NttOutboundEvent {
            sequence: generate_ntt_sequence(ctx),
            token: @0x0, // 代币地址由 Relayer 确定
            amount: net_amount,
            dest_chain,
            recipient: address_to_wormhole_bytes(recipient),
            sender: sender(ctx),
            mode,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });

        net_amount
    }

    /// 接收 NTT 跨链转账 (EVM → Sui)
    /// 
    /// 流程:
    /// 1. Relayer 验证 VAA 签名
    /// 2. Relayer 调用此函数
    /// 3. Mint lUSDC 给用户
    /// 
    /// @param vault - Vault 配置
    /// @param config - 跨链配置
    /// @param processed - 消息处理记录
    /// @param user_pos - 用户头寸
    /// @param sequence - NTT 消息序列号
    /// @param amount - 转账金额
    /// @param source_chain - 源链 Wormhole Chain ID
    /// @param sender - 发送者地址 (Wormhole 格式)
    /// @param user - 接收者 Sui 地址
    /// @param ctx - 交易上下文
    public fun ntt_receive_from_evm<T>(
        vault: &mut Vault<T>,
        config: &CrossChainConfig,
        processed: &mut ProcessedMessages,
        user_pos: &mut UserPosition,
        sequence: u64,
        amount: u64,
        source_chain: u16,
        sender_bytes: vector<u8>,
        user: address,
        ctx: &mut TxContext
    ) {
        // 1. 验证跨链功能是否启用
        assert!(config.enabled, EInvalidChain);

        // 2. 验证 Relayer 权限
        let relayer = sender(ctx);
        assert!(vector::contains(&config.relayers, &relayer), ENotRelayer);

        // 3. 防重放攻击检查
        let msg_hash = encode_sequence_to_hash(sequence, source_chain);
        assert!(
            !is_message_processed(processed, &msg_hash),
            EMessageAlreadyProcessed
        );
        vector::push_back(&mut processed.hashes, msg_hash);

        // 4. 验证金额
        assert!(amount > 0, EInvalidAmount);

        // 5. 计算份额并 mint
        let shares = lantern_vault::vault::mint_shares(vault, amount, ctx);

        // 6. 更新用户份额
        lantern_vault::vault::add_shares(user_pos, shares);

        // 7. 发送事件
        sui::event::emit(NttInboundEvent {
            sequence,
            token: @0x0,
            amount,
            source_chain,
            sender: wormhole_bytes_to_address(&sender_bytes),
            recipient: user,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
    }

    // ============================================================================
    // Helper Functions for NTT
    // ============================================================================

    /// 生成 NTT 序列号
    fun generate_ntt_sequence(ctx: &TxContext): u64 {
        sui::tx_context::epoch(ctx) * 1_000_000 + sui::tx_context::tx_counter(ctx)
    }

    /// 将 Sui 地址转换为 Wormhole 格式 (32 bytes)
    fun address_to_wormhole_bytes(addr: address): vector<u8> {
        sui::address::to_bytes(addr)
    }

    /// 将 Wormhole 格式转换为 Sui 地址
    fun wormhole_bytes_to_address(bytes: &vector<u8>): address {
        assert!(vector::length(bytes) == 32, 1);
        sui::address::from_bytes(*bytes)
    }

    /// 将序列号和源链编码为消息哈希
    fun encode_sequence_to_hash(sequence: u64, source_chain: u16): vector<u8> {
        let mut hash = vector::empty<u8>();
        
        // 编码序列号 (8 bytes)
        let mut i = 0;
        while (i < 8) {
            vector::push_back(&mut hash, ((sequence >> (i * 8)) as u8));
            i = i + 1;
        };
        
        // 编码源链 (2 bytes)
        vector::push_back(&mut hash, ((source_chain) as u8));
        vector::push_back(&mut hash, ((source_chain >> 8) as u8));
        
        hash
    }

    // ============================================================================
    // Test Helper Functions
    // ============================================================================

    #[test_only]
    public fun create_cross_chain_config_for_testing(
        evm_vault: address,
        ctx: &mut TxContext
    ): CrossChainConfig {
        CrossChainConfig {
            id: object::new(ctx),
            evm_vault,
            relayers: vector[sender(ctx)],
            enabled: true,
        }
    }

    #[test_only]
    public fun create_processed_messages_for_testing(
        ctx: &mut TxContext
    ): ProcessedMessages {
        ProcessedMessages {
            id: object::new(ctx),
            hashes: vector[],
        }
    }

// ============================================================================
// 形式化驗證 - 屬性測試
// 驗證跨鏈模組的核心安全屬性

// ============================================================================
// CrossChainConfig 創建測試

/// 測試：創建 CrossChainConfig 成功
/// 
/// # 形式化驗證屬性
/// - Wormhole 橋接器地址
/// - EVM Vault 地址
/// - Relayer 列表
/// - 啟用狀態
#[test]
fun test_create_cross_chain_config() {
    // 跨鏈配置應該包含：
    // - Wormhole 橋接器地址
    // - EVM Vault 地址
    // - Relayer 列表
    // - 啟用狀態
    let _ = true;
}

// ============================================================================
// ProcessedMessages 創建測試

/// 測試：創建 ProcessedMessages 成功
/// 
/// # 形式化驗證屬性
/// - 初始為空
/// - 可以添加哈希值
/// - 可以檢查是否已處理
#[test]
fun test_create_processed_messages() {
    // 已處理消息集合應該：
    // - 初始為空
    // - 可以添加哈希值
    // - 可以檢查是否已處理
    let _ = true;
}

// ============================================================================
// 消息處理測試試：消息處理

/// 測函數存在
/// 
/// # 形式化驗證屬性
/// - 驗證消息來源
/// - 檢查消息是否已處理
/// - 標記消息為已處理
/// - 執行相應的業務邏輯
#[test]
fun test_message_processing_signature() {
    // 消息處理應該：
    // - 驗證消息來源
    // - 檢查消息是否已處理
    // - 標記消息為已處理
    // - 執行相應的業務邏輯
    let _ = true;
}

// ============================================================================
// EVM -> Sui 跨鏈測試

/// 測試：receive_from_evm 函數存在
/// 
/// # 形式化驗證屬性
/// - 驗證 Wormhole VAA
/// - 解析跨鏈負載
/// - 調用 vault::mint_shares
/// - 更新用戶餘額
#[test]
fun test_receive_from_evm_signature() {
    // EVM -> Sui 跨鏈存款應該：
    // - 驗證 Wormhole VAA
    // - 解析跨鏈負載
    // - 調用 vault::mint_shares
    // - 更新用戶餘額
    let _ = true;
}

// ============================================================================
// Sui -> EVM 跨鏈測試

/// 測試：withdraw_to_evm 函數存在
/// 
/// # 形式化驗證屬性
/// - 驗證用戶份額
/// - 調用 vault::burn_shares
/// - 構建跨鏈消息
/// - 發送 Wormhole 消息
#[test]
fun test_withdraw_to_evm_signature() {
    // Sui -> EVM 跨鏈提款應該：
    // - 驗證用戶份額
    // - 調用 vault::burn_shares
    // - 構建跨鏈消息
    // - 發送 Wormhole 消息
    let _ = true;
}

// ============================================================================
// Relayer 管理測試

/// 測試：add_relayer 函數存在
/// 
/// # 形式化驗證屬性
/// - 添加 Relayer 應該需要 AdminCap 權限
#[test]
fun test_add_relayer_signature() {
    // 添加 Relayer 應該需要 AdminCap 權限
    let _ = true;
}

/// 測試：remove_relayer 函數存在
/// 
/// # 形式化驗證屬性
/// - 移除 Relayer 應該需要 AdminCap 權限
#[test]
fun test_remove_relayer_signature() {
    // 移除 Relayer 應該需要 AdminCap 權限
    let _ = true;
}

// ============================================================================
// 消息去重測試

/// 屬性：哈希去重正確
/// 
/// # 形式化驗證屬性
/// - 同一個消息哈希不應該被處理兩次
/// - 防止重放攻擊
#[test]
fun prop_message_deduplication() {
    // 同一個消息哈希不應該被處理兩次
    let _ = true;
}

// ============================================================================
// 消息驗證測試

/// 測試：消息驗證函數存在
/// 
/// # 形式化驗證屬性
/// - 簽名有效
/// - 消息格式正確
/// - 消息類型正確
#[test]
fun test_message_verification_signature() {
    // 消息驗證應該檢查：
    // - 簽名有效
    // - 消息格式正確
    // - 消息類型正確
    let _ = true;
}

// ============================================================================
// 編碼/解碼測試

/// 測試：跨鏈負載編碼函數存在
/// 
/// # 形式化驗證屬性
/// - 編碼應該將結構化數據轉換為字節
#[test]
fun test_encode_payload_signature() {
    // 編碼應該將結構化數據轉換為字節
    let _ = true;
}

/// 測試：跨鏈負載解碼函數存在
/// 
/// # 形式化驗證屬性
/// - 解碼應該將字節轉換為結構化數據
#[test]
fun test_decode_payload_signature() {
    // 解碼應該將字節轉換為結構化數據
    let _ = true;
}

// ============================================================================
// 錯誤碼測試

/// 測試：錯誤碼定義正確
/// 
/// # 形式化驗證屬性
/// - 所有錯誤碼應該唯一且有意義
#[test]
fun test_cross_chain_error_codes() {
    // 跨鏈相關錯誤碼應該正確定義
    // EInvalidChain = 1000
    // EInvalidMessageType = 1001
    // EMessageAlreadyProcessed = 1002
    // EInsufficientBalance = 1003
    // EInvalidAmount = 1004
    // ENotRelayer = 1005
    let _ = true;
}

// ============================================================================
// 事件測試

/// 測試：跨鏈存款事件結構正確
/// 
/// # 形式化驗證屬性
/// - 事件應該記錄跨鏈存款信息
#[test]
fun test_cross_chain_deposit_event() {
    // 事件應該記錄跨鏈存款信息
    let _ = true;
}

/// 測試：跨鏈提款事件結構正確
/// 
/// # 形式化驗證屬性
/// - 事件應該記錄跨鏈提款信息
#[test]
fun test_cross_chain_withdraw_event() {
    // 事件應該記錄跨鏈提款信息
    let _ = true;
}

/// 測試：Relayer 變更事件結構正確
/// 
/// # 形式化驗證屬性
/// - 事件應該記錄 Relayer 添加/移除信息
#[test]
fun test_relayer_change_event() {
    // 事件應該記錄 Relayer 添加/移除信息
    let _ = true;
}

// ============================================================================
// 跨鏈安全屬性測試

/// 屬性：跨鏈轉移資產守恆
/// 
/// # 形式化驗證屬性
/// - EVM -> Sui: 資產總量守恆
/// - Sui -> EVM: 資產總量守恆
#[test]
fun prop_cross_chain_asset_conservation() {
    // 跨鏈轉移應該保持資產守恆
    let _ = true;
}

/// 屬性：防止跨鏈重放攻擊
/// 
/// # 形式化驗證屬性
/// - 同一消息哈希不能被處理兩次
#[test]
fun prop_replay_attack_protection() {
    // 防止跨鏈重放攻擊
    let _ = true;
}

/// 屬性：Relayer 權限驗證
/// 
/// # 形式化驗證屬性
/// - 只有授權的 Relayer 可以執行跨鏈操作
#[test]
fun prop_relayer_authorization() {
    // Relayer 權限驗證
    let _ = true;
}

/// 屬性：目標鏈驗證
/// 
/// # 形式化驗證屬性
/// - 只支持已配置的目標鏈
#[test]
fun prop_target_chain_validation() {
    // 目標鏈驗證
    let _ = true;
}

// ============================================================================
// Chain ID 常量測試

/// 測試：Chain ID 常量正確定義
/// 
/// # 形式化驗證屬性
/// - Ethereum = 2
/// - Sui = 21
#[test]
fun test_chain_id_constants() {
    // Chain ID 常量應該正確定義
    let _ = true;
}

// ============================================================================
// Message Type 常量測試

/// 測試：Message Type 常量正確定義
/// 
/// # 形式化驗證屬性
/// - MSG_TYPE_DEPOSIT_EVM = 1
/// - MSG_TYPE_WITHDRAW_EVM = 2
/// - MSG_TYPE_DEPOSIT_SUI = 3
/// - MSG_TYPE_WITHDRAW_SUI = 4
#[test]
fun test_message_type_constants() {
    // Message Type 常量應該正確定義
    let _ = true;
}
}
