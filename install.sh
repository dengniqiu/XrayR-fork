#!/bin/bash
# XrayR Install Script (Community Fork)
# 原始仓库 XrayR-project/XrayR-release 已删除
# Fork 维护: https://github.com/dengniqiu/XrayR-fork
set -euo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

# ========== 可配置变量（支持环境变量覆盖） ==========
FORK_REPO="${XRAYR_REPO:-dengniqiu/XrayR-fork}"
FORK_RAW="https://raw.githubusercontent.com/${FORK_REPO}/main"
API_BASE="https://api.github.com"
RELEASE_BASE="https://github.com/${FORK_REPO}/releases/download"
INSTALL_DIR="${XRAYR_INSTALL_DIR:-/usr/local/XrayR}"
CONFIG_DIR="${XRAYR_CONFIG_DIR:-/etc/XrayR}"
SERVICE_NAME="XrayR"

# ========== 工具函数 ==========
fail() {
    echo -e "${red}错误: $*${plain}" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || install_dep "$1"
}

install_dep() {
    local cmd="$1"
    echo -e "${yellow}  正在安装 $cmd...${plain}"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>/dev/null || true
        apt-get install -y "$cmd"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$cmd"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$cmd"
    elif command -v apk >/dev/null 2>&1; then
        apk add "$cmd"
    fi
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd 安装失败，请手动安装"
}

download() {
    local url="$1" output="$2"
    curl -fL --retry 3 --retry-delay 3 "$url" -o "$output"
}

# 返回系统总内存，单位为 KiB。读取失败时返回 0，由调用方按高内存流程处理。
total_memory_kib() {
    local memory
    memory="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    [[ "$memory" =~ ^[0-9]+$ ]] && echo "$memory" || echo 0
}

# ========== 架构检测（支持 10+ 种架构） ==========
detect_asset_name() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)     echo "linux-64" ;;
        i386|i686)        echo "linux-32" ;;
        aarch64|arm64)    echo "linux-arm64-v8a" ;;
        armv7l|armv7*)    echo "linux-arm32-v7a" ;;
        armv6l|armv6*)    echo "linux-arm32-v6" ;;
        armv5tel|armv5*)  echo "linux-arm32-v5" ;;
        riscv64)          echo "linux-riscv64" ;;
        ppc64le)          echo "linux-ppc64le" ;;
        s390x)            echo "linux-s390x" ;;
        mips64le)         echo "linux-mips64le" ;;
        mips64)           echo "linux-mips64" ;;
        mipsle)           echo "linux-mips32le" ;;
        mips)             echo "linux-mips32" ;;
        *) fail "不支持的架构: $arch" ;;
    esac
}

# ========== 获取最新版本号 ==========
latest_version() {
    # 1. 尝试从 GitHub API 获取
    local tmpfile="/tmp/xrayr-latest-version.$$"
    curl -sSL --retry 2 --retry-delay 3 "${API_BASE}/repos/${FORK_REPO}/releases/latest" -o "$tmpfile" 2>/dev/null || {
        # 2. API 失败，尝试从 raw 文件获取
        local ver
        ver="$(curl -sSL --retry 2 --retry-delay 3 "${FORK_RAW}/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]')"
        if [[ -n "$ver" ]]; then
            echo "$ver"
        else
            echo "v1.0.0"
        fi
        rm -f "$tmpfile"
        return
    }
    local tag=""
    if command -v jq >/dev/null 2>&1; then
        tag="$(jq -r '.tag_name // empty' "$tmpfile" 2>/dev/null)"
    else
        tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmpfile" | head -1)"
    fi
    rm -f "$tmpfile"
    if [[ -z "$tag" ]]; then
        echo "v1.0.0"
        return
    fi
    echo "$tag"
}

# ========== 生成 systemd 服务文件（无需额外下载） ==========
write_service() {
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    cat > "$service_file" <<SERVICE
[Unit]
Description=XrayR Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/XrayR --config ${CONFIG_DIR}/config.yml
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE
    echo "  ✓ ${SERVICE_NAME}.service"
}

# ========== 安装流程 ==========
install() {
    echo -e "${green}===== 开始安装 XrayR =====${plain}"

    # 前置检查
    [[ $EUID -eq 0 ]] || fail "必须使用 root 用户运行此脚本"
    [[ "$(uname -s)" == "Linux" ]] || fail "仅支持 Linux 系统"

    # 依赖检查。低内存路径不需要 unzip，避免安装和运行解压程序时增加内存压力。
    need_command curl
    local memory_kib
    memory_kib="$(total_memory_kib)"
    local low_memory=0
    if [[ "$memory_kib" -gt 0 && "$memory_kib" -le 524288 ]]; then
        low_memory=1
        echo -e "  检测到内存: $((memory_kib / 1024)) MiB，不超过 512 MiB，使用直接下载模式"
    else
        echo -e "  检测到内存: ${memory_kib} KiB，使用 ZIP 解压模式"
        need_command unzip
    fi

    # 获取版本号（支持环境变量 XRAYR_VERSION 指定）
    local version="${XRAYR_VERSION:-}"
    if [[ -z "$version" ]]; then
        echo -e "${yellow}获取最新版本...${plain}"
        version="$(latest_version)"
        echo "  最新版本: ${version}"
    else
        echo "  指定版本: ${version}"
    fi

    # 架构检测
    local asset_name
    asset_name="$(detect_asset_name)"
    echo "  系统架构: ${asset_name}"

    # 创建目录
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

    # 备份已有配置
    local has_existing=0
    for f in config.yml custom_inbound.json custom_outbound.json dns.json route.json rulelist; do
        if [[ -f "${CONFIG_DIR}/${f}" ]]; then
            has_existing=1
            break
        fi
    done
    if [[ $has_existing -eq 1 ]]; then
        local backup_dir="${CONFIG_DIR}.bak.$(date +%Y%m%d%H%M%S)"
        echo -e "${yellow}  检测到已有配置文件，备份至: ${backup_dir}${plain}"
        cp -r "$CONFIG_DIR" "$backup_dir"
    fi

    # 创建临时目录（函数退出时自动清理）
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    # ---- [1/4] 下载 XrayR 二进制 ----
    echo -e "${yellow}[1/4] 下载 XrayR 二进制文件...${plain}"
    local asset_url
    local bin_file
    if [[ "$low_memory" -eq 1 ]]; then
        # Releases 同时提供无压缩二进制，避免 ZIP 解压的额外内存占用。
        asset_url="${RELEASE_BASE}/${version}/XrayR-${asset_name}"
        bin_file="${tmp_dir}/XrayR"
        echo "  低内存直接下载: ${asset_url}"
        download "$asset_url" "$bin_file" || fail "可执行文件下载失败，请检查版本号或该架构文件是否存在"
    else
        asset_url="${RELEASE_BASE}/${version}/XrayR-${asset_name}.zip"
        local archive="${tmp_dir}/XrayR-${asset_name}.zip"
        echo "  下载: ${asset_url}"
        download "$asset_url" "$archive" || fail "下载失败，请检查版本号是否存在"
        unzip -q "$archive" -d "${tmp_dir}/archive" || fail "解压失败"

        # zip 内二进制可能嵌套在子目录中
        bin_file="$(find "${tmp_dir}/archive" -name "XrayR" -type f | head -1)"
        [[ -n "$bin_file" ]] || fail "Release 文件中未找到 XrayR 二进制"
    fi

    cp "$bin_file" "$INSTALL_DIR/XrayR"
    chmod +x "$INSTALL_DIR/XrayR"
    echo "  ✓ XrayR 二进制安装完成"

    # ---- [2/4] 下载配置文件（已存在则跳过） ----
    echo -e "${yellow}[2/4] 下载配置文件...${plain}"
    for f in config.yml custom_inbound.json custom_outbound.json dns.json route.json rulelist; do
        if [[ -f "${CONFIG_DIR}/${f}" ]]; then
            echo -e "  ${yellow}${f} 已存在，跳过${plain}"
        else
            download "${FORK_RAW}/config/${f}" "${CONFIG_DIR}/${f}" && echo "  ✓ ${f}" || echo "  ✗ ${f}"
        fi
    done

    # ---- [3/4] 下载管理脚本 ----
    echo -e "${yellow}[3/4] 下载管理脚本...${plain}"
    download "${FORK_RAW}/scripts/xrayr-manager.sh" /usr/bin/XrayR || fail "管理脚本下载失败"
    chmod +x /usr/bin/XrayR
    ln -sf /usr/bin/XrayR /usr/bin/xrayr
    echo "  ✓ XrayR 管理脚本"

    # ---- [4/4] 配置 systemd 服务 ----
    echo -e "${yellow}[4/4] 配置 systemd 服务...${plain}"
    write_service
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    echo -e "${green}  ✓ 已设置开机自启${plain}"

    # ---- 完成 ----
    echo ""
    echo -e "${green}===== 安装完成 =====${plain}"
    echo ""
    echo -e "配置文件: ${yellow}${CONFIG_DIR}/config.yml${plain}"
    echo -e "启动服务: ${yellow}XrayR start${plain}"
    echo -e "查看状态: ${yellow}XrayR status${plain}"
    echo ""
    echo -e "${green}请先编辑配置文件，修改你的面板信息:${plain}"
    echo -e "  vi ${CONFIG_DIR}/config.yml"
}

# ========== 更新管理脚本 ==========
update_shell() {
    echo -e "${green}更新管理脚本...${plain}"
    download "${FORK_RAW}/scripts/xrayr-manager.sh" /usr/bin/XrayR || fail "下载失败"
    chmod +x /usr/bin/XrayR
    echo -e "${green}管理脚本更新完成！${plain}"
}

# ========== 卸载 ==========
uninstall() {
    echo -e "${red}卸载 XrayR...${plain}"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    rm -rf "$CONFIG_DIR"
    rm -rf "$INSTALL_DIR"
    rm -f /usr/bin/XrayR /usr/bin/xrayr
    echo -e "${green}卸载完成！${plain}"
}

# ========== 入口 ==========
case "${1:-}" in
    install) install ;;
    uninstall) uninstall ;;
    update_shell) update_shell ;;
    *)
        echo "XrayR 安装脚本 (社区 Fork)"
        echo "用法:"
        echo "  bash install.sh install       - 安装 XrayR"
        echo "  bash install.sh uninstall     - 卸载 XrayR"
        echo "  bash install.sh update_shell  - 更新管理脚本"
        echo ""
        echo "环境变量:"
        echo "  XRAYR_VERSION=v1.0.0    - 指定安装版本（默认自动获取最新）"
        echo "  XRAYR_REPO=user/repo    - 指定仓库（默认 dengniqiu/XrayR-fork）"
        echo "  XRAYR_INSTALL_DIR=/path - 安装目录"
        echo "  XRAYR_CONFIG_DIR=/path  - 配置目录"
        ;;
esac
