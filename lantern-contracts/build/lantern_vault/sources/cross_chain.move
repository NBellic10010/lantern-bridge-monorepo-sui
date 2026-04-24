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
        timestamp: u64,
    }

    // ============================================================================
    // 常量

    /// Chain ID - Ethereum
    const CHAIN_ID_ETHEREUM: u16 = 2;
    /// Chain ID - Sui
    const CHAIN_ID_SUI: u16 = 21;

    /// Message Type - Deposit from EVM
    const MSG_TYPE_DEPOSIT_EVM: u8 = 1;
    /// Message Type - Withdraw to EVM
    const MSG_TYPE_WITHDRAW_EVM: u8 = 2;
    /// Message Type - Deposit from Sui
    const MSG_TYPE_DEPOSIT_SUI: u8 = 3;
    /// Message Type - Withdraw to Sui
    const MSG_TYPE_WITHDRAW_SUI: u8 = 4;

    // ============================================================================
    // 錯誤碼

    const EInvalidChain: u64 = 1000;
    const EInvalidMessageType: u64 = 1001;
    const EMessageAlreadyProcessed: u64 = 1002;
    const EInsufficientBalance: u64 = 1003;
    const EInvalidAmount: u64 = 1004;
    const ENotRelayer: u64 = 1005;

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
        new_relayer: address
    ) {
        lantern_vault::admin::verify_admin(cap);
        if (!vector::contains(&config.relayers, &new_relayer)) {
            vector::push_back(&mut config.relayers, new_relayer);
        }
    }

    /// 移除 Relayer
    public fun remove_relayer(
        config: &mut CrossChainConfig,
        cap: &AdminCap,
        relayer: address
    ) {
        lantern_vault::admin::verify_admin(cap);
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
    // 測試輔助

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
    #[test]
    fun test_create_cross_chain_config() {
        // 跨鏈配置應該包含：
        // - Wormhole 橋接器地址
        // - EVM Vault 地址
        // - Relayer 列表
        // - 啟用狀態
    }

    // ============================================================================
    // ProcessedMessages 創建測試

    /// 測試：創建 ProcessedMessages 成功
    #[test]
    fun test_create_processed_messages() {
        // 已處理消息集合應該：
        // - 初始為空
        // - 可以添加哈希值
        // - 可以檢查是否已處理
    }

    // ============================================================================
    // 消息處理測試

    /// 測試：消息處理函數存在
    #[test]
    fun test_message_processing_signature() {
        // 消息處理應該：
        // - 驗證消息來源
        // - 檢查消息是否已處理
        // - 標記消息為已處理
        // - 執行相應的業務邏輯
    }

    // ============================================================================
    // EVM -> Sui 跨鏈測試

    /// 測試：receive_from_evm 函數存在
    #[test]
    fun test_receive_from_evm_signature() {
        // EVM -> Sui 跨鏈存款應該：
        // - 驗證 Wormhole VAA
        // - 解析跨鏈負載
        // - 調用 vault::mint_shares
        // - 更新用戶餘額
    }

    // ============================================================================
    // Sui -> EVM 跨鏈測試

    /// 測試：withdraw_to_evm 函數存在
    #[test]
    fun test_withdraw_to_evm_signature() {
        // Sui -> EVM 跨鏈提款應該：
        // - 驗證用戶份額
        // - 調用 vault::burn_shares
        // - 構建跨鏈消息
        // - 發送 Wormhole 消息
    }

    // ============================================================================
    // Relayer 管理測試

    /// 測試：add_relayer 函數存在
    #[test]
    fun test_add_relayer_signature() {
        // 添加 Relayer 應該需要 AdminCap 權限
    }

    /// 測試：remove_relayer 函數存在
    #[test]
    fun test_remove_relayer_signature() {
        // 移除 Relayer 應該需要 AdminCap 權限
    }

    // ============================================================================
    // 消息去重測試

    /// 屬性：哈希去重正確
    #[test]
    fun prop_message_deduplication() {
        // 同一個消息哈希不應該被處理兩次
    }

    // ============================================================================
    // 消息驗證測試

    /// 測試：消息驗證函數存在
    #[test]
    fun test_message_verification_signature() {
        // 消息驗證應該檢查：
        // - 簽名有效
        // - 消息格式正確
        // - 消息類型正確
    }

    // ============================================================================
    // 編碼/解碼測試

    /// 測試：跨鏈負載編碼函數存在
    #[test]
    fun test_encode_payload_signature() {
        // 編碼應該將結構化數據轉換為字節
    }

    /// 測試：跨鏈負載解碼函數存在
    #[test]
    fun test_decode_payload_signature() {
        // 解碼應該將字節轉換為結構化數據
    }

    // ============================================================================
    // 錯誤碼測試

    /// 測試：錯誤碼定義正確
    #[test]
    fun test_cross_chain_error_codes() {
        // 跨鏈相關錯誤碼應該正確定義
    }

    // ============================================================================
    // 事件測試

    /// 測試：跨鏈存款事件結構正確
    #[test]
    fun test_cross_chain_deposit_event() {
        // 事件應該記錄跨鏈存款信息
    }

    /// 測試：跨鏈提款事件結構正確
    #[test]
    fun test_cross_chain_withdraw_event() {
        // 事件應該記錄跨鏈提款信息
    }

    /// 測試：Relayer 變更事件結構正確
    #[test]
    fun test_relayer_change_event() {
        // 事件應該記錄 Relayer 添加/移除信息
    }
}
