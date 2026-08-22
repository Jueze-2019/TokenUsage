#!/bin/bash
# 发布打包：构建 → 校验 bundle 不含任何用户数据 → 打成 zip。
#
# 用户数据（API Key / 账户配置 / 用量缓存）只存在于 ~/Library，
# 不会被 build.sh 打进 .app；本脚本做一次显式扫描兜底。
#
# 用法:
#   Tools/build_release.sh              构建 + 校验 + 产出 dist/TokenUsage.zip
#   Tools/build_release.sh --wipe-local 额外清除本机的 App 数据（回到首次安装状态，
#                                        用于发布前验证首次安装引导向导）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/TokenUsage.app"

"$ROOT/build.sh"

echo "==> 校验 bundle 不含用户数据"
if find "$APP" \( -name "*.zip" -o -name "*.csv" -o -name "api_keys.json" \
       -o -name "balance_cache.json" -o -name "*.plist.tmp" \) | grep .; then
    echo "!! bundle 中包含疑似用户数据，已中止"
    exit 1
fi
echo "    OK：无 Key / 缓存 / 用量数据文件"

if [ "${1:-}" = "--wipe-local" ]; then
    echo "==> 清除本机 App 数据（恢复首次安装状态）"
    pkill -f "TokenUsage.app/Contents/MacOS/TokenUsage" 2>/dev/null || true
    defaults delete com.tokenusage.app 2>/dev/null || true
    rm -rf "$HOME/Library/Application Support/TokenUsage"
    rm -f "$HOME/Library/Group Containers/group.com.tokenusage.shared/balance_cache.json"
    echo "    OK：defaults / API Key / 用量缓存已清除"
fi

cd "$ROOT/dist"
rm -f TokenUsage.zip
ditto -c -k --sequesterRsrc --keepParent TokenUsage.app TokenUsage.zip
echo "==> 发布包: dist/TokenUsage.zip"
echo
echo "提醒：仓库根目录的 usage_data_*.zip 是你的真实用量数据，分发时勿打包/上传。"
