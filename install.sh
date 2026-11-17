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
[[ ! -f /etc/XrayR-manager.conf ]] || source /etc/XrayR-manager.conf
FORK_REPO="${XRAYR_REPO:-${XRAYR_SAVED_REPO:-dengniqiu/XrayR-fork}}"
FORK_RAW="https://raw.githubusercontent.com/${FORK_REPO}/main"
API_BASE="https://api.github.com"
RELEASE_BASE="https://github.com/${FORK_REPO}/releases/download"
INSTALL_DIR="${XRAYR_INSTALL_DIR:-${XRAYR_SAVED_INSTALL_DIR:-/usr/local/XrayR}}"
CMD_NAME="${XRAYR_CMD_NAME:-${XRAYR_SAVED_CMD_NAME:-XrayR}}"
CMD_ALIAS="${CMD_NAME,,}"
BINARY_NAME="$CMD_NAME"
CONFIG_DIR="${XRAYR_CONFIG_DIR:-${XRAYR_SAVED_CONFIG_DIR:-}}"
if [[ -z "$CONFIG_DIR" ]]; then
    if [[ "$CMD_NAME" == "XrayR" ]]; then
        CONFIG_DIR=/etc/XrayR
    else
        CONFIG_DIR="/etc/${CMD_ALIAS}"
    fi
fi
SERVICE_NAME="XrayR"
SERVICE_MANAGER=""
LEGACY_CONFIG_DIR="/etc/XrayR"

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
        apk add --no-cache "$cmd"
    fi
    command -v "$cmd" >/dev/null 2>&1 || fail "$cmd 安装失败，请手动安装"
}

download() {
    local url="$1" output="$2"
    curl -fL --retry 3 --retry-delay 3 "$url" -o "$output"
}

# 使用主机内存与容器 cgroup 限额的较小值，单位为 KiB。
total_memory_kib() {
    local memory limit path relative controller
    memory="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    [[ "$memory" =~ ^[0-9]+$ ]] || memory=0
    local paths=(/sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes)
    if [[ -r /proc/self/cgroup ]]; then
        while IFS=: read -r _ controller relative; do
            case "$controller" in
                '') paths+=("/sys/fs/cgroup${relative%/}/memory.max") ;;
                *memory*) paths+=("/sys/fs/cgroup/memory${relative%/}/memory.limit_in_bytes") ;;
            esac
        done < /proc/self/cgroup
    fi
    for path in "${paths[@]}"; do
        [[ -r "$path" ]] || continue
        limit="$(cat "$path" 2>/dev/null || true)"
        # Ignore 'max' and the large v1 unlimited sentinel before arithmetic.
        if [[ "$limit" =~ ^[0-9]+$ && ${#limit} -lt 16 && "$limit" -ge 1024 ]]; then
            limit=$((limit / 1024))
            if [[ "$memory" -eq 0 || "$limit" -lt "$memory" ]]; then
                memory="$limit"
            fi
        fi
    done
    echo "$memory"
}

# ========== 命令名称与配置目录 ==========
valid_command_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

command_name_free() {
    local target="/usr/bin/$1"
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        return 0
    fi
    # 已安装的旧管理脚本可以覆盖，其他程序占用则拒绝。
    [[ -L "$target" ]] && return 0
    grep -q 'xrayr-manager\|XrayR' "$target" 2>/dev/null
}

can_prompt() {
    [[ "${XRAYR_NONINTERACTIVE:-0}" == "1" ]] && return 1
    [[ -r /dev/tty && -w /dev/tty ]] || return 1
    # 标准输入被重定向成脚本文件时按非交互处理，避免等待输入。
    [[ -f /dev/stdin ]] && return 1
    return 0
}

# 只从终端读取，避免 curl | bash 时把脚本文本当成回答。
prompt_line() {
    local prompt="$1" default="$2" answer=""
    printf '%s' "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
    [[ -n "$answer" ]] || answer="$default"
    REPLY="$answer"
}

configure_names() {
    local name
    can_prompt || return 0
    if [[ -z "${XRAYR_CMD_NAME:-}" ]]; then
        echo > /dev/tty
        prompt_line "是否修改管理命令名称 (当前 ${CMD_NAME}/${CMD_ALIAS})? [y/N]: " n
        if [[ "$REPLY" =~ ^[Yy] ]]; then
            prompt_line "新的命令名称 (默认 ${CMD_NAME}): " "$CMD_NAME"
            name="$REPLY"
            if ! valid_command_name "$name"; then
                echo "名称只能包含字母、数字、点、下划线或短横线，且不能以符号开头，保持 ${CMD_NAME}" > /dev/tty
            elif ! command_name_free "$name"; then
                echo "/usr/bin/${name} 已被其他程序占用，保持 ${CMD_NAME}" > /dev/tty
            else
                CMD_NAME="$name"
                CMD_ALIAS="${name,,}"
                if [[ -z "${XRAYR_CONFIG_DIR:-}" ]]; then
                    CONFIG_DIR="/etc/${CMD_ALIAS}"
                fi
                echo "管理命令: ${CMD_NAME} (别名 ${CMD_ALIAS})" > /dev/tty
            fi
        fi
    fi
    [[ -n "${XRAYR_CONFIG_DIR:-}" ]] && return 0
    echo > /dev/tty
    prompt_line "是否修改配置目录 (当前 ${CONFIG_DIR})? [y/N]: " n
    [[ "$REPLY" =~ ^[Yy] ]] || return 0
    prompt_line "新的配置目录 (默认 ${CONFIG_DIR}): " "$CONFIG_DIR"
    CONFIG_DIR="${REPLY%/}"
}

migrate_legacy_config() {
    [[ "$CONFIG_DIR" == "$LEGACY_CONFIG_DIR" ]] && return 0
    [[ -d "$LEGACY_CONFIG_DIR" ]] || return 0
    if [[ ! -e "$CONFIG_DIR" ]]; then
        mv -- "$LEGACY_CONFIG_DIR" "$CONFIG_DIR"
        echo "  已把旧配置目录 ${LEGACY_CONFIG_DIR} 迁移到 ${CONFIG_DIR}"
    elif [[ ! -f "${CONFIG_DIR}/config.yml" && -f "${LEGACY_CONFIG_DIR}/config.yml" ]]; then
        cp -a -- "${LEGACY_CONFIG_DIR}/." "${CONFIG_DIR}/"
        echo -e "  ${yellow}已复制旧配置到 ${CONFIG_DIR}，旧目录 ${LEGACY_CONFIG_DIR} 未被删除${plain}"
    fi
}

install_manager_command() {
    local source="$1" name
    for name in XrayR xrayr; do
        [[ "$name" == "$CMD_NAME" || "$name" == "$CMD_ALIAS" ]] && continue
        rm -f -- "/usr/bin/${name}"
    done
    mv -f -- "$source" "/usr/bin/${CMD_NAME}"
    chmod 755 "/usr/bin/${CMD_NAME}"
    [[ "$CMD_ALIAS" == "$CMD_NAME" ]] || ln -sfn "/usr/bin/${CMD_NAME}" "/usr/bin/${CMD_ALIAS}"
}

filesystem_type() {
    df -PT "$1" 2>/dev/null | awk 'NR > 1 {print $2; exit}'
}

validate_paths() {
    local path
    for path in "$INSTALL_DIR" "$CONFIG_DIR"; do
        # These paths are embedded in shell/service files and used by uninstall.
        [[ "$path" == /* && "$path" =~ ^/[a-zA-Z0-9_./-]+$ ]] || fail "目录必须是绝对路径，且仅含字母、数字、下划线、点、短横线和斜线: $path"
        case "$path" in
            */../*|*/..|*/./*|*/.) fail "目录不能包含 . 或 .. 路径段: $path" ;;
        esac
        case "${path%/}" in
            ''|/|/etc|/usr|/usr/local|/bin|/sbin|/var|/var/log|/tmp|/root|/home|/mnt|/opt|/run)
                fail "拒绝将系统目录作为可卸载目录: $path" ;;
        esac
    done
}

write_manager_settings() {
    local settings
    settings="$(mktemp /etc/.XrayR-manager.XXXXXX)"
    printf 'XRAYR_SAVED_REPO=%q\nXRAYR_SAVED_INSTALL_DIR=%q\nXRAYR_SAVED_CONFIG_DIR=%q\nXRAYR_SAVED_CMD_NAME=%q\n' \
        "$FORK_REPO" "$INSTALL_DIR" "$CONFIG_DIR" "$CMD_NAME" > "$settings"
    chmod 600 "$settings"
    mv -f -- "$settings" /etc/XrayR-manager.conf
}

detect_service_manager() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        SERVICE_MANAGER=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        SERVICE_MANAGER=openrc
    else
        fail "未检测到正在使用的 systemd 或 OpenRC；Alpine 请使用 OpenRC 系统环境"
    fi
}

service_installed() {
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        [[ -f "/etc/init.d/${SERVICE_NAME}" ]]
    else
        [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]
    fi
}

service_running() {
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        rc-service "$SERVICE_NAME" status >/dev/null 2>&1
    else
        systemctl is-active --quiet "$SERVICE_NAME"
    fi
}

service_action() {
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        rc-service "$SERVICE_NAME" "$1"
    else
        systemctl "$1" "$SERVICE_NAME"
    fi
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
    local response
    response="$(curl -fsSL --max-time 30 --retry 2 --retry-delay 3 "${API_BASE}/repos/${FORK_REPO}/releases/latest" 2>/dev/null)" || {
        # 2. API 失败，尝试从 raw 文件获取
        local ver
        ver="$(curl -fsSL --max-time 30 --retry 2 --retry-delay 3 "${FORK_RAW}/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
        if [[ -n "$ver" ]]; then
            echo "$ver"
        else
            echo "v1.0.0"
        fi
        return
    }
    local tag=""
    if command -v jq >/dev/null 2>&1; then
        tag="$(printf '%s' "$response" | jq -r '.tag_name // empty' 2>/dev/null || true)"
    else
        tag="$(printf '%s' "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    fi
    if [[ -z "$tag" ]]; then
        echo "v1.0.0"
        return
    fi
    echo "$tag"
}

# ========== 生成服务文件（无需额外下载） ==========
write_service() {
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        mkdir -p /etc/init.d
        cat > "/etc/init.d/${SERVICE_NAME}" <<SERVICE
#!/sbin/openrc-run
description="XrayR Service"
supervisor=supervise-daemon
command="${INSTALL_DIR}/${BINARY_NAME}"
command_args="--config \"${CONFIG_DIR}/config.yml\""
directory="${INSTALL_DIR}"
pidfile="/run/\${RC_SVCNAME}.pid"
respawn_delay=10
respawn_max=5
respawn_period=60
output_log="/var/log/XrayR.log"
error_log="/var/log/XrayR.log"

if [ -f "${CONFIG_DIR}/runtime.env" ]; then
    set -a
    . "${CONFIG_DIR}/runtime.env"
    set +a
fi

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f -m 0600 -o root:root "\$output_log"
}
SERVICE
        chmod +x "/etc/init.d/${SERVICE_NAME}"
        rc-update add "$SERVICE_NAME" default
        echo "  ✓ OpenRC ${SERVICE_NAME}"
        return
    fi
    local service_file="/etc/systemd/system/${SERVICE_NAME}.service"
    mkdir -p /etc/systemd/system
    cat > "$service_file" <<SERVICE
[Unit]
Description=XrayR Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${BINARY_NAME} --config ${CONFIG_DIR}/config.yml
EnvironmentFile=-${CONFIG_DIR}/runtime.env
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE
    echo "  ✓ ${SERVICE_NAME}.service"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
}

write_runtime_env() {
    local memory_kib="$1"
    [[ -e "${CONFIG_DIR}/runtime.env" ]] && return 0
    if [[ "$memory_kib" -gt 0 && "$memory_kib" -le 524288 ]]; then
        # Soft Go runtime budget; not a process RSS limit or an OOM guarantee.
        local budget_mib=$((memory_kib / 1024 / 2))
        printf 'GOMEMLIMIT=%sMiB\nGOGC=50\n' "$budget_mib" > "${CONFIG_DIR}/runtime.env"
        echo "  低内存运行参数: GOMEMLIMIT=${budget_mib}MiB, GOGC=50（软限制）"
    fi
}

# ========== 安装流程 ==========
install() (
    echo -e "${green}===== 开始安装 XrayR =====${plain}"

    # 前置检查
    [[ $EUID -eq 0 ]] || fail "必须使用 root 用户运行此脚本"
    [[ "$(uname -s)" == "Linux" ]] || fail "仅支持 Linux 系统"
    configure_names
    valid_command_name "$CMD_NAME" || fail "管理命令名称不合法: $CMD_NAME"
    validate_paths
    detect_service_manager
    migrate_legacy_config

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
    local fs_type
    fs_type="$(filesystem_type "$INSTALL_DIR" || true)"
    if [[ "$low_memory" -eq 1 ]]; then
        case "$fs_type" in
            tmpfs|ramfs|rootfs)
                fail "安装目录 ${INSTALL_DIR} 位于 ${fs_type} 内存盘。112 MiB 二进制无法安全放入此低内存环境；请将磁盘挂载到安装目录，或用 XRAYR_INSTALL_DIR 指向真实磁盘（Alpine diskless 根目录也可能是内存盘）"
                ;;
            '') fail "无法检测安装目录文件系统，停止下载以避免写入内存盘" ;;
        esac
        echo "  安装目录文件系统: ${fs_type}；下载文件直接暂存于安装目录，不使用 /tmp"
    fi

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

    # 暂存于目标文件系统；无论成功、失败或收到信号均清理。
    local tmp_dir was_running=0 binary_replaced=0 had_binary=0
    tmp_dir="$(mktemp -d "${INSTALL_DIR}/.install.XXXXXX")"
    cleanup_install() {
        local result=$?
        trap - EXIT
        if [[ "$result" -ne 0 ]]; then
            if [[ "$binary_replaced" -eq 1 ]]; then
                if [[ "$had_binary" -eq 1 ]]; then
                    rm -f -- "${INSTALL_DIR}/${BINARY_NAME}"
                    mv -f -- "${tmp_dir}/previous-XrayR" "$old_binary" || true
                else
                    rm -f -- "${INSTALL_DIR}/${BINARY_NAME}"
                fi
            fi
            if [[ -f "${tmp_dir}/previous-service" ]]; then
                if [[ "$SERVICE_MANAGER" == openrc ]]; then
                    cp -p -- "${tmp_dir}/previous-service" "/etc/init.d/${SERVICE_NAME}"
                else
                    cp -p -- "${tmp_dir}/previous-service" "/etc/systemd/system/${SERVICE_NAME}.service"
                    systemctl daemon-reload || true
                fi
            fi
            if [[ "$was_running" -eq 1 ]]; then
                service_action start || echo "请检查 XrayR status，服务恢复失败" >&2
            fi
        fi
        rm -rf -- "$tmp_dir"
        exit "$result"
    }
    trap cleanup_install EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

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
        mkdir -p "${tmp_dir}/archive"
        unzip -q "$archive" -d "${tmp_dir}/archive" || fail "解压失败"

        # zip 内二进制可能嵌套在子目录中
        bin_file="$(find "${tmp_dir}/archive" -name "XrayR" -type f | head -1)"
        [[ -n "$bin_file" ]] || fail "Release 文件中未找到 XrayR 二进制"
    fi

    [[ -s "$bin_file" ]] || fail "下载的 XrayR 二进制为空"
    chmod +x "$bin_file"
    echo "  ✓ XrayR 二进制下载完成，等待原子替换"

    # ---- [2/4] 下载配置文件（已存在则跳过） ----
    echo -e "${yellow}[2/4] 下载配置文件...${plain}"
    for f in config.yml custom_inbound.json custom_outbound.json dns.json route.json rulelist; do
        if [[ -f "${CONFIG_DIR}/${f}" ]]; then
            echo -e "  ${yellow}${f} 已存在，跳过${plain}"
        else
            download "${FORK_RAW}/config/${f}" "${tmp_dir}/${f}" || fail "配置 ${f} 下载失败"
            mv -f -- "${tmp_dir}/${f}" "${CONFIG_DIR}/${f}"
            echo "  ✓ ${f}"
        fi
    done

    # ---- [3/4] 下载管理脚本 ----
    echo -e "${yellow}[3/4] 下载管理脚本...${plain}"
    download "${FORK_RAW}/scripts/xrayr-manager.sh" "${tmp_dir}/xrayr-manager.sh" || fail "管理脚本下载失败"
    bash -n "${tmp_dir}/xrayr-manager.sh" || fail "管理脚本语法不正确"
    chmod +x "${tmp_dir}/xrayr-manager.sh"

    # ---- [4/4] 配置服务 ----
    echo -e "${yellow}[4/4] 配置 ${SERVICE_MANAGER} 服务...${plain}"
    # Rename on the same filesystem, retaining the old executable for rollback.
    # Do not create a second in-memory copy or truncate a running executable.
    if service_installed; then
        if [[ "$SERVICE_MANAGER" == openrc ]]; then
            cp -p -- "/etc/init.d/${SERVICE_NAME}" "${tmp_dir}/previous-service"
        else
            cp -p -- "/etc/systemd/system/${SERVICE_NAME}.service" "${tmp_dir}/previous-service"
        fi
    fi
    if service_installed && service_running; then
        service_action stop
        was_running=1
    fi
    local old_binary="${INSTALL_DIR}/${BINARY_NAME}"
    if [[ ! -f "$old_binary" && "$BINARY_NAME" != "XrayR" && -f "${INSTALL_DIR}/XrayR" ]]; then
        old_binary="${INSTALL_DIR}/XrayR"
    fi
    if [[ -f "$old_binary" ]]; then
        mv -- "$old_binary" "${tmp_dir}/previous-XrayR"
        had_binary=1
    fi
    binary_replaced=1
    mv -- "$bin_file" "${INSTALL_DIR}/${BINARY_NAME}"
    [[ "$BINARY_NAME" == "XrayR" ]] || rm -f -- "${INSTALL_DIR}/XrayR"
    install_manager_command "${tmp_dir}/xrayr-manager.sh"
    write_manager_settings
    write_runtime_env "$memory_kib"
    write_service
    echo -e "${green}  ✓ 已设置开机自启${plain}"
    if [[ "$was_running" -eq 1 ]]; then
        service_action start
        echo "  ✓ 已重新启动原来运行的服务"
    fi

    # ---- 完成 ----
    echo ""
    echo -e "${green}===== 安装完成 =====${plain}"
    echo ""
    echo -e "配置文件: ${yellow}${CONFIG_DIR}/config.yml${plain}"
    echo -e "管理命令: ${yellow}${CMD_NAME}${plain} (别名 ${CMD_ALIAS})"
    echo -e "启动服务: ${yellow}${CMD_NAME} start${plain}"
    echo -e "查看状态: ${yellow}${CMD_NAME} status${plain}"
    echo ""
    echo -e "${green}请先编辑配置文件，修改你的面板信息:${plain}"
    echo -e "  vi ${CONFIG_DIR}/config.yml"
)

# ========== 更新管理脚本 ==========
update_shell() {
    echo -e "${green}更新管理脚本...${plain}"
    download "${FORK_RAW}/scripts/xrayr-manager.sh" "/usr/bin/${CMD_NAME}" || fail "下载失败"
    chmod +x "/usr/bin/${CMD_NAME}"
    [[ "$CMD_ALIAS" == "$CMD_NAME" ]] || ln -sfn "/usr/bin/${CMD_NAME}" "/usr/bin/${CMD_ALIAS}"
    echo -e "${green}管理脚本更新完成！${plain}"
}

# ========== 卸载 ==========
uninstall() {
    echo -e "${red}卸载 XrayR...${plain}"
    [[ $EUID -eq 0 ]] || fail "必须使用 root 用户运行此脚本"
    validate_paths
    detect_service_manager
    service_action stop 2>/dev/null || true
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        rc-update del "$SERVICE_NAME" default 2>/dev/null || true
        rm -f "/etc/init.d/${SERVICE_NAME}"
    else
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        rm -rf -- /etc/systemd/system/XrayR.service.d
        systemctl daemon-reload
        systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
    fi
    rm -rf -- "$CONFIG_DIR" "$INSTALL_DIR"
    # 迁移后遗留的空目录只有在不再含配置文件时才清理。
    if [[ "$CONFIG_DIR" != "$LEGACY_CONFIG_DIR" && -d "$LEGACY_CONFIG_DIR" \
        && ! -f "${LEGACY_CONFIG_DIR}/config.yml" ]]; then
        rm -rf -- "$LEGACY_CONFIG_DIR"
    fi
    # Only remove timestamped backups produced by this installer.
    local backup
    for backup in "${CONFIG_DIR}".bak.*; do
        [[ "${backup#"${CONFIG_DIR}.bak."}" =~ ^[0-9]{14}$ ]] || continue
        rm -rf -- "$backup"
    done
    rm -rf -- /var/log/XrayR /var/cache/XrayR /var/cache/xrayr \
        /etc/systemd/system/XrayR.service.d
    rm -f -- /var/log/XrayR.log /var/log/XrayR.log.* \
        /run/XrayR.pid /tmp/xrayr-manager.sh
    rm -f -- "/usr/bin/${CMD_NAME}" "/usr/bin/${CMD_ALIAS}" \
        /usr/bin/XrayR /usr/bin/xrayr /etc/XrayR-manager.conf
    echo -e "${green}卸载完成！${plain}"
}

# ========== 入口 ==========
main() {
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
        echo "  XRAYR_CMD_NAME=name     - 管理命令名称（默认 XrayR，另建小写别名）"
        echo "  XRAYR_NONINTERACTIVE=1  - 跳过命令名称与配置目录的交互提问"
        ;;
esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
