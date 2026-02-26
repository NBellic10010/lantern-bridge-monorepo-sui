/// Math Module - 數學計算輔助
/// 處理份額計算的精度問題
module lantern_vault::math;

// ============================================================================
// 錯誤碼

const EInvalidAmount: u64 = 400;
const EDivisionByZero: u64 = 401;

// ============================================================================
// 核心計算函數

/// 計算存款應獲得的份額
/// 採用 ERC-4626 標準
/// @param assets 新存款金額
/// @param total_assets 當前總資產
/// @param total_shares 當前總份額
/// @return 應獲得的新份額
public fun calculate_shares(
    assets: u64,
    total_assets: u64,
    total_shares: u64
): u64 {
    // 參數驗證
    assert!(assets > 0, EInvalidAmount);

    if (total_shares == 0) {
        // 第一個存款人：1:1 匯率
        assets
    } else {
        assert!(total_assets > 0, EDivisionByZero);

        // 後續存款：shares = assets * total_shares / total_assets
        // 向上取整避免份額被稀釋
        (assets * total_shares + total_assets - 1) / total_assets
    }
}

/// 計算份額可贖回的資產
/// @param shares 要贖回的份額
/// @param total_assets 當前總資產
/// @param total_shares 當前總份額
/// @return 可贖回的資產金額
public fun calculate_assets(
    shares: u64,
    total_assets: u64,
    total_shares: u64
): u64 {
    if (total_shares == 0 || shares == 0) {
        0
    } else {
        // assets = shares * total_assets / total_shares
        (shares * total_assets) / total_shares
    }
}

/// 計算當前份額的匯率
/// @param total_assets 當前總資產
/// @param total_shares 當前總份額
/// @return 每份額對應的資產（放大 1e9 倍）
public fun calculate_exchange_rate(
    total_assets: u64,
    total_shares: u64
): u64 {
    if (total_shares == 0) {
        // 初始匯率 1:1
        1_000_000_000  // 1e9
    } else {
        // 放大 1e9 倍以保持精度
        (total_assets * 1_000_000_000) / total_shares
    }
}

/// 計算手續費
/// @param amount 金額
/// @param fee_rate 手續費費率 (basis points)
/// @return 手續費金額
public fun calculate_fee(
    amount: u64,
    fee_rate: u64
): u64 {
    // fee = amount * fee_rate / 10000
    (amount * fee_rate) / 10000
}

/// 計算年化收益率
/// @param yield 收益金額
/// @param principal 本金
/// @param days 天數
/// @return 年化收益率 (basis points)
public fun calculate_apy(
    yield: u64,
    principal: u64,
    days: u64
): u64 {
    if (principal == 0 || days == 0) {
        0
    } else {
        // APY = (yield / principal) * (365 / days) * 10000
        (yield * 365 * 10000) / (principal * days)
    }
}

/// 計算單利收益
/// @param principal 本金
/// @param rate 年化收益率 (basis points)
/// @param days 天數
/// @return 收益金額
public fun calculate_simple_interest(
    principal: u64,
    rate: u64,
    days: u64
): u64 {
    // interest = principal * rate * days / (365 * 10000)
    (principal * rate * days) / (365 * 10000)
}

/// 計算複利收益（年化）
/// @param principal 本金
/// @param rate 年化收益率 (小數，如 0.05 = 5%)
/// @param years 年數
/// @return 最終金額
public fun calculate_compound_interest(
    principal: u64,
    rate: u64,  // 需要轉換為小數（rate / 10000）
    years: u64
): u64 {
    // A = P * (1 + r)^n
    // 這裡簡化處理，使用近似公式
    if (years == 0) {
        principal
    } else {
        // 簡化：使用線性近似
        let interest = principal * rate * years / 10000;
        principal + interest
    }
}

// ============================================================================
// 測試輔助

#[test]
fun test_calculate_shares_first_deposit() {
    // 第一個存款人應該獲得 1:1 份額
    let shares = calculate_shares(1000, 0, 0);
    assert!(shares == 1000, 0);
}

#[test]
fun test_calculate_shares_subsequent_deposit() {
    // 後續存款應該按比例計算
    // 總資產 1000，總份額 1000
    // 存款 1000，應獲得 1000 份額
    let shares = calculate_shares(1000, 1000, 1000);
    assert!(shares == 1000, 0);
}

#[test]
fun test_calculate_assets() {
    // 計算贖回資產
    let assets = calculate_assets(500, 1000, 1000);
    assert!(assets == 500, 0);
}

#[test]
fun test_calculate_fee() {
    // 1% 手續費
    let fee = calculate_fee(1000, 100);
    assert!(fee == 10, 0);
}

#[test]
fun test_calculate_simple_interest() {
    // 本金 1000，年化 5%，1 天
    let interest = calculate_simple_interest(1000, 500, 1); // 500 = 5%
    // 1000 * 500 * 1 / (365 * 10000) = 0
    assert!(interest == 0, 0);
}
