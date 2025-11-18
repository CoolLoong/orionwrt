#!/usr/bin/env bash

set -e
set -o errexit
set -o errtrace
# 定义错误处理函数
error_handler() {
    echo "Error occurred in script at line: ${BASH_LINENO[0]}, command: '${BASH_COMMAND}'"
}
trap 'error_handler' ERR

BASE_PATH=$(cd $(dirname $0) && pwd)

# ==================== 全局变量 ====================
Dev=""
Build_Mod=""
FORCE_INIT=false
UPDATE_FEEDS=false
FEEDS_CONF="feeds.conf.default"
GOLANG_REPO="https://github.com/sbwml/packages_lang_golang"
GOLANG_BRANCH="25.x"
THEME_SET="orion"
LAN_ADDR="192.168.100.1"

# ==================== 帮助信息 ====================
show_usage() {
    cat <<EOF
使用方法: $0 <设备名> [构建模式] [选项]

参数说明:
    设备名               设备配置名称（必需）
    构建模式             debug 或其他值（可选）

选项:
    --force-init         强制重新初始化（重新 clone、feeds update、应用所有配置）
    --update-feeds       增量构建时更新 feeds 源代码
    --clean              清理后重新构建
    -h, --help           显示此帮助信息

构建模式:
    【模式1 - 首次构建】
        自动检测并执行完整初始化流程
        - 下载源代码
        - 更新 feeds
        - 应用所有自定义配置

    【模式2 - 增量构建（默认）】
        不更新 feeds，但应用所有自定义配置
        - 保持 feeds 源代码不变
        - 重新应用自定义修改
        - 编译速度快

    【模式3 - 增量构建 + 更新 feeds】
        使用 --update-feeds 选项
        - 更新 feeds 源代码
        - 重新应用自定义配置

示例:
    # 模式1：第一次构建（自动完整初始化）
    $0 x86_64_immwrt

    # 模式2：第二次构建（默认，不更新 feeds，应用配置）
    $0 x86_64_immwrt

    # 模式3：增量构建 + 更新 feeds
    $0 x86_64_immwrt --update-feeds

    # 强制重新初始化所有内容
    $0 x86_64_immwrt --force-init

    # 清理后重新构建
    $0 x86_64_immwrt --clean

    # Debug 模式（只生成配置，不编译）
    $0 x86_64_immwrt debug

EOF
}

# ==================== 参数解析 ====================
if [[ $# -eq 0 ]]; then
    echo "错误: 缺少设备名参数"
    show_usage
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        --force-init)
            FORCE_INIT=true
            shift
            ;;
        --update-feeds)
            UPDATE_FEEDS=true
            shift
            ;;
        --clean)
            FORCE_CLEAN=true
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

if [[ -z "$Dev" ]]; then
    echo "错误: 缺少设备名参数"
    show_usage
    exit 1
fi

# ==================== 读取配置 ====================
CONFIG_FILE="$BASE_PATH/deconfig/$Dev.config"
INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

if [[ ! -f $CONFIG_FILE ]]; then
    echo "错误: 配置文件不存在: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f $INI_FILE ]]; then
    echo "错误: INI 文件不存在: $INI_FILE"
    exit 1
fi

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
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

BUILD_PATH="$BASE_PATH/$BUILD_DIR"

# ==================== 检测：是否需要初始化 ====================
check_if_needs_init() {
    # 检查关键目录和文件是否存在
    if [[ ! -d "$BUILD_PATH" ]]; then
        echo "检测：构建目录不存在"
        return 0  # 需要初始化
    fi

    if [[ ! -d "$BUILD_PATH/.git" ]]; then
        echo "检测：Git 仓库不存在"
        return 0
    fi

    if [[ ! -d "$BUILD_PATH/feeds" ]]; then
        echo "检测：feeds 目录不存在"
        return 0
    fi

    if [[ ! -f "$BUILD_PATH/feeds.conf.default" ]]; then
        echo "检测：feeds.conf.default 不存在"
        return 0
    fi

    if [[ ! -d "$BUILD_PATH/package" ]]; then
        echo "检测：package 目录不存在"
        return 0
    fi

    # 所有检查通过，不需要初始化
    echo "检测：构建环境已初始化"
    return 1
}

# 判断是否需要初始化
NEEDS_INIT=false
if [[ "$FORCE_INIT" == "true" ]]; then
    echo "用户指定 --force-init，将执行完整初始化"
    NEEDS_INIT=true
elif check_if_needs_init; then
    echo "首次构建，将执行完整初始化"
    NEEDS_INIT=true
else
    echo "已存在构建环境，将执行增量构建"
    NEEDS_INIT=false
fi

# 如果指定了 --clean，执行清理
if [[ "$FORCE_CLEAN" == "true" ]]; then
    echo "执行构建清理..."
    if [[ -d "$BUILD_PATH" ]]; then
        cd "$BUILD_PATH"
        make clean 2>/dev/null || true
        echo "✅ 清理完成"
    fi
fi

# ==================== 初始化相关函数 ====================
clone_repo() {
    if [[ ! -d $BUILD_PATH ]]; then
        echo "正在克隆仓库: $REPO_URL (分支: $REPO_BRANCH)"
        git clone --depth 1 -b $REPO_BRANCH $REPO_URL $BUILD_PATH
        echo "✅ 仓库克隆完成"
    else
        echo "仓库已存在，跳过克隆"
    fi
}

clean_up() {
    cd $BUILD_PATH
    echo "清理临时文件..."
    [[ -f .config ]] && rm -f .config

    # 只清理锁文件，保留编译缓存
    if [[ -d tmp ]]; then
        find tmp -name "*.lock" -delete 2>/dev/null || true
        find tmp -name ".packageinfo" -delete 2>/dev/null || true
    fi

    [[ -d logs ]] && rm -rf logs/*
    mkdir -p tmp
    echo "1" > tmp/.build
    echo "✅ 临时文件清理完成"
}

reset_feeds_conf() {
    cd $BUILD_PATH
    echo "重置代码到最新版本..."
    git reset --hard origin/$REPO_BRANCH
    git clean -f -d
    git pull
    if [[ $COMMIT_HASH != "none" ]]; then
        echo "切换到指定提交: $COMMIT_HASH"
        git checkout $COMMIT_HASH
    fi
    echo "✅ 代码重置完成"
}

update_feeds() {
    cd $BUILD_PATH
    echo "更新 feeds 配置..."
    sed -i '/^#/d' "$FEEDS_CONF"
    if ! grep -q "small-package" "$FEEDS_CONF"; then
        [ -z "$(tail -c 1 "$FEEDS_CONF")" ] || echo "" >> "$FEEDS_CONF"
        echo "src-git small8 https://github.com/kenzok8/small-package" >> "$FEEDS_CONF"
    fi
    [[ ! -f "include/bpf.mk" ]] && touch "include/bpf.mk"

    echo "清理和更新 feeds..."
    ./scripts/feeds clean
    ./scripts/feeds update -a
    echo "✅ Feeds 更新完成"
}

clone_luci_theme_orion() {
    cd $BUILD_PATH
    local theme_dir="package/luci-theme-orion"
    if [[ ! -d "$theme_dir" ]]; then
        echo "克隆 luci-theme-orion 到 package 目录..."
        git clone --depth 1 https://github.com/CoolLoong/luci-theme-orion.git "$theme_dir"
        echo "✅ luci-theme-orion 克隆完成"
    else
        echo "luci-theme-orion 已存在，跳过克隆"
    fi
}

remove_unwanted_packages() {
    cd $BUILD_PATH
    echo "移除不需要的包..."

    local luci_packages=(
        "luci-app-passwall" "luci-app-ddns-go" "luci-app-rclone" "luci-app-ssr-plus"
        "luci-app-vssr" "luci-app-daed" "luci-app-dae" "luci-app-alist" "luci-app-homeproxy"
        "luci-app-haproxy-tcp" "luci-app-mihomo" "luci-app-appfilter" "luci-app-msd_lite"
    )
    local packages_net=(
        "haproxy" "xray-core" "xray-plugin" "dns2socks" "alist" "hysteria"
        "mosdns" "adguardhome" "ddns-go" "naiveproxy" "sing-box" "v2ray-core" "v2ray-geodata" "v2ray-plugin" "tuic-client"
        "chinadns-ng" "ipt2socks" "tcping" "trojan-plus" "simple-obfs" "shadowsocksr-libev"
        "dae" "daed" "mihomo" "geoview" "tailscale" "open-app-filter" "msd_lite"
    )
    local packages_utils=("cups")
    local small8_packages=(
        "ppp" "firewall" "dae" "daed" "daed-next" "libnftnl" "nftables" "dnsmasq"
        "luci-app-alist" "alist" "opkg" "smartdns" "luci-app-smartdns"
        "luci-app-openclash" "openclash"
    )

    for pkg in "${luci_packages[@]}"; do
        [[ -d ./feeds/luci/applications/$pkg ]] && rm -rf ./feeds/luci/applications/$pkg
        [[ -d ./feeds/luci/themes/$pkg ]] && rm -rf ./feeds/luci/themes/$pkg
    done

    for pkg in "${packages_net[@]}"; do
        [[ -d ./feeds/packages/net/$pkg ]] && rm -rf ./feeds/packages/net/$pkg
    done

    for pkg in "${packages_utils[@]}"; do
        [[ -d ./feeds/packages/utils/$pkg ]] && rm -rf ./feeds/packages/utils/$pkg
    done

    for pkg in "${small8_packages[@]}"; do
        [[ -d ./feeds/small8/$pkg ]] && rm -rf ./feeds/small8/$pkg
    done

    [[ -d ./package/istore ]] && rm -rf ./package/istore

    if [ -d "target/linux/qualcommax/base-files/etc/uci-defaults" ]; then
        find "target/linux/qualcommax/base-files/etc/uci-defaults/" -type f -name "99*.sh" -exec rm -f {} +
    fi

    echo "✅ 不需要的包移除完成"
}

update_golang() {
    cd $BUILD_PATH
    if [[ -d ./feeds/packages/lang/golang ]]; then
        echo "更新 Golang..."
        rm -rf ./feeds/packages/lang/golang
        git clone --depth 1 $GOLANG_REPO -b $GOLANG_BRANCH ./feeds/packages/lang/golang
        echo "✅ Golang 更新完成"
    fi
}

install_small8() {
    cd $BUILD_PATH
    ./scripts/feeds install -p small8 -f xray-core xray-plugin dns2tcp dns2socks haproxy hysteria \
        naiveproxy sing-box v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin \
        tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev \
        luci-app-passwall v2dat mosdns luci-app-mosdns adguardhome luci-app-adguardhome ddns-go \
        luci-app-ddns-go taskd luci-lib-xterm luci-lib-taskd luci-app-store quickstart \
        luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest netdata luci-app-netdata \
        lucky luci-app-lucky luci-app-openclash luci-app-homeproxy luci-app-amlogic nikki luci-app-nikki \
        tailscale luci-app-tailscale oaf open-app-filter luci-app-oaf easytier luci-app-easytier \
        msd_lite luci-app-msd_lite cups luci-app-cupsd
}

install_fullconenat() {
    cd $BUILD_PATH
    if [[ ! -d package/network/utils/fullconenat-nft ]]; then
        ./scripts/feeds install -p small8 -f fullconenat-nft
    fi
    if [[ ! -d package/network/utils/fullconenat ]]; then
        ./scripts/feeds install -p small8 -f fullconenat
    fi
}

install_feeds() {
    cd $BUILD_PATH
    echo "安装 feeds..."
    ./scripts/feeds update -i
    for dir in feeds/*; do
        if [ ! -L "$dir" ] && [ -d "$dir" ] && [[ ! "$dir" == *.tmp ]]; then
            if [[ $(basename "$dir") == "small8" ]]; then
                install_small8
                install_fullconenat
            else
                ./scripts/feeds install -f -ap $(basename "$dir")
            fi
        fi
    done
    echo "✅ Feeds 安装完成"
}

fix_default_set() {
    cd $BUILD_PATH
    if [ -d "feeds/luci/collections/" ]; then
        find "feeds/luci/collections/" -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$THEME_SET/g" {} \;
    fi
    install -Dm755 "$BASE_PATH/patches/991_custom_settings" "package/base-files/files/etc/uci-defaults/991_custom_settings"
}

fix_miniupnpd() {
    cd $BUILD_PATH
    local miniupnpd_dir="feeds/packages/net/miniupnpd"
    local patch_file="999-chanage-default-leaseduration.patch"
    if [ -d "$miniupnpd_dir" ] && [ -f "$BASE_PATH/patches/$patch_file" ]; then
        install -Dm644 "$BASE_PATH/patches/$patch_file" "$miniupnpd_dir/patches/$patch_file"
    fi
}

change_dnsmasq2full() {
    cd $BUILD_PATH
    grep -q "dnsmasq-full" include/target.mk || sed -i 's/dnsmasq/dnsmasq-full/g' ./include/target.mk
}

fix_mk_def_depends() {
    cd $BUILD_PATH
    sed -i 's/libustream-mbedtls/libustream-openssl/g' include/target.mk 2>/dev/null
    if [ -f target/linux/qualcommax/Makefile ]; then
        sed -i 's/wpad-openssl/wpad-mesh-openssl/g' target/linux/qualcommax/Makefile
    fi
}

update_default_lan_host_addr() {
    local CFG_PATH="$BUILD_PATH/package/base-files/files/bin/config_generate"
    if [ -f $CFG_PATH ]; then
        echo "✅ 自定义lanip应用完成"
        sed -i 's/192\.168\.[0-9]*\.[0-9]*/'$LAN_ADDR'/g' $CFG_PATH
    fi
    if [ -f "$CFG_PATH" ]; then
        echo "✅ 自定义hostname应用完成"
        sed -i "s/set system\.@system\[-1\]\.hostname='[^']*'/set system.@system[-1].hostname='OrionWrt'/" "$CFG_PATH"
    fi
}

apply_luci_firewall_patch() {
    cd $BUILD_PATH
    local patch_file="$BASE_PATH/patches/0004-luci-mod-status-firewall-disable-legacy-firewall-rul.patch"
    if [ -f "$patch_file" ] && [ -d "feeds/luci" ]; then
        cd feeds/luci
        patch -p1 --dry-run < "$patch_file" > /dev/null 2>&1 && patch -p1 < "$patch_file" || \
            echo "警告：luci-mod-status 防火墙补丁无法应用"
        cd "$BUILD_PATH"
    fi
}

apply_luci_base_patch() {
    cd $BUILD_PATH
    local patch_file="$BASE_PATH/patches/luci-base.patch"
    [ ! -f "$patch_file" ] && return 0

    if [ -d "feeds/luci/modules/luci-base" ]; then
        cd feeds/luci/modules
        patch -p1 < "$patch_file" 2>/dev/null || echo "警告：luci-base patch 应用失败"
        cd "$BUILD_PATH"
    fi
}

apply_ppp_fix_patch() {
    cd $BUILD_PATH
    local patch_file="$BASE_PATH/patches/101-ppp-fix-configure.patch"
    [ ! -f "$patch_file" ] && return 0

    if [ -f "package/network/services/ppp/Makefile" ]; then
        patch -p1 --dry-run < "$patch_file" > /dev/null 2>&1 && patch -p1 < "$patch_file" || \
            echo "警告：ppp configure patch 无法应用"
    fi
}

set_custom_task() {
    cd $BUILD_PATH
    cat > "package/base-files/files/etc/init.d/custom_task" <<'EOF'
#!/bin/sh /etc/rc.common
START=99
boot() {
    sed -i '/drop_caches/d' /etc/crontabs/root
    echo "15 3 * * * sync && echo 3 > /proc/sys/vm/drop_caches" >>/etc/crontabs/root
    sed -i '/wireguard_watchdog/d' /etc/crontabs/root
    local wg_ifname=$(wg show | awk '/interface/ {print $2}')
    if [ -n "$wg_ifname" ]; then
        echo "*/15 * * * * /usr/bin/wireguard_watchdog" >>/etc/crontabs/root
        uci set system.@system[0].cronloglevel='9'
        uci commit system
        /etc/init.d/cron restart
    fi
    crontab /etc/crontabs/root
}
EOF
    chmod +x "package/base-files/files/etc/init.d/custom_task"
}

install_opkg_distfeeds() {
    cd $BUILD_PATH
    local distfeeds_conf="package/emortal/default-settings/files/99-distfeeds.conf"
    if [ -d "$(dirname "$distfeeds_conf")" ] && [ ! -f "$distfeeds_conf" ]; then
        cat > "$distfeeds_conf" <<'EOF'
src/gz openwrt_base https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/base/
src/gz openwrt_luci https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/luci/
src/gz openwrt_packages https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/packages/
src/gz openwrt_routing https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/routing/
src/gz openwrt_telephony https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/telephony/
EOF
        sed -i "/define Package\/default-settings\/install/a\\
\\t\$(INSTALL_DIR) \$(1)/etc\\n\
\t\$(INSTALL_DATA) ./files/99-distfeeds.conf \$(1)/etc/99-distfeeds.conf\n" package/emortal/default-settings/Makefile
        sed -i "/exit 0/i\\
[ -f \'/etc/99-distfeeds.conf\' ] && mv \'/etc/99-distfeeds.conf\' \'/etc/opkg/distfeeds.conf\'\n\
sed -ri \'/check_signature/s@^[^#]@#&@\' /etc/opkg.conf\n" package/emortal/default-settings/files/99-default-settings
    fi
}

set_build_signature() {
    cd $BUILD_PATH
    local file="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
    if [ -f "$file" ]; then
        if ! grep -q "build by CoolLoong" "$file"; then
            sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ build by CoolLoong')/g" "$file"
        fi
    fi
}

update_menu_location() {
    cd $BUILD_PATH
    if [ -f "feeds/luci/applications/luci-app-samba4/root/usr/share/luci/menu.d/luci-app-samba4.json" ]; then
        sed -i 's/nas/services/g' "feeds/luci/applications/luci-app-samba4/root/usr/share/luci/menu.d/luci-app-samba4.json"
    fi
    if [ -f "feeds/small8/luci-app-tailscale/root/usr/share/luci/menu.d/luci-app-tailscale.json" ]; then
        sed -i 's/services/vpn/g' "feeds/small8/luci-app-tailscale/root/usr/share/luci/menu.d/luci-app-tailscale.json"
    fi
}

fix_compile_coremark() {
    cd $BUILD_PATH
    if [ -f "feeds/packages/utils/coremark/Makefile" ]; then
        sed -i 's/mkdir \$/mkdir -p \$/g' "feeds/packages/utils/coremark/Makefile"
    fi
}

update_dnsmasq_conf() {
    cd $BUILD_PATH
    if [ -f "package/network/services/dnsmasq/files/dhcp.conf" ]; then
        sed -i '/dns_redirect/d' "package/network/services/dnsmasq/files/dhcp.conf"
    fi
}

add_backup_info_to_sysupgrade() {
    cd $BUILD_PATH
    cat > "package/base-files/files/etc/sysupgrade.conf" <<'EOF'
/etc/AdGuardHome.yaml
/etc/easytier
/etc/lucky/
EOF
}

update_script_priority() {
    cd $BUILD_PATH
    if [ -f "package/feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init" ]; then
        sed -i 's/START=.*/START=88/g' "package/feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init"
    fi
    if [ -f "package/kernel/mac80211/files/qca-nss-pbuf.init" ]; then
        sed -i 's/START=.*/START=89/g' "package/kernel/mac80211/files/qca-nss-pbuf.init"
    fi
    if [ -f "package/feeds/small8/luci-app-mosdns/root/etc/init.d/mosdns" ]; then
        sed -i 's/START=.*/START=94/g' "package/feeds/small8/luci-app-mosdns/root/etc/init.d/mosdns"
    fi
}

update_oaf_deconfig() {
    cd $BUILD_PATH
    local conf_path="feeds/small8/open-app-filter/files/appfilter.config"
    if [ -f "$conf_path" ]; then
        sed -i -e "s/record_enable '1'/record_enable '0'/g" \
            -e "s/disable_hnat '1'/disable_hnat '0'/g" -e "s/auto_load_engine '1'/auto_load_engine '0'/g" "$conf_path"
    fi

    local uci_def="feeds/small8/luci-app-oaf/root/etc/uci-defaults/94_feature_3.0"
    if [ -f "$uci_def" ]; then
        sed -i '/\(disable_hnat\|auto_load_engine\)/d' "$uci_def"
        cat > "feeds/small8/luci-app-oaf/root/etc/uci-defaults/99_disable_oaf" <<'EOF'
#!/bin/sh
[ "$(uci get appfilter.global.enable 2>/dev/null)" = "0" ] && {
    /etc/init.d/appfilter disable
    /etc/init.d/appfilter stop
}
EOF
        chmod +x "feeds/small8/luci-app-oaf/root/etc/uci-defaults/99_disable_oaf"
    fi
}

update_uwsgi_limit_as() {
    cd $BUILD_PATH
    if [ -f "feeds/packages/net/uwsgi/files-luci-support/luci-cgi_io.ini" ]; then
        sed -i 's/^limit-as = .*/limit-as = 8192/g' "feeds/packages/net/uwsgi/files-luci-support/luci-cgi_io.ini"
    fi
    if [ -f "feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini" ]; then
        sed -i 's/^limit-as = .*/limit-as = 8192/g' "feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini"
    fi
}

remove_tweaked_packages() {
    cd $BUILD_PATH
    local target_mk="include/target.mk"
    if [ -f "$target_mk" ] && grep -q "^DEFAULT_PACKAGES += \$(DEFAULT_PACKAGES.tweak)" "$target_mk"; then
        sed -i 's/DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/# DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/g' "$target_mk"
    fi
}

replace_build_by_signature() {
    cd $BUILD_PATH
    find feeds package -type f -path "*/luci-static/*" -exec sed -i 's/build by ZqinKing/build by CoolLoong/g' {} + 2>/dev/null || true
}

set_custom_banner() {
    cd $BUILD_PATH
    local banner_path="package/base-files/files/etc/banner"
    mkdir -p "$(dirname "$banner_path")"
    cat > "$banner_path" <<EOF
  ___       _          __        __    _
 / _ \ _ __(_) ___  _ _\ \      / / __| |_
| | | | '__| |/ _ \| '_ \ \ /\ / / '__| __|
| |_| | |  | | (_) | | | \ V  V /| |  | |_
 \___/|_|  |_|\___/|_| |_|\_/\_/ |_|   \__|

-----------------------------------------------------
  Author: CoolLoong
  Build Timestamp: $(date +"%Y-%m-%d %H:%M:%S")
-----------------------------------------------------
EOF
}

set_ttyd_auto_login() {
    cd $BUILD_PATH
    if [ -f "feeds/packages/utils/ttyd/files/ttyd.config" ]; then
        sed -i 's|/bin/login|/bin/login -f root|g' "feeds/packages/utils/ttyd/files/ttyd.config"
    fi
}

install_mihomo_for_openclash() {
    cd $BUILD_PATH
    local mihomo_ver="v1.19.12"
    local device_name="$1"
    local target_arch=""

    if [[ $device_name =~ ^x86_64.* ]]; then
        target_arch="linux-amd64-v3"
    elif [[ $device_name =~ ^x86.* ]]; then
        target_arch="linux-386"
    elif [[ $device_name =~ ^(ax6000|ax3600|r4a|r619ac|ax1800|ax6|redmiax6s|qualcomm|ipq|filogic).* ]]; then
        target_arch="linux-arm64"
    else
        target_arch="linux-arm64"
    fi

    local clash_core_dir="package/feeds/luci/luci-app-openclash/root/etc/openclash/core"
    if [ -d "package/feeds/luci/luci-app-openclash" ] && [ ! -f "$clash_core_dir/clash_meta" ]; then
        mkdir -p "$clash_core_dir"
        local mihomo_url="https://github.com/MetaCubeX/mihomo/releases/download/${mihomo_ver}/mihomo-${target_arch}-${mihomo_ver}.gz"
        local temp_dir=$(mktemp -d)

        echo "下载 mihomo ($target_arch)..."
        if curl -sL --retry 3 --max-time 30 -o "$temp_dir/mihomo.gz" "$mihomo_url"; then
            gunzip -c "$temp_dir/mihomo.gz" > "$temp_dir/mihomo"
            chmod +x "$temp_dir/mihomo"
            cp "$temp_dir/mihomo" "$clash_core_dir/clash_meta"
            chmod +x "$clash_core_dir/clash_meta"
            echo "✅ mihomo 内核安装完成"
        fi
        rm -rf "$temp_dir"
    fi
}

set_default_password() {
    cd $BUILD_PATH
    sed -i 's#root:::0:99999:7:::#root:$1$zlz39mv2$a5xr3n0/qEre789LKYJ6J0::0:99999:7:::#g' \
        "package/base-files/files/etc/shadow"
}

remove_uhttpd_dependency() {
    cd $BUILD_PATH
    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" ".config" 2>/dev/null; then
        if [ -f "feeds/luci/collections/luci/Makefile" ]; then
            sed -i '/luci-light/d' "feeds/luci/collections/luci/Makefile"
        fi
    fi
}

# ==================== 应用自定义配置（所有构建模式都会调用）====================
apply_custom_configs() {
    cd $BUILD_PATH
    echo ""
    echo "========================================="
    echo "  应用自定义配置"
    echo "========================================="

    echo ">>> 软件包配置"
    fix_default_set                     # 设置默认主题和 UCI defaults
    fix_miniupnpd                       # UPnP支持
    update_oaf_deconfig                 # 应用过滤配置
    set_ttyd_auto_login                 # ttyd自动登录
    install_mihomo_for_openclash "$Dev" # OpenClash内核

    echo ">>> 系统增强"
    update_uwsgi_limit_as               # 提高LuCI内存限制
    install_opkg_distfeeds              # 添加官方软件源
    add_backup_info_to_sysupgrade       # 系统升级备份配置
    update_script_priority              # 优化服务启动顺序
    update_dnsmasq_conf                 # dnsmasq配置优化
    set_custom_task                     # 配置定时任务（内存清理、WireGuard监控）
    set_default_password                # 设置默认密码
    set_build_signature                 # 构建签名
    update_menu_location                # 菜单位置调整
    set_custom_banner                   # 自定义 banner
    replace_build_by_signature          # 替换签名
    update_default_lan_host_addr        # 设置 LAN 地址和主机名

    echo "✅ 自定义配置应用完成"
}

run_full_initialization() {
    echo ">>> 1: 核心初始化"
    clone_repo
    clean_up
    reset_feeds_conf
    update_feeds
    clone_luci_theme_orion
    remove_unwanted_packages
    remove_tweaked_packages

    echo ">>> 2: 编译环境配置"
    update_golang
    change_dnsmasq2full
    fix_mk_def_depends

    echo ">>> 3: 编译错误修复"
    fix_compile_coremark
    apply_luci_base_patch
    apply_luci_firewall_patch
    apply_ppp_fix_patch

    echo ">>> 4: 安装Feeds"
    install_feeds

    echo ">>> 5: 应用自定义配置"
    apply_custom_configs
}

run_incremental_build() {
    cd $BUILD_PATH
    if [[ "$UPDATE_FEEDS" == "true" ]]; then
        echo ">>> 更新 feeds 源代码"
        update_feeds
        clone_luci_theme_orion
        install_feeds
        apply_custom_configs
    else
        echo ">>> 保持 feeds 源代码不变，应用自定义配置"
        apply_custom_configs
    fi
    echo "✅ 增量构建准备完成"
}

# ==================== 主函数 ====================
main() {
    echo ""
    echo "========================================="
    echo "  OrionWrt 构建脚本"
    echo "========================================="
    echo "设备: $Dev"
    echo "构建模式: ${Build_Mod:-normal}"
    echo "仓库: $REPO_URL"
    echo "分支: $REPO_BRANCH"
    echo "构建目录: $BUILD_DIR"
    echo "提交哈希: $COMMIT_HASH"
    echo "强制初始化: $FORCE_INIT"
    echo "更新 Feeds: $UPDATE_FEEDS"
    echo "需要初始化: $NEEDS_INIT"
    echo "========================================="

    # 根据检测结果执行初始化或增量构建
    if [[ "$NEEDS_INIT" == "true" ]]; then
        run_full_initialization
    else
        run_incremental_build
    fi

    # 复制配置文件
    echo "复制设备配置..."
    cp -f "$CONFIG_FILE" "$BUILD_PATH/.config"

    # 移除 uhttpd 依赖
    remove_uhttpd_dependency

    # 进入构建目录
    cd "$BUILD_PATH"

    # 生成配置
    echo "生成配置..."
    make defconfig

    # Debug 模式退出
    if [[ $Build_Mod == "debug" ]]; then
        echo "Debug 模式，配置生成完成，不执行编译"
        exit 0
    fi

    # 删除旧的固件文件
    if [[ -d bin/targets ]]; then
        find bin/targets -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" \
            -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -delete
    fi

    # 下载源码包
    echo ""
    echo "========================================="
    echo "  下载源码包"
    echo "========================================="
    make download -j$(($(nproc) * 2))

    # 开始编译
    echo ""
    echo "========================================="
    echo "  开始编译固件"
    echo "========================================="
    make -j$(($(nproc) + 1)) V=s
    # make -j1 V=s

    # 复制固件到输出目录
    echo ""
    echo "========================================="
    echo "  复制固件到输出目录"
    echo "========================================="
    local firmware_dir="$BASE_PATH/firmware"
    rm -rf "$firmware_dir"
    mkdir -p "$firmware_dir"
    find bin/targets -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*efi.img.gz" \
        -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) \
        -exec cp -f {} "$firmware_dir/" \;
    rm -f "$firmware_dir/Packages.manifest" 2>/dev/null

    # action_build 特殊处理
    [[ -d $BASE_PATH/action_build ]] && make clean

    echo ""
    echo "========================================="
    echo "  ✅ 构建完成！"
    echo "  固件位置: $firmware_dir"
    echo "========================================="
}

# 执行主函数
main "$@"