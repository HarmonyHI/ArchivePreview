#!/bin/zsh
# 压缩包预览器 —— 编译并安装
#
# 用法：
#   ./install.sh              从源码编译并安装
#   ./install.sh --prebuilt   使用预编译二进制（没有 Xcode 命令行工具时用）
#
# 做的事：
#   1. 源码复制到 ~/Scripts/ArchivePreview（保留一份可编译的源）
#   2. 编译二进制到 ~/Scripts/bin
#   3. 组装 /Applications/压缩包预览器.app 并做本地临时签名
#   4. 重新登记 LaunchServices
#   5. 把 zip/tar/tgz/gz/bz2/xz/rar/7z 八种格式的默认打开方式指过去

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$HOME/Scripts/ArchivePreview"
BIN_DIR="$HOME/Scripts/bin"
APP="/Applications/压缩包预览器.app"
APP_NAME="压缩包预览器"
BUNDLE_ID="com.local.archivepreview"

# 兼容两种布局：仓库根目录直接放源码，或发布包里的 src/ 子目录
if [[ -f "$HERE/main.swift" ]]; then
    SRC="$HERE/main.swift"
    PLIST="$HERE/Info.plist"
    SETTER="$HERE/SetHandler/main.swift"
elif [[ -f "$HERE/src/main.swift" ]]; then
    SRC="$HERE/src/main.swift"
    PLIST="$HERE/src/Info.plist"
    SETTER="$HERE/src/SetHandler/main.swift"
else
    echo "!! 找不到 main.swift，请在项目根目录运行本脚本" >&2
    exit 1
fi

USE_PREBUILT=0
[[ "$1" == "--prebuilt" ]] && USE_PREBUILT=1
if [[ $USE_PREBUILT -eq 1 && ! -x "$HERE/bin/ArchivePreview" ]]; then
    echo "!! 没有找到预编译二进制（bin/ArchivePreview），改为从源码编译"
    USE_PREBUILT=0
fi

echo "==> 准备目录"
mkdir -p "$SRC_DIR/SetHandler" "$BIN_DIR"

echo "==> 复制源码到 $SRC_DIR"
cp "$SRC"   "$SRC_DIR/main.swift"
cp "$PLIST" "$SRC_DIR/Info.plist"
cp "$SETTER" "$SRC_DIR/SetHandler/main.swift"

# ---------------------------------------------------------------- 编译
if [[ $USE_PREBUILT -eq 1 ]]; then
    echo "==> 使用预编译二进制"
    cp "$HERE/bin/ArchivePreview" "$BIN_DIR/ArchivePreview"
    cp "$HERE/bin/SetHandler"     "$BIN_DIR/SetHandler"
    chmod +x "$BIN_DIR/ArchivePreview" "$BIN_DIR/SetHandler"
else
    if ! command -v swiftc >/dev/null 2>&1; then
        echo "!! 找不到 swiftc（需要 Xcode 命令行工具）" >&2
        echo "   先运行： xcode-select --install" >&2
        exit 1
    fi
    echo "==> 编译主程序"
    swiftc -O -o "$BIN_DIR/ArchivePreview" "$SRC_DIR/main.swift"
    echo "==> 编译 SetHandler"
    swiftc -O -o "$BIN_DIR/SetHandler" "$SRC_DIR/SetHandler/main.swift"
fi

# ---------------------------------------------------------------- 组装 App
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/ArchivePreview" "$APP/Contents/MacOS/$APP_NAME"
cp "$SRC_DIR/Info.plist"     "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

echo "==> 签名（本地临时签名，避免 Gatekeeper 拦）"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing" || true

# ---------------------------------------------------------------- 登记
# 追加新的文档类型（如 rar/7z）时必须先让 LaunchServices 忘记旧登记再重新登记，
# 否则 LSSetDefaultRoleHandlerForContentType 写的值会在 lsd 重启后被丢掉。
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
echo "==> 重新登记到 LaunchServices"
"$LSR" -u "$APP" >/dev/null 2>&1 || true
sleep 1
"$LSR" -f "$APP" >/dev/null 2>&1 || true
sleep 1

echo "==> 设置默认打开方式"
"$BIN_DIR/SetHandler" set "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 2

echo "==> 重启 LaunchServices 让系统认账"
killall lsd 2>/dev/null || true
sleep 2

echo ""
echo "✅ 安装完成。当前归档类型的默认打开方式："
"$BIN_DIR/SetHandler" get 2>/dev/null || true
echo ""
echo "还原成系统默认（归档实用工具）： $BIN_DIR/SetHandler revert"
