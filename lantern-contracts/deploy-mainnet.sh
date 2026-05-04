#!/bin/bash
# ==============================================================================
# Lantern Vault - Sui Mainnet 部署脚本
# ==============================================================================
# 用途：部署 lantern_vault 包到 Sui Mainnet
#
# 前置条件：
#   1. 安装 Sui CLI: https://docs.sui.io/build/sui-cli-install
#   2. 配置主网环境变量
#   3. 确保有足够的 SUI gas
#
# 使用方法：
#   chmod +x deploy-mainnet.sh
#   ./deploy-mainnet.sh
# ==============================================================================

set -e

echo "=========================================="
echo "Lantern Vault - Sui Mainnet 部署"
echo "=========================================="

# 切换到合约目录
cd "$(dirname "$0")"

# 检查 Sui CLI
if ! command -v sui &> /dev/null; then
    echo "❌ Sui CLI 未安装"
    echo "请先安装：curl -fsSL https://docs.sui.io/build/sui-cli-install/install.sh | sh"
    exit 1
fi

echo "✅ Sui CLI 版本：$(sui --version)"

# 检查 .env 文件
if [ ! -f .env ]; then
    echo "⚠️  未找到 .env 文件，从示例创建..."
    cat > .env << 'EOF'
# Sui RPC (主网)
SUI_RPC_URL=https://sui-mainnet.nodeinfra.com
# Sui 私钥 (base64 编码)
SUI_PRIVATE_KEY=YOUR_BASE64_PRIVATE_KEY
EOF
    echo "请编辑 .env 文件填入你的私钥"
    exit 1
fi

# 加载环境变量
source .env

echo "📦 正在构建合约..."
sui move build

echo "🚀 正在部署到主网..."
sui client publish --gas-budget 500000000 --skip-fetch-latest-deps

echo ""
echo "=========================================="
echo "✅ 部署成功！"
echo ""
echo "⚠️  重要：Config 迁移"
echo ""
echo "由于 admin.move 的 Config 结构体新增了 admin 字段，"
echo "旧的 Config shared object 无法原地升级。"
echo ""
echo "部署后你需要："
echo "  1. 运行合约的 initialize() 创建新的 Config"
echo "  2. 记录新 Config 的 object ID"
echo "  3. 将新 Config ID 更新到 Relayer 的环境变量"
echo ""
echo "参考 Config object ID 搜索："
echo "  sui client objects <你的地址> --type lantern_vault::admin::Config"
echo "=========================================="
