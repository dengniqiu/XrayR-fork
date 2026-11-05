#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

version="v1.0.0"
[[ ! -f /etc/XrayR-manager.conf ]] || source /etc/XrayR-manager.conf
FORK_REPO="${XRAYR_REPO:-${XRAYR_SAVED_REPO:-dengniqiu/XrayR-fork}}"
FORK_RAW="https://raw.githubusercontent.com/${FORK_REPO}/main"
INSTALL_DIR="${XRAYR_INSTALL_DIR:-${XRAYR_SAVED_INSTALL_DIR:-/usr/local/XrayR}}"
CONFIG_DIR="${XRAYR_CONFIG_DIR:-${XRAYR_SAVED_CONFIG_DIR:-/etc/XrayR}}"
SERVICE_NAME="XrayR"
SERVICE_MANAGER=""
export XRAYR_REPO="$FORK_REPO" XRAYR_INSTALL_DIR="$INSTALL_DIR" XRAYR_CONFIG_DIR="$CONFIG_DIR"

check_environment() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${red}错误: 必须使用 root 用户运行此脚本${plain}" >&2
        return 1
    fi
    local os_version=""
    release=""
    if [[ -f /etc/alpine-release ]]; then
        release=alpine
    elif [[ -f /etc/redhat-release ]]; then
        release=centos
    elif grep -qi ubuntu /etc/issue /proc/version 2>/dev/null; then
        release=ubuntu
    elif grep -qi debian /etc/issue /proc/version 2>/dev/null; then
        release=debian
    elif grep -Eqi 'centos|red hat|redhat' /etc/issue /proc/version 2>/dev/null; then
        release=centos
    fi
    if [[ -f /etc/os-release ]]; then
        os_version=$(awk -F'[= ."]' '/^VERSION_ID=/{print $3}' /etc/os-release)
    fi
    if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
        os_version=$(awk -F'[= ."]+' '/^DISTRIB_RELEASE=/{print $2}' /etc/lsb-release)
    fi
    case "$release" in
        centos) [[ "${os_version:-0}" -ge 7 ]] || { echo "请使用 CentOS 7 或更高版本" >&2; return 1; } ;;
        ubuntu) [[ "${os_version:-0}" -ge 16 ]] || { echo "请使用 Ubuntu 16 或更高版本" >&2; return 1; } ;;
        debian) [[ "${os_version:-0}" -ge 8 ]] || { echo "请使用 Debian 8 或更高版本" >&2; return 1; } ;;
        alpine) ;;
        *) echo "未识别系统版本，将按服务管理器检测结果运行" >&2 ;;
    esac
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        SERVICE_MANAGER=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        SERVICE_MANAGER=openrc
    else
        echo -e "${red}未检测到 systemd 或 OpenRC 服务管理器${plain}" >&2
        return 1
    fi
}

service_action() {
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        rc-service "$SERVICE_NAME" "$1"
    else
        systemctl "$1" "$SERVICE_NAME"
    fi
}

run_installer() (
    local version="${1:-}" tmp_dir
    tmp_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "$tmp_dir"' EXIT
    curl -fL --retry 3 "${FORK_RAW}/install.sh" -o "${tmp_dir}/install.sh" || return 1
    XRAYR_VERSION="$version" bash "${tmp_dir}/install.sh" install
)

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -p "$1 [默认$2]: " temp
        if [[ x"${temp}" == x"" ]]; then
            temp=$2
        fi
    else
        read -p "$1 [y/n]: " temp
    fi
    if [[ x"${temp}" == x"y" || x"${temp}" == x"Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启XrayR" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车返回主菜单: ${plain}" && read temp
    show_menu
}

install() {
    if run_installer "${2:-}"; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    local version=""
    if [[ $# == 0 ]]; then
        echo && echo -n -e "输入指定版本(默认最新版): " && read version_input
        version="$version_input"
    else
        version="${2:-}"
    fi
    if run_installer "$version"; then
        echo -e "${green}更新完成，原来运行的服务已由安装器恢复；使用 XrayR status 查看状态${plain}"
        return 0
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

config() {
    echo "XrayR在修改配置后会自动尝试重启"
    vi "${CONFIG_DIR}/config.yml"
    sleep 2
    check_status
    case $? in
        0)
            echo -e "XrayR状态: ${green}已运行${plain}"
            ;;
        1)
            echo -e "检测到您未启动XrayR或XrayR自动重启失败，是否查看日志？[Y/n]" && echo
            read -e -p "(默认: y):" yn
            [[ -z ${yn} ]] && yn="y"
            if [[ ${yn} == [Yy] ]]; then
               show_log
            fi
            ;;
        2)
            echo -e "XrayR状态: ${red}未安装${plain}"
    esac
}

uninstall() {
    local path
    for path in "$INSTALL_DIR" "$CONFIG_DIR"; do
        [[ "$path" == /* && "$path" =~ ^/[a-zA-Z0-9_./-]+$ ]] || return 1
        case "$path" in
            */../*|*/..|*/./*|*/.) echo "拒绝删除不安全的目录: $path" >&2; return 1 ;;
        esac
        case "${path%/}" in
            ''|/|/etc|/usr|/usr/local|/bin|/sbin|/var|/var/log|/tmp|/root|/home|/mnt|/opt|/run)
                echo "拒绝删除系统目录: $path" >&2; return 1 ;;
        esac
    done
    confirm "确定要卸载 XrayR 吗?" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    service_action stop
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        rc-update del "$SERVICE_NAME" default
        rm -f "/etc/init.d/${SERVICE_NAME}"
    else
        systemctl disable "$SERVICE_NAME"
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload
        systemctl reset-failed "$SERVICE_NAME"
    fi
    rm -rf -- "$CONFIG_DIR" "$INSTALL_DIR"
    rm -f /etc/XrayR-manager.conf

    echo ""
    echo -e "卸载成功，如果你想删除此脚本，则退出脚本后运行 ${green}rm /usr/bin/XrayR -f${plain} 进行删除"
    echo ""

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        echo -e "${green}XrayR已运行，无需再次启动，如需重启请选择重启${plain}"
    else
        service_action start
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            echo -e "${green}XrayR 启动成功，请使用 XrayR log 查看运行日志${plain}"
        else
            echo -e "${red}XrayR可能启动失败，请稍后使用 XrayR log 查看日志信息${plain}"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    service_action stop
    sleep 2
    check_status
    if [[ $? == 1 ]]; then
        echo -e "${green}XrayR 停止成功${plain}"
    else
        echo -e "${red}XrayR停止失败，可能是因为停止时间超过了两秒，请稍后查看日志信息${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    service_action restart
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        echo -e "${green}XrayR 重启成功，请使用 XrayR log 查看运行日志${plain}"
    else
        echo -e "${red}XrayR可能启动失败，请稍后使用 XrayR log 查看日志信息${plain}"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        service_action status
    else
        systemctl status "$SERVICE_NAME" --no-pager -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    local result=0
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        rc-update add "$SERVICE_NAME" default || result=$?
    else
        systemctl enable "$SERVICE_NAME" || result=$?
    fi
    if [[ $result == 0 ]]; then
        echo -e "${green}XrayR 设置开机自启成功${plain}"
    else
        echo -e "${red}XrayR 设置开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    local result=0
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        rc-update del "$SERVICE_NAME" default || result=$?
    else
        systemctl disable "$SERVICE_NAME" || result=$?
    fi
    if [[ $result == 0 ]]; then
        echo -e "${green}XrayR 取消开机自启成功${plain}"
    else
        echo -e "${red}XrayR 取消开机自启失败${plain}"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        if [[ ! -f /var/log/XrayR.log ]]; then
            echo "日志尚未生成，请先启动 XrayR"
            return 1
        fi
        tail -n 100 -f /var/log/XrayR.log
    else
        journalctl -u "${SERVICE_NAME}.service" -e --no-pager -f
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

install_bbr() {
    if [[ "${release:-}" == alpine ]]; then
        echo -e "${yellow}此第三方 BBR 内核安装脚本不支持 Alpine，已跳过${plain}"
        return 1
    fi
    bash <(curl -L -s https://raw.githubusercontent.com/chiakge/Linux-NetSpeed/master/tcp.sh)
    #if [[ $? == 0 ]]; then
    #    echo ""
    #    echo -e "${green}安装 bbr 成功，请重启服务器${plain}"
    #else
    #    echo ""
    #    echo -e "${red}下载 bbr 安装脚本失败，请检查本机能否连接 Github${plain}"
    #fi

    #before_show_menu
}

update_shell() {
    curl -fL --retry 3 "${FORK_RAW}/scripts/xrayr-manager.sh" -o /usr/bin/XrayR && chmod +x /usr/bin/XrayR
    if [[ $? != 0 ]]; then
        echo ""
        echo -e "${red}下载脚本失败，请检查本机能否连接 Github${plain}"
        before_show_menu
    else
        chmod +x /usr/bin/XrayR
        echo -e "${green}升级脚本成功，请重新运行脚本${plain}" && exit 0
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        [[ -f "/etc/init.d/${SERVICE_NAME}" ]] || return 2
        rc-service "$SERVICE_NAME" status >/dev/null 2>&1
    else
        [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]] || return 2
        systemctl is-active --quiet "$SERVICE_NAME"
    fi
    [[ $? == 0 ]] && return 0
    return 1
}

check_enabled() {
    if [[ "$SERVICE_MANAGER" == openrc ]]; then
        [[ -e "/etc/runlevels/default/${SERVICE_NAME}" ]]
    else
        systemctl is-enabled --quiet "$SERVICE_NAME"
    fi
}

check_uninstall() {
    check_status
    if [[ $? != 2 ]]; then
        echo ""
        echo -e "${red}XrayR已安装，请不要重复安装${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

check_install() {
    check_status
    if [[ $? == 2 ]]; then
        echo ""
        echo -e "${red}请先安装XrayR${plain}"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 1
    else
        return 0
    fi
}

show_status() {
    check_status
    case $? in
        0)
            echo -e "XrayR状态: ${green}已运行${plain}"
            show_enable_status
            ;;
        1)
            echo -e "XrayR状态: ${yellow}未运行${plain}"
            show_enable_status
            ;;
        2)
            echo -e "XrayR状态: ${red}未安装${plain}"
    esac
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "是否开机自启: ${green}是${plain}"
    else
        echo -e "是否开机自启: ${red}否${plain}"
    fi
}

show_XrayR_version() {
    echo -n "XrayR 版本："
    "${INSTALL_DIR}/XrayR" version
    echo ""
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_usage() {
    echo "XrayR 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "XrayR              - 显示管理菜单 (功能更多)"
    echo "XrayR start        - 启动 XrayR"
    echo "XrayR stop         - 停止 XrayR"
    echo "XrayR restart      - 重启 XrayR"
    echo "XrayR status       - 查看 XrayR 状态"
    echo "XrayR enable       - 设置 XrayR 开机自启"
    echo "XrayR disable      - 取消 XrayR 开机自启"
    echo "XrayR log          - 查看 XrayR 日志"
    echo "XrayR update       - 更新 XrayR"
    echo "XrayR update x.x.x - 更新 XrayR 指定版本"
    echo "XrayR install      - 安装 XrayR"
    echo "XrayR uninstall    - 卸载 XrayR"
    echo "XrayR version      - 查看 XrayR 版本"
    echo "------------------------------------------"
}

show_menu() {
    echo -e "
  ${green}XrayR 后端管理脚本，${plain}${red}不适用于docker${plain}
--- https://github.com/${FORK_REPO} ---
  ${green}0.${plain} 修改配置
————————————————
  ${green}1.${plain} 安装 XrayR
  ${green}2.${plain} 更新 XrayR
  ${green}3.${plain} 卸载 XrayR
————————————————
  ${green}4.${plain} 启动 XrayR
  ${green}5.${plain} 停止 XrayR
  ${green}6.${plain} 重启 XrayR
  ${green}7.${plain} 查看 XrayR 状态
  ${green}8.${plain} 查看 XrayR 日志
————————————————
  ${green}9.${plain} 设置 XrayR 开机自启
 ${green}10.${plain} 取消 XrayR 开机自启
————————————————
 ${green}11.${plain} 一键安装 bbr (最新内核)
 ${green}12.${plain} 查看 XrayR 版本 
 ${green}13.${plain} 升级维护脚本
 "
 #后续更新可加入上方字符串中
    show_status
    echo && read -p "请输入选择 [0-13]: " num

    case "${num}" in
        0) config
        ;;
        1) check_uninstall && install
        ;;
        2) check_install && update
        ;;
        3) check_install && uninstall
        ;;
        4) check_install && start
        ;;
        5) check_install && stop
        ;;
        6) check_install && restart
        ;;
        7) check_install && status
        ;;
        8) check_install && show_log
        ;;
        9) check_install && enable
        ;;
        10) check_install && disable
        ;;
        11) install_bbr
        ;;
        12) check_install && show_XrayR_version
        ;;
        13) update_shell
        ;;
        *) echo -e "${red}请输入正确的数字 [0-13]${plain}"
        ;;
    esac
}


main() {
check_environment || return 1
if [[ $# > 0 ]]; then
    case $1 in
        "start") check_install 0 && start 0
        ;;
        "stop") check_install 0 && stop 0
        ;;
        "restart") check_install 0 && restart 0
        ;;
        "status") check_install 0 && status 0
        ;;
        "enable") check_install 0 && enable 0
        ;;
        "disable") check_install 0 && disable 0
        ;;
        "log") check_install 0 && show_log 0
        ;;
        "update") check_install 0 && update 0 "${2:-}"
        ;;
        "config") config "$@"
        ;;
        "install") check_uninstall 0 && install 0
        ;;
        "uninstall") check_install 0 && uninstall 0
        ;;
        "version") check_install 0 && show_XrayR_version 0
        ;;
        "update_shell") update_shell
        ;;
        *) show_usage
    esac
else
    show_menu
fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
