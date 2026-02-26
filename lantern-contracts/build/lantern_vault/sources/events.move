/// Events Module - 事件定義
/// 定義金庫的所有事件類型
module lantern_vault::events;

// ============================================================================
// 存款相關事件

/// 存款事件
/// 當用戶存款時觸發
public struct DepositEvent has copy, drop {
    /// 存款用戶地址
    user: address,
    /// 存款金額（最小單位）
    amount: u64,
    /// 獲得的份額
    shares: u64,
    /// 存款時間戳
    timestamp: u64,
}

/// 批量存款事件
public struct BatchDepositEvent has copy, drop {
    /// 存款用戶地址列表
    users: vector<address>,
    /// 存款金額列表
    amounts: vector<u64>,
    /// 獲得的份額列表
    shares_list: vector<u64>,
    /// 存款時間戳
    timestamp: u64,
}

// ============================================================================
// 提款相關事件

/// 提款事件
/// 當用戶提款時觸發
public struct WithdrawEvent has copy, drop {
    /// 提款用戶地址
    user: address,
    /// 提款的份額
    shares: u64,
    /// 獲得的金額（扣除手續費後）
    amount: u64,
    /// 手續費金額
    fee: u64,
    /// 提款時間戳
    timestamp: u64,
}

/// 批量提款事件
public struct BatchWithdrawEvent has copy, drop {
    /// 提款用戶地址列表
    users: vector<address>,
    /// 提款的份額列表
    shares_list: vector<u64>,
    /// 獲得的金額列表
    amounts: vector<u64>,
    /// 手續費總額
    total_fee: u64,
    /// 提款時間戳
    timestamp: u64,
}

// ============================================================================
// 收益相關事件

/// 收益事件
/// 當協議產生收益時觸發（如手續費收入）
public struct YieldEvent has copy, drop {
    /// 收益來源（存款/利息）
    source: vector<u8>,
    /// 收益金額
    amount: u64,
    /// 當前總資產
    total_assets: u64,
    /// 時間戳
    timestamp: u64,
}

/// 收益分配事件
public struct YieldDistributionEvent has copy, drop {
    /// 受益用戶地址
    user: address,
    /// 分配的收益金額
    yield_amount: u64,
    /// 用戶當前總份額
    user_shares: u64,
    /// 時間戳
    timestamp: u64,
}

// ============================================================================
// 管理相關事件

/// 協議暫停事件
public struct ProtocolPaused has copy, drop {
    /// 暫停原因
    reason: vector<u8>,
    /// 暫停時間戳
    timestamp: u64,
}

/// 協議恢復事件
public struct ProtocolUnpaused has copy, drop {
    /// 恢復時間戳
    timestamp: u64,
}

/// 手續費率變更事件
public struct FeeRateChanged has copy, drop {
    /// 舊費率
    old_rate: u64,
    /// 新費率
    new_rate: u64,
    /// 變更時間戳
    timestamp: u64,
}

/// 金庫參數變更事件
public struct VaultParametersChanged has copy, drop {
    /// 變更的參數類型
    parameter: vector<u8>,
    /// 舊值
    old_value: u64,
    /// 新值
    new_value: u64,
    /// 變更時間戳
    timestamp: u64,
}

// ============================================================================
// 風控相關事件

/// 存款被拒絕事件
public struct DepositRejected has copy, drop {
    /// 用戶地址
    user: address,
    /// 拒絕原因
    reason: vector<u8>,
    /// 嘗試存款金額
    amount: u64,
    /// 時間戳
    timestamp: u64,
}

/// 異常交易事件
public struct AnomalousTransaction has copy, drop {
    /// 用戶地址
    user: address,
    /// 交易類型
    tx_type: vector<u8>,
    /// 異常金額
    amount: u64,
    /// 異常原因
    reason: vector<u8>,
    /// 時間戳
    timestamp: u64,
}

// ============================================================================
// 跨鏈相關事件

/// EVM 存款事件 (EVM → Sui)
/// 當從 EVM 跨鏈存款到 Sui 時觸發
public struct EvmDepositEvent has copy, drop {
    /// 用戶地址 (EVM 地址)
    user: address,
    /// 存款金額
    amount: u64,
    /// 獲得的份額
    shares: u64,
    /// VAA Hash (用於防重放)
    vaa_hash: vector<u8>,
    /// 時間戳
    timestamp: u64,
}

/// EVM 提款事件 (Sui → EVM)
/// 當從 Sui 跨鏈提款到 EVM 時觸發
public struct EvmWithdrawEvent has copy, drop {
    /// 用戶地址 (EVM 地址)
    user: address,
    /// 提款金額
    amount: u64,
    /// 燒毀的份額
    shares: u64,
    /// 目標鏈
    dest_chain: u16,
    /// VAA Hash
    vaa_hash: vector<u8>,
    /// 時間戳
    timestamp: u64,
}

/// Sui 存款事件 (跨鏈存款到 Sui)
/// 當從其他鏈跨鏈存款到 Sui 時觸發
public struct SuiDepositEvent has copy, drop {
    /// 用戶地址 (Sui 地址)
    user: address,
    /// 存款金額
    amount: u64,
    /// 獲得的份額
    shares: u64,
    /// 源鏈 ID
    source_chain: u16,
    /// 時間戳
    timestamp: u64,
}

/// Sui 提款事件 (Sui → 跨鏈)
/// 當從 Sui 跨鏈提款到其他鏈時觸發
public struct SuiWithdrawEvent has copy, drop {
    /// 用戶地址 (Sui 地址)
    user: address,
    /// 提款金額
    amount: u64,
    /// 燒毀的份額
    shares: u16,
    /// 目標鏈 ID
    dest_chain: u16,
    /// 目標地址
    recipient: address,
    /// 時間戳
    timestamp: u64,
}

/// 跨鏈消息發送事件
/// 當發送跨鏈消息時觸發
public struct CrossChainMessageEvent has copy, drop {
    /// 消息類型
    msg_type: u8,
    /// 源鏈 ID
    source_chain: u16,
    /// 目標鏈 ID
    dest_chain: u16,
    /// 發送者
    sender: address,
    /// 金額
    amount: u64,
    /// 消息 Hash
    message_hash: vector<u8>,
    /// 時間戳
    timestamp: u64,
}

/// 跨鏈消息確認事件
/// 當跨鏈消息被確認時觸發
public struct CrossChainMessageConfirmedEvent has copy, drop {
    /// 消息 Hash
    message_hash: vector<u8>,
    /// 確認的區塊高度
    confirmation_height: u64,
    /// 時間戳
    timestamp: u64,
}
