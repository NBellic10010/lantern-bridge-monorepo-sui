# Lantern Vault - Sui Mainnet 部署指南

## 发布版本

- **日期**: 2026-05-04
- **版本**: v1.0.1

---

## 本次发布内容

### Sui Move 合约改动

| 文件 | 改动 |
|------|------|
| `admin.move` | 新增 `Config.admin` 字段；`verify_admin` 实现真正验证；所有管理函数加 `ctx` 参数 |
| `vault.move` | `deposit`/`withdraw` 加 `Config` 参数；手续费路由 treasury |
| `cross_chain.move` | 修复 `add_relayer`/`remove_relayer` 函数签名（加 `ctx`） |

### Relayer 改动

| 文件 | 改动 |
|------|------|
| `relayer.service.ts` | 新增 `depositToNavi`；`relayEvmNttToSui` 末尾追加 Navi 存款 |
| `package.json` | 新增 `@naviprotocol/lending@1.0.6` |

---

## 部署步骤

### Step 1: 安装/确认 Sui CLI

```bash
# 检查是否已安装
sui --version

# 如未安装：
curl -fsSL https://docs.sui.io/build/sui-cli-install/install.sh | sh
```

### Step 2: 切换到主网

```bash
sui client switch --env mainnet
```

### Step 3: 安装 npm 依赖

```bash
cd lantern-backend
npm install
```

### Step 4: 构建并部署合约

```bash
cd lantern-contracts
chmod +x deploy-mainnet.sh
./deploy-mainnet.sh
```

> ⚠️ 如果私钥格式问题，使用 `--private-key` 参数：
> ```bash
> sui client publish --private-key <hex_private_key> --gas-budget 500000000
> ```

### Step 5: Config 迁移

**由于 `Config` 结构体新增了 `admin` 字段，旧的 Config object 无法直接升级。**

#### 方案 A：全新部署（推荐，用于开发/测试）

```bash
# 部署后，在交易输出中查找 initialize 调用的结果
# 新 Config object ID 格式为：lantern_vault::admin::Config
sui client objects <你的地址> --type lantern_vault::admin::Config
```

#### 方案 B：升级现有 Config

如果需要保留现有数据，需要：

1. 导出现有 Config 数据（fee_rate, treasury, paused 等）
2. 创建一个新的 Config
3. 编写迁移脚本，将旧数据写入新 Config

```bash
# 1. 查看现有 Config
sui client object <OLD_CONFIG_ID> --json

# 2. 记录旧数据后，创建新 Config
# （需要调用 initialize() 函数）
```

### Step 6: 更新 Relayer 环境变量

部署后，获得新的：
1. **Package ID** — 更新到 `LANTERN_PACKAGE_ID`
2. **Config Object ID** — 更新到 `LANTERN_CONFIG_ID`

```bash
# 在 lantern-backend/.env 中更新：
LANTERN_PACKAGE_ID=0x<新包ID>
LANTERN_CONFIG_ID=0x<新Config ID>
```

### Step 7: 重启 Relayer

```bash
cd lantern-backend
npm run build
npm start
```

---

## 验证部署

### 检查合约包

```bash
sui client object <PACKAGE_ID> --json
```

### 检查 Config

```bash
sui client object <CONFIG_ID> --json
# 确认 admin 字段存在且正确
```

### 测试 Relayer

```bash
# 查看 Relayer 日志确认连接正常
curl http://localhost:3000/health
```

---

## 回滚方案

如需回滚到上一个版本：

```bash
# 找到上一个版本的 git commit
git log --oneline

# 使用旧合约重新部署
git checkout <上一个版本commit>
sui move build
sui client publish --gas-budget 500000000
```

---

## 联系支持

如部署遇到问题，请查看 `relayer.service.ts` 中的日志输出，或联系开发团队。
