/// Safety Module - 安全與風控
/// 負責金庫的安全檢查和風控邏輯
#[allow(unused_const, unused_field, duplicate_alias)]
module lantern_vault::safety;

use sui::tx_context::{TxContext, sender};
use lantern_vault::admin::Config;
use lantern_vault::admin;
use lantern_vault::vault;
use lantern_vault::vault::Vault;
use lantern_vault::vault::UserPosition;
use std::type_name;

// ============================================================================
// 錯誤碼

const EInvalidToken: u64 = 300;
const EPaused: u64 = 301;
const EMinDepositNotMet: u64 = 302;
const EInsufficientShares: u64 = 303;
const EMaxDepositExceeded: u64 = 304;
const EMaxWithdrawExceeded: u64 = 305;
const ERateLimitExceeded: u64 = 306;
const ESlippageExceeded: u64 = 307;

// ============================================================================
// 事件

/// 大額交易預警事件
public struct LargeTransactionAlert has copy, drop {
    user: address,
    amount: u64,
    total_assets: u64,
    threshold_bps: u64,
    timestamp: u64,
}

/// 速率限制觸發事件
public struct RateLimitTriggered has copy, drop {
    user: address,
    action_count: u64,
    window_ms: u64,
    timestamp: u64,
}

// ============================================================================
// 安全檢查函數

/// 驗證 Token 是否在白名單
public fun verify_token<T>(_vault: &Vault<T>) {
    assert!(
        type_name::with_defining_ids<T>() == vault::get_wusdc_type(_vault),
        EInvalidToken
    );
}

/// 存款時的安全檢查
public fun deposit_safety_check<T>(
    vault: &Vault<T>,
    config: &Config,
    amount: u64,
    ctx: &mut TxContext
) {
    // 1. 檢查合約是否暫停
    assert!(!admin::is_paused(config), EPaused);

    // 2. 檢查存款金額 - 最低
    assert!(amount >= admin::get_min_deposit(config), EMinDepositNotMet);

    // 3. 檢查存款金額 - 最高
    let max_deposit = admin::get_max_deposit(config);
    if (max_deposit > 0) {
        assert!(amount <= max_deposit, EMaxDepositExceeded);
    };

    // 4. 驗證 Token
    verify_token(vault);

    // 5. 大額交易預警檢查
    let total_assets = vault::get_total_assets(vault);
    check_large_transaction(
        sender(ctx),
        amount,
        total_assets,
        admin::get_large_tx_threshold(config),
        ctx
    );
}

/// 提款時的安全檢查（包含最大金額檢查）
public fun withdraw_safety_check<T>(
    vault: &Vault<T>,
    config: &Config,
    shares: u64,
    user_pos: &UserPosition,
    _ctx: &mut TxContext
) {
    // 1. 檢查份額餘額
    assert!(vault::get_shares(user_pos) >= shares, EInsufficientShares);

    // 2. 計算可贖回金額
    let total_assets = vault::get_total_assets(vault);
    let total_shares = vault::get_total_shares(vault);
    let withdraw_amount = calculate_assets(shares, total_assets, total_shares);

    // 3. 檢查最大提款金額
    let max_withdraw = admin::get_max_withdraw(config);
    if (max_withdraw > 0) {
        assert!(withdraw_amount <= max_withdraw, EMaxWithdrawExceeded);
    };

    // 注意：暫停時通常仍允許提款
    // 如果需要禁止提款，可添加：
    // assert!(!config.paused, EPaused);
}

/// 批量提款安全檢查
public fun batch_withdraw_safety_check<T>(
    vault: &Vault<T>,
    config: &Config,
    shares: u64,
    user_pos: &UserPosition,
    ctx: &mut TxContext
) {
    // 與普通提款相同的檢查
    withdraw_safety_check(vault, config, shares, user_pos, ctx);
}

// ============================================================================
// 速率限制

/// 速率限制檢查
/// 注意：此函數需要在 UserPosition 中記錄時間戳
/// 由於當前 UserPosition 沒有這個字段，這是簡化版本
public fun check_rate_limit(
    _config: &Config,
    _user_pos: &UserPosition,
    _ctx: &mut TxContext
) {
    // 簡化實現：實際需要記錄用戶的上次操作時間
    // 完整的速率限制需要：
    // 1. 在 UserPosition 中添加 last_action_time 和 action_count
    // 2. 在每次操作時檢查時間窗口
    // 3. 如果超過窗口則重置計數
}

// ============================================================================
// 滑點保護

/// 計算最低接收金額（滑點保護）
/// shares: 要贖回的份額
/// total_shares: 總份額
/// total_assets: 總資產
/// slippage_bps: 允許的最大滑點（basis points），如 100 = 1%
public fun calculate_min_receive(
    shares: u64,
    total_shares: u64,
    total_assets: u64,
    slippage_bps: u64
): u64 {
    let assets = calculate_assets(shares, total_shares, total_assets);
    // 最小接收 = 資產 * (10000 - slippage_bps) / 10000
    let min_receive = (assets * (10000 - slippage_bps)) / 10000;
    min_receive
}

/// 滑點保護檢查
/// 實際收到的金額必須 >= 最小預期金額
public fun check_slippage(
    actual_received: u64,
    min_expected: u64
) {
    assert!(actual_received >= min_expected, ESlippageExceeded);
}

// ============================================================================
// 大額交易預警

/// 大額交易預警檢查
/// 當交易金額超過總資產的閾值時觸發預警
public fun check_large_transaction(
    user: address,
    amount: u64,
    total_assets: u64,
    threshold_bps: u64,
    ctx: &mut TxContext
) {
    if (total_assets == 0) {
        return
    };

    // 計算閾值金額
    let threshold_amount = (total_assets * threshold_bps) / 10000;

    if (amount > threshold_amount) {
        sui::event::emit(LargeTransactionAlert {
            user,
            amount,
            total_assets,
            threshold_bps,
            timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
        });
    }
}

// ============================================================================
// 輔助函數

/// 計算份額對應的資產（從 vault 模組拷貝過來以便獨立使用）
/// 這裡使用簡化的線性計算
fun calculate_assets(
    shares: u64,
    total_assets: u64,
    total_shares: u64
): u64 {
    if (total_shares == 0 || total_assets == 0) {
        return shares  // 首次存款按 1:1
    };

    // assets = shares * total_assets / total_shares
    (shares * total_assets) / total_shares
}
