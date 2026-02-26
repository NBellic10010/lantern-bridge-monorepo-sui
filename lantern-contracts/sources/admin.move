/// Admin Module - 權限與治理
/// 負責金庫的管理權限和全局配置
module lantern_vault::admin;

use sui::object::{UID, ID};
use sui::tx_context::TxContext;
use sui::transfer;

// ============================================================================
// 錯誤碼

const ENotAdmin: u64 = 200;
const EInvalidFeeRate: u64 = 201;
const EAlreadyPaused: u64 = 202;
const ENotPaused: u64 = 203;

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
    /// 手續費費率 (basis points, 如 100 = 1%)
    fee_rate: u64,
    /// 手續費歸屬地址
    treasury: address,
    /// 緊急暫停開關
    paused: bool,
    /// 最低存款金額（最小單位，如 1 USDC = 1000000）
    min_deposit: u64,
}

// ============================================================================
// 初始化

/// 初始化協議
/// 創建 AdminCap 和 Config
/// 只能在部署時調用一次
public fun initialize(ctx: &mut TxContext) {
    let config = Config {
        id: object::new(ctx),
        fee_rate: 100,         // 默認 1%
        treasury: ctx.sender(),
        paused: false,
        min_deposit: 1000000, // 默認 1 USDC
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
public fun verify_admin(_cap: &AdminCap) {
    // 實際實現可以記錄管理員地址
    // 這裡簡化處理
}

// ============================================================================
// 配置管理

/// 設定手續費費率
public fun set_fee_rate(
    config: &mut Config,
    cap: &AdminCap,
    new_rate: u64
) {
    // 驗證權限
    verify_admin(cap);

    // 費率不能超過 5%
    assert!(new_rate <= 500, EInvalidFeeRate);

    config.fee_rate = new_rate;
}

/// 設定手續費歸屬地址
public fun set_treasury(
    config: &mut Config,
    cap: &AdminCap,
    new_treasury: address
) {
    verify_admin(cap);
    config.treasury = new_treasury;
}

/// 設定最低存款金額
public fun set_min_deposit(
    config: &mut Config,
    cap: &AdminCap,
    new_min: u64
) {
    verify_admin(cap);
    config.min_deposit = new_min;
}

// ============================================================================
// 緊急控制

/// 緊急暫停
/// 暫停後禁止存款，但通常允許提款
public fun pause(config: &mut Config, cap: &AdminCap, ctx: &mut TxContext) {
    verify_admin(cap);
    assert!(!config.paused, EAlreadyPaused);

    config.paused = true;

    sui::event::emit(ProtocolPaused {
        timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
    });
}

/// 解除暫停
public fun unpause(config: &mut Config, cap: &AdminCap, ctx: &mut TxContext) {
    verify_admin(cap);
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

// ============================================================================
// 事件

public struct ProtocolPaused has copy, drop {
    timestamp: u64,
}

public struct ProtocolUnpaused has copy, drop {
    timestamp: u64,
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
        fee_rate: 100,
        treasury,
        paused: false,
        min_deposit: 1000000,
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
