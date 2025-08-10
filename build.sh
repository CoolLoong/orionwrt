#!/usr/bin/env bash

set -e

BASE_PATH=$(cd $(dirname $0) && pwd)

Dev=""
Build_Mod=""
SKIP_FEEDS_UPDATE=false

show_usage() {
    echo "使用方法: $0 <设备名> [构建模式] [选项]"
    echo ""
    echo "参数说明:"
    echo "  设备名               设备配置名称（必需）"
    echo "  构建模式             debug 或其他值（可选）"
    echo ""
    echo "选项:"
    echo "  --skip-feeds-update  跳过 feeds 更新操作（加快构建速度）"
    echo "  -h, --help           显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  # 正常构建"
    echo "  $0 ax6000"
    echo ""
    echo "  # debug 模式"
    echo "  $0 ax6000 debug"
    echo ""
    echo "  # 跳过 feeds 更新的快速构建"
    echo "  $0 ax6000 --skip-feeds-update"
    echo ""
    echo "  # debug 模式并跳过 feeds 更新"
    echo "  $0 ax6000 debug --skip-feeds-update"
}

# 解析命令行参数
if [[ $# -eq 0 ]]; then
    echo "错误: 缺少设备名参数"
    show_usage
    exit 1
fi

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        --skip-feeds-update)
            SKIP_FEEDS_UPDATE=true
            shift
            ;;
        debug)
            Build_Mod="debug"
            shift
            ;;
        *)
            if [[ -z "$Dev" ]]; then
                Dev="$1"
                shift
            elif [[ -z "$Build_Mod" && "$1" != --* ]]; then
                Build_Mod="$1"
                shift
            else
                echo "未知参数: $1"
                show_usage
                exit 1
            fi
            ;;
    esac
done

# 检查必需参数
if [[ -z "$Dev" ]]; then
    echo "错误: 缺少设备名参数"
    show_usage
    exit 1
fi

CONFIG_FILE="$BASE_PATH/deconfig/$Dev.config"
INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

if [[ ! -f $CONFIG_FILE ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f $INI_FILE ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
}

# 移除 uhttpd 依赖
# 当启用luci-app-quickfile插件时，表示启动nginx，所以移除luci对uhttp(luci-light)的依赖
remove_uhttpd_dependency() {
    local config_path="$BASE_PATH/$BUILD_DIR/.config"
    local luci_makefile_path="$BASE_PATH/$BUILD_DIR/feeds/luci/collections/luci/Makefile"

    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path"; then
        if [ -f "$luci_makefile_path" ]; then
            sed -i '/luci-light/d' "$luci_makefile_path"
            echo "Removed uhttpd (luci-light) dependency as luci-app-quickfile (nginx) is enabled."
        fi
    fi
}

REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR")
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}

if [[ -d $BASE_PATH/action_build ]]; then
    BUILD_DIR="action_build"
fi

# 显示构建配置
echo "========================================="
echo "构建配置:"
echo "  设备: $Dev"
echo "  构建模式: ${Build_Mod:-normal}"
echo "  仓库: $REPO_URL"
echo "  分支: $REPO_BRANCH"
echo "  构建目录: $BUILD_DIR"
echo "  提交哈希: $COMMIT_HASH"
echo "  跳过 feeds 更新: $SKIP_FEEDS_UPDATE"
echo "========================================="

# 调用 update.sh 脚本，传递 --skip-feeds-update 参数
if [[ "$SKIP_FEEDS_UPDATE" == "true" ]]; then
    $BASE_PATH/update.sh "$REPO_URL" "$REPO_BRANCH" "$BASE_PATH/$BUILD_DIR" "$COMMIT_HASH" "$SKIP_FEEDS_UPDATE"
else
    $BASE_PATH/update.sh "$REPO_URL" "$REPO_BRANCH" "$BASE_PATH/$BUILD_DIR" "$COMMIT_HASH"
fi

\cp -f "$CONFIG_FILE" "$BASE_PATH/$BUILD_DIR/.config"

remove_uhttpd_dependency

cd "$BASE_PATH/$BUILD_DIR"
make defconfig

if grep -qE "^CONFIG_TARGET_x86_64=y" "$CONFIG_FILE"; then
    DISTFEEDS_PATH="$BASE_PATH/$BUILD_DIR/package/emortal/default-settings/files/99-distfeeds.conf"
    if [ -d "${DISTFEEDS_PATH%/*}" ] && [ -f "$DISTFEEDS_PATH" ]; then
        sed -i 's/aarch64_cortex-a53/x86_64/g' "$DISTFEEDS_PATH"
    fi
fi

if [[ $Build_Mod == "debug" ]]; then
    exit 0
fi

TARGET_DIR="$BASE_PATH/$BUILD_DIR/bin/targets"
if [[ -d $TARGET_DIR ]]; then
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec rm -f {} +
fi

make download -j$(($(nproc) * 2))
make -j$(($(nproc) + 1)) || make -j1 V=s

FIRMWARE_DIR="$BASE_PATH/firmware"
\rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
\rm -f "$BASE_PATH/firmware/Packages.manifest" 2>/dev/null

if [[ -d $BASE_PATH/action_build ]]; then
    make clean
fi