/// Vault Core Module - 核心金庫邏輯
/// 實現 ERC-4626 標準的份額記帳模型
module lantern_vault::vault;

use sui::coin::{Coin, TreasuryCap};
use sui::balance::{Self, Balance, Supply};
use sui::object::{UID, ID};
use sui::tx_context::{TxContext, sender};
use sui::transfer;
use std::type_name;
use lantern_vault::math;
// use lantern_vault::yield; // TODO: 启用yield模块

// ============================================================================
// 錯誤碼

const EInvalidToken: u64 = 0;
const EInsufficientShares: u64 = 1;
const EPaused: u64 = 2;
const EZeroAmount: u64 = 3;
const EMinDepositNotMet: u64 = 4;
const EInvalidFeeRate: u64 = 5;

// ============================================================================
// 事件定義

/// 存款事件
public struct DepositEvent has copy, drop {
    user: address,
    amount: u64,
    shares: u64,
    timestamp: u64,
}

/// 提款事件
public struct WithdrawEvent has copy, drop {
    user: address,
    shares: u64,
    amount: u64,
    fee: u64,
    timestamp: u64,
}

// ============================================================================
// 核心結構

/// 金庫主結構
/// 使用 ERC-4626 標準的份額記帳模型
public struct Vault<phantom T> has key, store {
    id: UID,
    /// 總份額 (totalShares)
    total_shares: u64,
    /// 累計存入的資產價值 (totalAssets)，包含本金+利息
    total_assets: u64,
    /// Navi 生成的生息憑證 (nUSDC)
    n_token: Balance<T>,
    /// 官方 Wormhole wUSDC Type（白名單）
    wusdc_type: type_name::TypeName,
}

/// 用戶份額記錄
public struct UserPosition has key, store {
    id: UID,
    user: address,
    shares: u64,
    deposit_timestamp: u64,
}

// ============================================================================
// 初始化

/// 創建金庫（只能調用一次）
public fun create_vault<T>(
    wusdc_type: type_name::TypeName,
    ctx: &mut TxContext
): (Vault<T>, UserPosition) {
    let vault = Vault<T> {
        id: object::new(ctx),
        total_shares: 0,
        total_assets: 0,
        n_token: balance::zero<T>(),
        wusdc_type,
    };

    let user_pos = UserPosition {
        id: object::new(ctx),
        user: ctx.sender(),
        shares: 0,
        deposit_timestamp: 0,
    };

    (vault, user_pos)
}

// ============================================================================
// 存款功能

/// 存款入口
public fun deposit<T>(
    vault: &mut Vault<T>,
    user_pos: &mut UserPosition,
    wusdc: Coin<T>,
    ctx: &mut TxContext
) {
    let amount = wusdc.value();
    assert!(amount > 0, EZeroAmount);

    // 1. 驗證 Token Type（白名單）
    assert!(type_name::get<T>() == vault.wusdc_type, EInvalidToken);

    // 2. 計算份額
    let shares = math::calculate_shares(amount, vault.total_assets, vault.total_shares);

    // 3. 存入 Navi，獲取 nUSDC
    // 將 Coin 轉換為 Balance
    let n_token = wusdc.into_balance();

    // 4. 更新 Vault 狀態
    vault.total_assets = vault.total_assets + amount;
    vault.total_shares = vault.total_shares + shares;
    balance::join(&mut vault.n_token, n_token);

    // 5. 更新用戶份額
    user_pos.shares = user_pos.shares + shares;
    if (user_pos.deposit_timestamp == 0) {
        user_pos.deposit_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
    }

    // 6. 發送事件
    // TODO: 启用事件 emit
    // sui::event::emit(DepositEvent {
    //     user: sender(ctx),
    //     amount,
    //     shares,
    //     timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
    // });
}

// ============================================================================
// 提款功能

/// 提款入口
public fun withdraw<T>(
    vault: &mut Vault<T>,
    user_pos: &mut UserPosition,
    share_amount: u64,
    ctx: &mut TxContext
) {
    assert!(user_pos.shares >= share_amount, EInsufficientShares);

    // 1. 計算可贖回資產
    let assets = math::calculate_assets(share_amount, vault.total_assets, vault.total_shares);

    // 2. 計算手續費（從 Config 讀取）
    // 簡化實現：手續費為 0
    // 實際實現需要從 Config 讀取 fee_rate
    let fee: u64 = 0;
    let net_assets = assets - fee;

    // 3. 從 Navi 贖回 wUSDC
    // 簡化實現：直接從 Vault 餘額轉出
    // TODO: 啟用 yield 模塊調用
    // let wusdc_balance = yield::withdraw_from_navi<T>(net_assets, ctx);
    // let wusdc = wusdc_balance.into_coin(ctx);
    let wusdc = vault.n_token.split(net_assets).into_coin(ctx);

    // 4. 轉給用戶
    transfer::public_transfer(wusdc, sender(ctx));

    // 5. 更新狀態
    vault.total_assets = vault.total_assets - assets;
    vault.total_shares = vault.total_shares - share_amount;
    user_pos.shares = user_pos.shares - share_amount;

    // 6. 發送事件
    sui::event::emit(WithdrawEvent {
        user: sender(ctx),
        shares: share_amount,
        amount: net_assets,
        fee,
        timestamp: sui::tx_context::epoch_timestamp_ms(ctx),
    });
}

// ============================================================================
// 視圖函數

/// 獲取用戶份額
public fun get_user_shares(user_pos: &UserPosition): u64 {
    user_pos.shares
}

/// 獲取 Vault 總份額
public fun get_total_shares<T>(vault: &Vault<T>): u64 {
    vault.total_shares
}

/// 獲取 Vault 總資產
public fun get_total_assets<T>(vault: &Vault<T>): u64 {
    vault.total_assets
}

/// 計算用戶可贖回的資產
public fun calculate_user_assets<T>(
    vault: &Vault<T>,
    user_pos: &UserPosition
): u64 {
    math::calculate_assets(user_pos.shares, vault.total_assets, vault.total_shares)
}

// ============================================================================
// 測試輔助

/// Mint shares (for cross-chain use)
public fun mint_shares<T>(
    vault: &mut Vault<T>,
    amount: u64,
    ctx: &mut TxContext
): u64 {
    let shares = math::calculate_shares(amount, vault.total_assets, vault.total_shares);
    
    // Update vault state
    vault.total_assets = vault.total_assets + amount;
    vault.total_shares = vault.total_shares + shares;
    
    shares
}

/// Burn shares (for cross-chain use)
public fun burn_shares<T>(
    vault: &mut Vault<T>,
    user_pos: &mut UserPosition,
    share_amount: u64
): u64 {
    assert!(user_pos.shares >= share_amount, EInsufficientShares);
    
    // Calculate assets to redeem
    let assets = math::calculate_assets(share_amount, vault.total_assets, vault.total_shares);
    
    // Update vault state
    vault.total_assets = vault.total_assets - assets;
    vault.total_shares = vault.total_shares - share_amount;
    user_pos.shares = user_pos.shares - share_amount;
    
    assets
}

/// Add shares to user position (for cross-chain use)
public fun add_shares(
    user_pos: &mut UserPosition,
    shares: u64
) {
    user_pos.shares = user_pos.shares + shares;
}

// ============================================================================
// Getter 函數（供其他模組使用）

/// 獲取金庫的 wUSDC 類型
public fun get_wusdc_type<T>(vault: &Vault<T>): type_name::TypeName {
    vault.wusdc_type
}

/// 獲取用戶份額
public fun get_shares(user_pos: &UserPosition): u64 {
    user_pos.shares
}

#[test_only]
public fun create_vault_for_testing<T>(
    wusdc_type: type_name::TypeName,
    ctx: &mut TxContext
): Vault<T> {
    Vault<T> {
        id: object::new(ctx),
        total_shares: 0,
        total_assets: 0,
        n_token: balance::zero<T>(),
        wusdc_type,
    }
}

#[test_only]
public fun create_user_position_for_testing(
    user: address,
    ctx: &mut TxContext
): UserPosition {
    UserPosition {
        id: object::new(ctx),
        user,
        shares: 0,
        deposit_timestamp: 0,
    }
}
