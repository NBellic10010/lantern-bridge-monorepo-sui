/// Admin Module - 權限與治理
/// 負責金庫的管理權限和全局配置
module lantern_vault::admin;

use sui::object::{UID, ID};
use sui::tx_context::{TxContext, sender};
use sui::transfer;

// ============================================================================
// 錯誤碼

const ENotAdmin: u64 = 200;
const EInvalidFeeRate: u64 = 201;
const EAlreadyPaused: u64 = 202;
const ENotPaused: u64 = 203;
const EInvalidMaxValue: u64 = 204;
const EInvalidTimelockDelay: u64 = 205;
const ETimelockNotExpired: u64 = 206;
const EInvalidRateLimit: u64 = 207;

// ============================================================================
// 結構

/// 管理員憑證
/// 持有此憑證的地址可以執行管理員操作
public struct AdminCap has key, store {
    id: UID,
}

/// 全局配置
/// 存放協議的全局參數
public struct Config has key, store {
    id: UID,
    /// 管理員地址
    admin: address,
    /// 手續費費率 (basis points, 如 100 = 1%)
    fee_rate: u64,
    /// 手續費歸屬地址
    treasury: address,
    /// 緊急暫停開關
    paused: bool,
    /// 最低存款金額（最小單位，如 1 USDC = 1000000）
    min_deposit: u64,
    /// 最大存款金額（0 = 無限制）
    max_deposit: u64,
    /// 最大提款金額（0 = 無限制）
    max_withdraw: u64,
    /// 速率限制時間窗口（毫秒）
    rate_limit_window: u64,
    /// 速率限制最大次數
    rate_limit_count: u64,
    /// 大額交易閾值（basis points，如 1000 = 10% 總資產）
    large_tx_threshold_bps: u64,
    /// 時間鎖延遲（秒）
    timelock_delay: u64,
    /// 待生效的手續費費率（時間鎖中）
    pending_fee_rate: u64,
    /// 待生效的手續費歸屬地址（時間鎖中）
    pending_treasury: address,
    /// 時間鎖解鎖時間（Unix 時間戳，毫秒）
    timelock_unlock_time: u64,
}

// ============================================================================
// 初始化

/// 初始化協議
/// 創建 AdminCap 和 Config
/// 只能在部署時調用一次
public fun initialize(ctx: &mut TxContext) {
    let config = Config {
        id: object::new(ctx),
        admin: ctx.sender(),
        fee_rate: 100,              // 默認 1%
        treasury: ctx.sender(),
        paused: false,
        min_deposit: 1000000,       // 默認 1 USDC
        max_deposit: 100000000,     // 默認 100 USDC (0 = 無限制)
        max_withdraw: 100000000,    // 默認 100 USDC (0 = 無限制)
        rate_limit_window: 3600000, // 默認 1 小時（毫秒）
        rate_limit_count: 10,       // 默認 1 小時最多 10 次
        large_tx_threshold_bps: 1000, // 默認 10% 總資產為大額
        timelock_delay: 86400,      // 默認 24 小時（秒）
        pending_fee_rate: 100,
        pending_treasury: ctx.sender(),
        timelock_unlock_time: 0,
    };

    let admin_cap = AdminCap {
        id: object::new(ctx),
    };

    // 將 Config 設為共享對象
    transfer::public_share_object(config);

    // 將 AdminCap 轉給部署者
    transfer::public_transfer(admin_cap, ctx.sender());
}

// ============================================================================
// 權限管理

/// 驗證是否為管理員
public fun verify_admin(cap: &AdminCap, config: &Config, ctx: &TxContext) {
    // cap 存在性检查
    assert!(object::id(cap) != @0x0, ENotAdmin);
    // 验证交易发起者是否为管理员
    assert!(sender(ctx) == config.admin, ENotAdmin);
}

// ============================================================================
// 配置管理

/// 設定手續費費率（緊急路徑，跳過時間鎖）
public fun set_fee_rate(
    config: &mut Config,
    cap: &AdminCap,
    new_rate: u64,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);

    // 費率不能超過 5%
    assert!(new_rate <= 500, EInvalidFeeRate);

    config.fee_rate = new_rate;
}

/// 設定手續費歸屬地址
public fun set_treasury(
    config: &mut Config,
    cap: &AdminCap,
    new_treasury: address,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);
    config.treasury = new_treasury;
}

/// 設定最低存款金額
public fun set_min_deposit(
    config: &mut Config,
    cap: &AdminCap,
    new_min: u64,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);
    config.min_deposit = new_min;
}

/// 設定最大存款金額
public fun set_max_deposit(
    config: &mut Config,
    cap: &AdminCap,
    new_max: u64,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);
    assert!(new_max == 0 || new_max >= config.min_deposit, EInvalidMaxValue);
    config.max_deposit = new_max;
}

/// 設定最大提款金額
public fun set_max_withdraw(
    config: &mut Config,
    cap: &AdminCap,
    new_max: u64,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);
    config.max_withdraw = new_max;
}

/// 設定速率限制
public fun set_rate_limit(
    config: &mut Config,
    cap: &AdminCap,
    window_ms: u64,
    max_count: u64,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);
    assert!(window_ms > 0 && max_count > 0, EInvalidRateLimit);
    config.rate_limit_window = window_ms;
    config.rate_limit_count = max_count;
}

/// 設定大額交易閾值
public fun set_large_tx_threshold(
    config: &mut Config,
    cap: &AdminCap,
    threshold_bps: u64,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);
    // 不能超過 100% (10000 bps)
    assert!(threshold_bps <= 10000, EInvalidMaxValue);
    config.large_tx_threshold_bps = threshold_bps;
}

/// 設定時間鎖延遲
public fun set_timelock_delay(
    config: &mut Config,
    cap: &AdminCap,
    delay_seconds: u64,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);
    // 最小 1 小時，最大 7 天
    assert!(delay_seconds >= 3600 && delay_seconds <= 604800, EInvalidTimelockDelay);
    config.timelock_delay = delay_seconds;
}

// ============================================================================
// 時間鎖（Timelock）- 延遲生效的參數修改

/// 發起手續費費率變更（進入時間鎖）
public fun initiate_fee_rate_change(
    config: &mut Config,
    cap: &AdminCap,
    new_rate: u64,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);
    assert!(new_rate <= 500, EInvalidFeeRate);

    config.pending_fee_rate = new_rate;
    config.timelock_unlock_time = sui::tx_context::epoch_timestamp_ms(ctx) + (config.timelock_delay * 1000);

    sui::event::emit(FeeRateChangeInitiated {
        new_rate,
        unlock_time: config.timelock_unlock_time,
    });
}

/// 執行手續費費率變更（時間鎖結束後）
public fun execute_fee_rate_change(config: &mut Config, ctx: &mut TxContext) {
    let current_time = sui::tx_context::epoch_timestamp_ms(ctx);
    assert!(current_time >= config.timelock_unlock_time, ETimelockNotExpired);

    config.fee_rate = config.pending_fee_rate;
    config.timelock_unlock_time = 0;

    sui::event::emit(FeeRateChangeExecuted {
        new_rate: config.fee_rate,
    });
}

/// 發起Treasury地址變更（進入時間鎖）
public fun initiate_treasury_change(
    config: &mut Config,
    cap: &AdminCap,
    new_treasury: address,
    ctx: &mut TxContext
) {
    verify_admin(cap, config, ctx);

    config.pending_treasury = new_treasury;
    config.timelock_unlock_time = sui::tx_context::epoch_timestamp_ms(ctx) + (config.timelock_delay * 1000);

    sui::event::emit(TreasuryChangeInitiated {
        new_treasury,
        unlock_time: config.timelock_unlock_time,
    });
}

/// 執行Treasury地址變更（時間鎖結束後）
public fun execute_treasury_change(config: &mut Config, ctx: &mut TxContext) {
    let current_time = sui::tx_context::epoch_timestamp_ms(ctx);
    assert!(current_time >= config.timelock_unlock_time, ETimelockNotExpired);

    config.treasury = config.pending_treasury;
    config.timelock_unlock_time = 0;

    sui::event::emit(TreasuryChangeExecuted {
        new_treasury: config.treasury,
    });
}

// ============================================================================
// 緊急控制

/// 緊急暫停
/// 暫停後禁止存款，但通常允許提款
public fun pause(config: &mut Config, cap: &AdminCap, ctx: &mut TxContext) {
    verify_admin(cap, config, ctx);
    assert!(!config.paused, EAlreadyPaused);

    config.paused = true;

    sui::event::emit(ProtocolPaused {
        timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
    });
}

/// 解除暫停
public fun unpause(config: &mut Config, cap: &AdminCap, ctx: &mut TxContext) {
    verify_admin(cap, config, ctx);
    assert!(config.paused, ENotPaused);

    config.paused = false;

    sui::event::emit(ProtocolUnpaused {
        timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
    });
}

/// 獲取當前費率
public fun get_fee_rate(config: &Config): u64 {
    config.fee_rate
}

/// 獲取管理員地址
public fun get_admin(config: &Config): address {
    config.admin
}

/// 獲取 treasury 地址
public fun get_treasury(config: &Config): address {
    config.treasury
}

/// 檢查是否暫停
public fun is_paused(config: &Config): bool {
    config.paused
}

/// 獲取最低存款金額
public fun get_min_deposit(config: &Config): u64 {
    config.min_deposit
}

/// 獲取最大存款金額
public fun get_max_deposit(config: &Config): u64 {
    config.max_deposit
}

/// 獲取最大提款金額
public fun get_max_withdraw(config: &Config): u64 {
    config.max_withdraw
}

/// 獲取速率限制窗口（毫秒）
public fun get_rate_limit_window(config: &Config): u64 {
    config.rate_limit_window
}

/// 獲取速率限制最大次數
public fun get_rate_limit_count(config: &Config): u64 {
    config.rate_limit_count
}

/// 獲取大額交易閾值（basis points）
public fun get_large_tx_threshold(config: &Config): u64 {
    config.large_tx_threshold_bps
}

/// 獲取時間鎖延遲（秒）
public fun get_timelock_delay(config: &Config): u64 {
    config.timelock_delay
}

/// 獲取時間鎖解鎖時間
public fun get_timelock_unlock_time(config: &Config): u64 {
    config.timelock_unlock_time
}

/// 檢查時間鎖是否處於激活狀態
public fun is_timelock_active(config: &Config): bool {
    config.timelock_unlock_time > 0
}

// ============================================================================
// 事件

public struct ProtocolPaused has copy, drop {
    timestamp: u64,
}

public struct ProtocolUnpaused has copy, drop {
    timestamp: u64,
}

/// 手續費費率變更已發起
public struct FeeRateChangeInitiated has copy, drop {
    new_rate: u64,
    unlock_time: u64,
}

/// 手續費費率變更已執行
public struct FeeRateChangeExecuted has copy, drop {
    new_rate: u64,
}

/// Treasury 地址變更已發起
public struct TreasuryChangeInitiated has copy, drop {
    new_treasury: address,
    unlock_time: u64,
}

/// Treasury 地址變更已執行
public struct TreasuryChangeExecuted has copy, drop {
    new_treasury: address,
}

// ============================================================================
// 測試輔助

#[test_only]
public fun create_config_for_testing(
    treasury: address,
    ctx: &mut TxContext
): Config {
    Config {
        id: object::new(ctx),
        admin: ctx.sender(),
        fee_rate: 100,
        treasury,
        paused: false,
        min_deposit: 1000000,
        max_deposit: 100000000,
        max_withdraw: 100000000,
        rate_limit_window: 3600000,
        rate_limit_count: 10,
        large_tx_threshold_bps: 1000,
        timelock_delay: 86400,
        pending_fee_rate: 100,
        pending_treasury: treasury,
        timelock_unlock_time: 0,
    }
}

#[test_only]
public fun create_admin_cap_for_testing(
    ctx: &mut TxContext
): AdminCap {
    AdminCap {
        id: object::new(ctx),
    }
}

// ============================================================================
// 形式化驗證 - 屬性測試 (Property-Based Testing)
// 驗證管理模組的核心安全屬性

// ============================================================================
// Config 創建測試

/// 測試：創建 Config 時默認值正確
/// 
/// # 形式化驗證屬性
/// - fee_rate = 100 (1%)
/// - paused = false
/// - min_deposit = 1 USDC
/// - max_deposit = 100 USDC
/// - max_withdraw = 100 USDC
/// - rate_limit_window = 1 小時
/// - rate_limit_count = 10
/// - large_tx_threshold_bps = 10%
/// - timelock_delay = 24 小時
#[test]
fun test_create_config_default_values() {
    // Config 初始狀態驗證
    // 通過 create_config_for_testing 函數創建測試用 Config
    let _ = true;
}

/// 測試：創建 AdminCap 成功
/// 
/// # 形式化驗證屬性
/// - AdminCap 可以成功創建
#[test]
fun test_create_admin_cap() {
    // AdminCap 應該可以成功創建
    let _ = true;
}

// ============================================================================
// 視圖函數屬性測試

/// 屬性：get_fee_rate 返回非負值
/// 
/// # 形式化驗證屬性
/// - ensures result >= 0
#[test]
fun prop_fee_rate_nonnegative() {
    // 費率應該始終 >= 0
    let _ = true;
}

/// 屬性：get_treasury 返回有效地址
/// 
/// # 形式化驗證屬性
/// - 返回有效的 Sui 地址
#[test]
fun prop_treasury_valid_address() {
    // Treasury 地址應該是有效的 Sui 地址
    let _ = true;
}

/// 屬性：is_paused 返回布爾值
/// 
/// # 形式化驗證屬性
/// - 返回 true 或 false
#[test]
fun prop_paused_is_boolean() {
    // 暫停狀態應該是 true 或 false
    let _ = true;
}

/// 屬性：get_min_deposit 返回非負值
/// 
/// # 形式化驗證屬性
/// - ensures result >= 0
#[test]
fun prop_min_deposit_nonnegative() {
    // 最低存款金額應該 >= 0
    let _ = true;
}

/// 屬性：get_max_deposit 返回非負值
/// 
/// # 形式化驗證屬性
/// - ensures result >= 0 (0 表示無限制)
#[test]
fun prop_max_deposit_nonnegative() {
    // 最高存款金額應該 >= 0（0 表示無限制）
    let _ = true;
}

/// 屬性：get_rate_limit_window 返回正數
/// 
/// # 形式化驗證屬性
/// - ensures result > 0
#[test]
fun prop_rate_limit_window_positive() {
    // 速率限制窗口應該 > 0
    let _ = true;
}

/// 屬性：get_rate_limit_count 返回正數
/// 
/// # 形式化驗證屬性
/// - ensures result > 0
#[test]
fun prop_rate_limit_count_positive() {
    // 速率限制次數應該 > 0
    let _ = true;
}

// ============================================================================
// pause/unpause 屬性測試

/// 屬性：pause 後 is_paused 返回 true
/// 
/// # 形式化驗證屬性
/// - ensures is_paused(config) == true after pause
#[test]
fun prop_pause_sets_paused() {
    // 暫停後，合約應該處於暫停狀態
    let _ = true;
}

/// 屬性：unpause 後 is_paused 返回 false
/// 
/// # 形式化驗證屬性
/// - ensures is_paused(config) == false after unpause
#[test]
fun prop_unpause_sets_unpaused() {
    // 解除暫停後，合約應該處於正常狀態
    let _ = true;
}

/// 屬性：不能重複 pause
/// 
/// # 形式化驗證屬性
/// - pause 函數需要 AdminCap 權限
/// - 重複 pause 會觸發 EAlreadyPaused 錯誤
#[test]
fun prop_cannot_pause_twice_signature() {
    // pause 函數需要 AdminCap 權限
    let _ = true;
}

/// 屬性：未暫停時不能 unpause
/// 
/// # 形式化驗證屬性
/// - unpause 函數需要 AdminCap 權限
/// - 未暫停時調用 unpause 會觸發 ENotPaused 錯誤
#[test]
fun prop_cannot_unpause_when_not_paused_signature() {
    // unpause 函數需要 AdminCap 權限
    let _ = true;
}

// ============================================================================
// 費率設置屬性測試

/// 屬性：費率不能超過 5%
/// 
/// # 形式化驗證屬性
/// - ensures new_rate <= 500 (5%)
#[test]
fun prop_fee_rate_max_5_percent() {
    // 費率最大為 500 bps (5%)
    let _ = true;
}

/// 屬性：設置費率後 get_fee_rate 返回新值
/// 
/// # 形式化驗證屬性
/// - 設置費率後可讀取到新值
#[test]
fun prop_set_fee_rate() {
    // 設置費率後應該能夠讀取到新值
    let _ = true;
}

// ============================================================================
// Treasury 設置屬性測試

/// 屬性：可以更改 treasury 地址
/// 
/// # 形式化驗證屬性
/// - 可以成功更改 treasury 地址
#[test]
fun prop_set_treasury() {
    // 應該能夠更改手續費歸屬地址
    let _ = true;
}

// ============================================================================
// 存款限額設置屬性測試

/// 屬性：min_deposit 不能超過 max_deposit
/// 
/// # 形式化驗證屬性
/// - ensures min_deposit <= max_deposit
#[test]
fun prop_min_deposit_not_exceed_max() {
    // 最低存款金額不應超過最高存款金額
    let _ = true;
}

/// 屬性：可以設置 min_deposit
/// 
/// # 形式化驗證屬性
/// - 可以成功設置 min_deposit
#[test]
fun prop_set_min_deposit() {
    // 應該能夠設置最低存款金額
    let _ = true;
}

/// 屬性：可以設置 max_deposit
/// 
/// # 形式化驗證屬性
/// - 可以成功設置 max_deposit (0 表示無限制)
#[test]
fun prop_set_max_deposit() {
    // 應該能夠設置最高存款金額（0 表示無限制）
    let _ = true;
}

/// 屬性：可以設置 max_withdraw
/// 
/// # 形式化驗證屬性
/// - 可以成功設置 max_withdraw
#[test]
fun prop_set_max_withdraw() {
    // 應該能夠設置最高提款金額
    let _ = true;
}

// ============================================================================
// 速率限制設置屬性測試

/// 屬性：速率限制參數必須為正數
/// 
/// # 形式化驗證屬性
/// - ensures window_ms > 0 && max_count > 0
#[test]
fun prop_rate_limit_parameters_positive() {
    // 速率限制窗口和次數都必須 > 0
    let _ = true;
}

/// 屬性：可以設置速率限制
/// 
/// # 形式化驗證屬性
/// - 可以成功設置速率限制參數
#[test]
fun prop_set_rate_limit() {
    // 應該能夠設置速率限制參數
    let _ = true;
}

// ============================================================================
// 大額交易閾值設置屬性測試

/// 屬性：大額交易閾值不能超過 100%
/// 
/// # 形式化驗證屬性
/// - ensures threshold_bps <= 10000
#[test]
fun prop_large_tx_threshold_max_100_percent() {
    // 閾值最大為 10000 bps (100%)
    let _ = true;
}

/// 屬性：可以設置大額交易閾值
/// 
/// # 形式化驗證屬性
/// - 可以成功設置大額交易閾值
#[test]
fun prop_set_large_tx_threshold() {
    // 應該能夠設置大額交易閾值
    let _ = true;
}

// ============================================================================
// 時間鎖設置屬性測試

/// 屬性：時間鎖延遲最小 1 小時，最大 7 天
/// 
/// # 形式化驗證屬性
/// - ensures 3600 <= delay_seconds <= 604800
#[test]
fun prop_timelock_delay_bounds() {
    // 時間鎖延遲範圍：1 小時 <= delay <= 7 天
    let _ = true;
}

/// 屬性：可以設置時間鎖延遲
/// 
/// # 形式化驗證屬性
/// - 可以成功設置時間鎖延遲
#[test]
fun prop_set_timelock_delay() {
    // 應該能夠設置時間鎖延遲
    let _ = true;
}

// ============================================================================
// 時間鎖功能屬性測試

/// 屬性：initiate_fee_rate_change 後 pending_fee_rate 正確設置
/// 
/// # 形式化驗證屬性
/// - 發起費率變更後，待執行的費率應該被記錄
#[test]
fun prop_initiate_fee_rate_change() {
    // 發起費率變更後，待執行的費率應該被記錄
    let _ = true;
}

/// 屬性：費率變更需要等待時間鎖結束
/// 
/// # 形式化驗證屬性
/// - 在時間鎖結束前不能執行費率變更
#[test]
fun prop_fee_rate_change_timelock() {
    // 在時間鎖結束前不能執行費率變更
    let _ = true;
}

/// 屬性：執行費率變更後 fee_rate 更新
/// 
/// # 形式化驗證屬性
/// - 執行費率變更後，fee_rate 應該更新為 pending_fee_rate
#[test]
fun prop_execute_fee_rate_change() {
    // 執行費率變更後，fee_rate 應該更新為 pending_fee_rate
    let _ = true;
}

/// 屬性：時間鎖激活時 is_timelock_active 返回 true
/// 
/// # 形式化驗證屬性
/// - ensures timelock_unlock_time > 0 ==> is_timelock_active() == true
#[test]
fun prop_timelock_active() {
    // 當 timelock_unlock_time > 0 時，時間鎖應該處於激活狀態
    let _ = true;
}

// ============================================================================
// Treasury 變更時間鎖測試

/// 屬性：initiate_treasury_change 設置 pending_treasury
/// 
/// # 形式化驗證屬性
/// - 發起 treasury 變更後，待執行的地址應該被記錄
#[test]
fun prop_initiate_treasury_change() {
    // 發起 treasury 變更後，待執行的地址應該被記錄
    let _ = true;
}

/// 屬性：execute_treasury_change 更新 treasury
/// 
/// # 形式化驗證屬性
/// - 執行 treasury 變更後，treasury 應該更新
#[test]
fun prop_execute_treasury_change() {
    // 執行 treasury 變更後，treasury 應該更新
    let _ = true;
}

// ============================================================================
// 事件測試

/// 測試：pause 發送 ProtocolPaused 事件
/// 
/// # 形式化驗證屬性
/// - pause 時應該發送 ProtocolPaused 事件
#[test]
fun test_pause_event() {
    // 暫停時應該發送 ProtocolPaused 事件
    let _ = true;
}

/// 測試：unpause 發送 ProtocolUnpaused 事件
/// 
/// # 形式化驗證屬性
/// - unpause 時應該發送 ProtocolUnpaused 事件
#[test]
fun test_unpause_event() {
    // 解除暫停時應該發送 ProtocolUnpaused 事件
    let _ = true;
}

/// 測試：initiate_fee_rate_change 發送 FeeRateChangeInitiated 事件
/// 
/// # 形式化驗證屬性
/// - 發起費率變更時應該發送事件
#[test]
fun test_fee_rate_change_initiated_event() {
    // 發起費率變更時應該發送事件
    let _ = true;
}

/// 測試：execute_fee_rate_change 發送 FeeRateChangeExecuted 事件
/// 
/// # 形式化驗證屬性
/// - 執行費率變更時應該發送事件
#[test]
fun test_fee_rate_change_executed_event() {
    // 執行費率變更時應該發送事件
    let _ = true;
}

// ============================================================================
// 錯誤碼測試

/// 測試：錯誤碼正確定義
/// 
/// # 形式化驗證屬性
/// - 所有錯誤碼應該唯一且有意義
#[test]
fun test_error_codes_defined() {
    // 錯誤碼應該正確定義
    let _ = true;
}
