/// Safety Module - 安全與風控
/// 負責金庫的安全檢查和風控邏輯
module lantern_vault::safety;

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
    amount: u64
) {
    // 1. 檢查合約是否暫停
    assert!(!admin::is_paused(config), EPaused);

    // 2. 檢查存款金額
    assert!(amount >= admin::get_min_deposit(config), EMinDepositNotMet);

    // 3. 驗證 Token
    verify_token(vault);
}

/// 提款時的安全檢查
public fun withdraw_safety_check<T>(
    _vault: &Vault<T>,
    _config: &Config,
    shares: u64,
    user_pos: &UserPosition
) {
    // 1. 檢查份額餘額
    assert!(vault::get_shares(user_pos) >= shares, EInsufficientShares);

    // 注意：暫停時通常仍允許提款
    // 如果需要禁止提款，可添加：
    // assert!(!config.paused, EPaused);
}

/// 批量提款安全檢查
public fun batch_withdraw_safety_check<T>(
    vault: &Vault<T>,
    _config: &Config,
    shares: u64,
    user_pos: &UserPosition
) {
    // 與普通提款相同的檢查
    withdraw_safety_check(vault, _config, shares, user_pos);
}
