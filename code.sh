#!/bin/bash
# FRP内网穿透配置脚本 - 仅普通用户模式
# 文件将安装在用户主目录下，服务需手动启动。

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
reading() { read -p "$(red "$1")" "$2"; }

# --- Global Variables for User Mode ---
FRP_VERSION_DEFAULT='0.62.1'
# ~ 会被bash自动扩展为当前用户的主目录
FRP_BASE_DIR_DEFAULT="${HOME}/.local/share/frp_user_script" 
SSH_PORT_DEFAULT='22'

FRP_VERSION=""
SSH_PORT=""
FRP_INSTALL_DIR="" # Actual base directory for frp binaries (frps, frpc)
FRP_CONFIG_DIR=""  # Directory for .toml files and info.txt
FRP_LOG_DIR=""     # Directory for log files (referenced in .toml)
INFO_FILE=""

LOCAL_SSH_USER="" # For client SSH guidance
REMINDER_SSH_PWD="" # For client SSH guidance

# --- End Global Variables ---

initialize_env() {
    FRP_VERSION="${FRP_VERSION_OVERRIDE:-$FRP_VERSION_DEFAULT}"
    SSH_PORT="${SSH_PORT_OVERRIDE:-$SSH_PORT_DEFAULT}"

    FRP_INSTALL_DIR="${FRP_BASE_DIR_OVERRIDE:-$FRP_BASE_DIR_DEFAULT}"
    FRP_CONFIG_DIR="$FRP_INSTALL_DIR" # Configs alongside binaries
    FRP_LOG_DIR="$FRP_INSTALL_DIR"    # Logs also in user space
    INFO_FILE="${FRP_CONFIG_DIR}/info.txt"

    purple "FRP 版本: ${FRP_VERSION}"
    purple "安装/配置/日志 目录: ${FRP_INSTALL_DIR}"
    sleep 1
}

get_server_ip() {
    local ipv4=$(curl -s --max-time 2 ipv4.ip.sb)
    if [ -n "$ipv4" ]; then
        echo "$ipv4"
    else
        ipv6=$(curl -s --max-time 2 ipv6.ip.sb)
        echo "[$ipv6]" # Square brackets for IPv6 address
    fi
}

get_arch() {
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64|amd64) echo "amd64";;
        arm64|aarch64) echo "arm64";;
        *) red "不支持的架构: ${ARCH}"; exit 1;;
    esac
}

init_frp_dirs() {
    mkdir -p "${FRP_INSTALL_DIR}" || { red "创建FRP目录 '${FRP_INSTALL_DIR}' 失败"; exit 1; }
    # Config and Log dirs are the same as Install dir in this simplified version
}

download_frp() {
    local ARCH=$1
    local FRP_PACKAGE_BASENAME="frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
    local DOWNLOAD_TARGET="${FRP_INSTALL_DIR}/${FRP_PACKAGE_BASENAME}"

    if [ ! -f "${FRP_INSTALL_DIR}/frps" ] || [ ! -f "${FRP_INSTALL_DIR}/frpc" ]; then
        yellow "FRP二进制文件未在 ${FRP_INSTALL_DIR} 中找到。正在下载 frp v${FRP_VERSION}..."
        
        if [ ! -d "$(dirname "$DOWNLOAD_TARGET")" ]; then # Should be created by init_frp_dirs
            mkdir -p "$(dirname "$DOWNLOAD_TARGET")"
        fi

        wget -q --show-progress "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_PACKAGE_BASENAME}" -O "${DOWNLOAD_TARGET}"
        if [ $? -ne 0 ]; then
            red "下载frp失败"; rm -f "${DOWNLOAD_TARGET}"; exit 1
        fi
        
        EXTRACTED_SUBDIR_NAME="frp_${FRP_VERSION}_linux_${ARCH}"
        tar -zxvf "${DOWNLOAD_TARGET}" -C "${FRP_INSTALL_DIR}" >/dev/null
        if [ $? -ne 0 ]; then red "解压frp失败"; rm -f "${DOWNLOAD_TARGET}"; exit 1; fi
        
        mv "${FRP_INSTALL_DIR}/${EXTRACTED_SUBDIR_NAME}/frps" "${FRP_INSTALL_DIR}/frps"
        mv "${FRP_INSTALL_DIR}/${EXTRACTED_SUBDIR_NAME}/frpc" "${FRP_INSTALL_DIR}/frpc"
        # Optionally move example configs
        [ -f "${FRP_INSTALL_DIR}/${EXTRACTED_SUBDIR_NAME}/frps.toml" ] && mv "${FRP_INSTALL_DIR}/${EXTRACTED_SUBDIR_NAME}/frps.toml" "${FRP_INSTALL_DIR}/frps.toml.example"
        [ -f "${FRP_INSTALL_DIR}/${EXTRACTED_SUBDIR_NAME}/frpc.toml" ] && mv "${FRP_INSTALL_DIR}/${EXTRACTED_SUBDIR_NAME}/frpc.toml" "${FRP_INSTALL_DIR}/frpc.toml.example"

        rm -rf "${FRP_INSTALL_DIR}/${EXTRACTED_SUBDIR_NAME}"
        rm -f "${DOWNLOAD_TARGET}"
        chmod +x "${FRP_INSTALL_DIR}/frps" "${FRP_INSTALL_DIR}/frpc"
        if [ $? -ne 0 ]; then red "设置frp文件权限或移动文件失败"; exit 1; fi
    else
        green "FRP二进制文件已存在于 ${FRP_INSTALL_DIR}."
    fi
}

provide_ssh_access_guidance() {
    yellow "\n--- SSH访问配置提示 (普通用户模式) ---"
    yellow "您正在普通用户模式下安装FRP客户端。"
    yellow "此脚本不会修改任何系统SSH配置 (如 /etc/ssh/sshd_config) 或系统密码。"
    yellow "请确保您的本地SSH服务已配置为允许您希望通过FRP访问的用户登录。"
    reading "请输入您用于本地SSH登录的用户名 [默认: 当前用户 $(whoami)]: " LOCAL_SSH_USER_INPUT
    LOCAL_SSH_USER=${LOCAL_SSH_USER_INPUT:-$(whoami)}
    reading "请输入您用于本地SSH登录的密码 (此密码不会被系统设置，仅用于配置提示): " REMINDER_SSH_PWD_INPUT
    REMINDER_SSH_PWD="$REMINDER_SSH_PWD_INPUT" 
    yellow "您需要确保用户 '${LOCAL_SSH_USER}' 可以通过密码 '${REMINDER_SSH_PWD}' (或SSH密钥) 登录到本地SSH服务 (端口 ${SSH_PORT})。"
    yellow "FRP客户端会将流量转发到本地的 127.0.0.1:${SSH_PORT}。"
    yellow "-------------------------------------\n"
}

save_config_info() {
    local mode=$1
    shift
    
    mkdir -p "$(dirname "$INFO_FILE")" # Ensure directory exists
    
    echo "=== FRP ${mode} 配置信息 (普通用户模式) ===" > "$INFO_FILE"
    echo "生成时间: $(date "+%Y-%m-%d %H:%M:%S")" >> "$INFO_FILE"
    for item in "$@"; do
        IFS='|' read -r name value <<< "$item"
        echo "${name}: ${value}" >> "$INFO_FILE"
    done
    echo "=========================" >> "$INFO_FILE"
    chmod 600 "$INFO_FILE" # User's private info
}

show_config_confirmation() {
    local mode=$1
    shift
    
    yellow "\n============= ${mode}配置确认 (普通用户模式) ============="
    for item in "$@"; do
        IFS='|' read -r name value <<< "$item"
        purple "${name}: ${value}"
    done
    purple "====================================================="
    
    reading "确认以上配置是否正确？(y/n) [默认: y]: " CONFIRM
    CONFIRM=${CONFIRM:-"y"}
    [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]] && { yellow "配置已取消"; exit 1; }
}

show_saved_info() {
    clear
    if [ ! -f "$INFO_FILE" ]; then
        red "未找到配置信息文件 (${INFO_FILE})，请先安装FRP服务。\n"
    else
        echo ""
        cat "$INFO_FILE"
        
        local service_type_in_file service_name status_display
        if grep -q "服务端" "$INFO_FILE"; then
            service_type_in_file="服务端"
            service_name="frps"
        elif grep -q "客户端" "$INFO_FILE"; then
            service_type_in_file="客户端"
            service_name="frpc"
        else
            service_name=""
        fi

        if [ -n "$service_name" ]; then
            # pgrep: -u current_user_name, -f full_command_line
            if pgrep -u "$(id -u -n)" -f "${FRP_INSTALL_DIR}/${service_name} -c ${FRP_CONFIG_DIR}/${service_name}.toml" > /dev/null; then
                status_display="\e[1;32m推测正在运行 (手动进程)\033[0m"
            else
                status_display="\e[1;31m推测未运行 (手动进程)\033[0m"
            fi
            echo -e "\e[1;35m${service_type_in_file}运行状态: ${status_display}\033[0m\n\n"
            yellow "普通用户模式下，请使用以下命令手动启动/检查:"
            purple "启动: ${FRP_INSTALL_DIR}/${service_name} -c ${FRP_CONFIG_DIR}/${service_name}.toml"
            purple "检查: ps aux | grep '${service_name}.*${service_name}.toml'"
            yellow "可使用 'nohup ... &' 或 'screen'/'tmux' 在后台运行。\n"
        fi
    fi
    
    read -rsn1 -p "$(red "按任意键返回主菜单...")"
    echo
    main_menu
}

server_side_config_inputs() {
    reading "请输入FRP服务端监听端口 (>=1024) [默认: 7000]: " BIND_PORT
    BIND_PORT=${BIND_PORT:-"7000"}
    if [ "$BIND_PORT" -lt 1024 ]; then
        yellow "警告: 普通用户模式下，绑定到端口 ${BIND_PORT} (<1024) 通常会失败。建议使用 >=1024 的端口。"
        reading "请重新输入FRP服务端监听端口 (>=1024) [默认: 7000]: " BIND_PORT
        BIND_PORT=${BIND_PORT:-"7000"}
    fi
    green "服务端监听端口为：$BIND_PORT"
    
    reading "请输入认证TOKEN [回车将自动随机生成]: " TOKEN
    [ -z "$TOKEN" ] && TOKEN=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
    green "验证token为：$TOKEN"
    
    reading "请输入web界面端口 (>=1024) [默认: 7500]: " DASHBOARD_PORT
    DASHBOARD_PORT=${DASHBOARD_PORT:-"7500"}
    if [ "$DASHBOARD_PORT" -lt 1024 ]; then
        yellow "警告: 普通用户模式下，Web服务绑定到端口 ${DASHBOARD_PORT} (<1024) 通常会失败。"
        reading "请重新输入web界面端口 (>=1024) [默认: 7500]: " DASHBOARD_PORT
        DASHBOARD_PORT=${DASHBOARD_PORT:-"7500"}
    fi
    green "web界面端口为：$DASHBOARD_PORT"
    
    reading "请输入web界面用户名 [默认: admin]: " DASHBOARD_USER
    DASHBOARD_USER=${DASHBOARD_USER:-"admin"}
    green "web界面登录用户名为：$DASHBOARD_USER"
    
    reading "请输入web界面登录密码 [默认: 回车将随机生成]: " DASHBOARD_PWD
    [ -z "$DASHBOARD_PWD" ] && DASHBOARD_PWD=$(openssl rand -hex 8)
    green "web界面登录密码为：$DASHBOARD_PWD"
}

install_frp_server() {
    yellow "\n开始安装FRP服务端 v${FRP_VERSION} (普通用户模式)..."
    
    ARCH=$(get_arch)
    init_frp_dirs
    download_frp "$ARCH"
    
    FRPS_TOML_PATH="${FRP_CONFIG_DIR}/frps.toml"
    FRPS_LOG_PATH="${FRP_LOG_DIR}/frps.log" # Will be in the same user directory

    mkdir -p "$(dirname "$FRPS_TOML_PATH")" # Ensure directory exists

    cat > "${FRPS_TOML_PATH}" <<EOF
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}
quicBindPort = ${BIND_PORT}

auth.method = "token"
auth.token = "${TOKEN}"

webServer.addr = "0.0.0.0"
webServer.port = ${DASHBOARD_PORT}
webServer.user = "${DASHBOARD_USER}"
webServer.password = "${DASHBOARD_PWD}"

log.to = "${FRPS_LOG_PATH}"
log.level = "info"
log.maxDays = 3

# In user mode, Prometheus might be harder to set up if it expects system paths/ports
# enablePrometheus = true 
EOF
    chmod 600 "${FRPS_TOML_PATH}"

    green "FRP服务端配置文件已生成: ${FRPS_TOML_PATH}"
    yellow "请手动运行以下命令启动FRP服务端:"
    purple "${FRP_INSTALL_DIR}/frps -c ${FRPS_TOML_PATH}"
    yellow "您可以使用 'nohup ... &' 或 'screen'/'tmux' 等工具使其在后台运行。"

    local SERVER_IP=$(get_server_ip) # This gets the public IP, user needs to ensure server is reachable
    green "\nFRP服务端安装配置完成!\n"
    save_config_info "服务端" \
        "FRP版本号|${FRP_VERSION}" \
        "安装目录|${FRP_INSTALL_DIR}" \
        "配置文件|${FRPS_TOML_PATH}" \
        "日志文件|${FRPS_LOG_PATH}" \
        "本机公网IP (仅供参考)|${SERVER_IP}" \
        "监听端口|${BIND_PORT}" \
        "认证TOKEN|${TOKEN}" \
        "web端口|${DASHBOARD_PORT}" \
        "web登录用户名|${DASHBOARD_USER}" \
        "web登录密码|${DASHBOARD_PWD}"
    yellow "====== 客户端与服务端通信信息 ======"
    green "服务端公网IP (需确保可达): ${SERVER_IP}"
    green "服务端监听端口: ${BIND_PORT}"
    green "认证TOKEN: ${TOKEN}\n"
    purple "====== web管理信息 ======"
    green "Web地址 (需确保可达): http://${SERVER_IP}:${DASHBOARD_PORT} 或 http://<服务器内网IP>:${DASHBOARD_PORT}"
    green "用户名: ${DASHBOARD_USER}"
    green "登录密码: ${DASHBOARD_PWD}\n"
}

client_side_config_inputs() {
    reading "请输入中继服务器公网IP: " SERVER_IP_FOR_CLIENT
    while [ -z "$SERVER_IP_FOR_CLIENT" ]; do
        reading "中继服务器IP不能为空，请重新输入: " SERVER_IP_FOR_CLIENT
    done
    green "FRP中继服务器IP为：$SERVER_IP_FOR_CLIENT"
    
    reading "请输入中继服务器FRP端口 [默认: 7000]: " SERVER_PORT_FOR_CLIENT
    SERVER_PORT_FOR_CLIENT=${SERVER_PORT_FOR_CLIENT:-"7000"}
    green "FRP中继服务器通信端口为：$SERVER_PORT_FOR_CLIENT"
    
    reading "请输入认证TOKEN (与服务端一致): " TOKEN_FOR_CLIENT
    while [ -z "$TOKEN_FOR_CLIENT" ]; do
        reading "TOKEN不能为空，请重新输入: " TOKEN_FOR_CLIENT
    done
    green "认证token为：$TOKEN_FOR_CLIENT"
    
    reading "请输入要映射的远程SSH端口 (在服务端上打开的端口) [默认: 6000]: " REMOTE_SSH_PORT_ON_SERVER
    REMOTE_SSH_PORT_ON_SERVER=${REMOTE_SSH_PORT_ON_SERVER:-"6000"}
    green "ssh远程映射端口为：$REMOTE_SSH_PORT_ON_SERVER"
}

install_frp_client() {
    yellow "\n开始安装FRP客户端 v${FRP_VERSION} (普通用户模式)..."
    
    ARCH=$(get_arch)
    init_frp_dirs
    download_frp "$ARCH"
    
    FRPC_TOML_PATH="${FRP_CONFIG_DIR}/frpc.toml"
    FRPC_LOG_PATH="${FRP_LOG_DIR}/frpc.log"

    # LOCAL_SSH_USER and REMINDER_SSH_PWD are set by provide_ssh_access_guidance
    # SSH_PORT is the local SSH server port on this client machine

    mkdir -p "$(dirname "$FRPC_TOML_PATH")"

    cat > "${FRPC_TOML_PATH}" <<EOF
serverAddr = "${SERVER_IP_FOR_CLIENT}"
serverPort = ${SERVER_PORT_FOR_CLIENT}

auth.method = "token"
auth.token = "${TOKEN_FOR_CLIENT}"

log.to = "${FRPC_LOG_PATH}"
log.level = "error"
log.maxDays = 3

transport.poolCount = 5
# Add other transport settings if needed, or keep it minimal

[[proxies]]
name = "ssh_$(hostname)_${USER}" # Add user to name for uniqueness if multiple users run frpc
type = "tcp"
localIP = "127.0.0.1"
localPort = ${SSH_PORT} 
remotePort = ${REMOTE_SSH_PORT_ON_SERVER}
EOF
    chmod 600 "${FRPC_TOML_PATH}"

    green "FRP客户端配置文件已生成: ${FRPC_TOML_PATH}"
    yellow "请手动运行以下命令启动FRP客户端:"
    purple "${FRP_INSTALL_DIR}/frpc -c ${FRPC_TOML_PATH}"
    yellow "您可以使用 'nohup ... &' 或 'screen'/'tmux' 等工具使其在后台运行。"
    
    save_config_info "客户端" \
        "FRP版本号|${FRP_VERSION}" \
        "安装目录|${FRP_INSTALL_DIR}" \
        "配置文件|${FRPC_TOML_PATH}" \
        "日志文件|${FRPC_LOG_PATH}" \
        "中继服务器IP|${SERVER_IP_FOR_CLIENT}" \
        "中继服务器端口|${SERVER_PORT_FOR_CLIENT}" \
        "认证TOKEN|${TOKEN_FOR_CLIENT}" \
        "本地SSH端口 (此机器)|${SSH_PORT}" \
        "远程映射端口 (FRP服务端)|${REMOTE_SSH_PORT_ON_SERVER}" \
        "本地SSH用户 (用于连接此客户端)|${LOCAL_SSH_USER}" \
        "本地SSH密码 (仅为提示)|${REMINDER_SSH_PWD}"

    green "FRP客户端安装配置完成!\n"
    purple "====== SSH连接信息 (通过FRP连接此客户端) ======"
    green "中继服务器IP: ${SERVER_IP_FOR_CLIENT}"
    green "SSH端口 (在FRP服务端上): ${REMOTE_SSH_PORT_ON_SERVER}"
    green "SSH用户: ${LOCAL_SSH_USER}"
    green "SSH密码: ${REMINDER_SSH_PWD} (这是您为本地SSH服务配置的密码/凭证)"
    yellow "\n温馨提示: 确保服务端已开放端口 ${SERVER_PORT_FOR_CLIENT} (FRP通讯) 和 ${REMOTE_SSH_PORT_ON_SERVER} (SSH映射)\n"
}

uninstall_frp_user_mode() {
    yellow "\n开始卸载FRP (普通用户模式)..."
    
    if [ -d "${FRP_INSTALL_DIR}" ]; then
        read -p "$(red "确认删除FRP用户模式目录 ${FRP_INSTALL_DIR} 及其所有内容? (y/n): ")" CONFIRM_DEL_USER
        if [[ "${CONFIRM_DEL_USER,,}" == "y" ]]; then
             rm -rf "${FRP_INSTALL_DIR}" # Contains binaries, configs, logs
             green "已删除FRP目录: ${FRP_INSTALL_DIR}"
        else
            yellow "取消删除目录。"
        fi
    else
        yellow "FRP目录 ${FRP_INSTALL_DIR} 未找到。"
    fi
    yellow "请手动停止任何正在运行的 frps 或 frpc 进程。"
    yellow "您可以使用 'pkill -u $(whoami) frps' 或 'pkill -u $(whoami) frpc' (请谨慎使用pkill)。"
    yellow "或者使用 'ps aux | grep frp' 找到进程ID (PID) 后使用 'kill <PID>'。"
    
    green "\nFRP卸载操作完成。"
}

main_menu() {
    clear
    purple "\n======== FRP 管理脚本 (v${FRP_VERSION} - 普通用户模式) ========\n"
    green "1. 安装 FRP 服务端 (frps)\n"
    green "2. 安装 FRP 客户端 (frpc)\n"
    purple "3. 显示当前配置信息\n"
    red "4. 卸载 FRP\n"
    yellow "0. 退出脚本\n"
    yellow "==========================================================="
    
    reading "请选择操作 [0-4]: " CHOICE
    case $CHOICE in
        1) # Install Server
            server_side_config_inputs
            local server_config_items=(
                "FRP版本号|${FRP_VERSION}"
                "安装目录|${FRP_INSTALL_DIR}"
                "配置文件|${FRP_CONFIG_DIR}/frps.toml"
                "日志文件|${FRP_LOG_DIR}/frps.log"
                "监听端口|${BIND_PORT}"
                "认证TOKEN|${TOKEN}"
                "web端口|${DASHBOARD_PORT}"
                "web登录用户名|${DASHBOARD_USER}"
                "web登录密码|${DASHBOARD_PWD}"
            )
            show_config_confirmation "服务端" "${server_config_items[@]}"
            install_frp_server
            ;;
        2) # Install Client
            provide_ssh_access_guidance # Get LOCAL_SSH_USER and REMINDER_SSH_PWD
            client_side_config_inputs   # Get server details and TOKEN_FOR_CLIENT etc.
            local client_config_items=(
                "FRP版本号|${FRP_VERSION}"
                "安装目录|${FRP_INSTALL_DIR}"
                "配置文件|${FRP_CONFIG_DIR}/frpc.toml"
                "日志文件|${FRP_LOG_DIR}/frpc.log"
                "中继服务器IP|${SERVER_IP_FOR_CLIENT}"
                "中继服务器端口|${SERVER_PORT_FOR_CLIENT}"
                "认证TOKEN|${TOKEN_FOR_CLIENT}"
                "本地SSH端口 (此机器)|${SSH_PORT}"
                "远程映射端口 (FRP服务端)|${REMOTE_SSH_PORT_ON_SERVER}"
                "本地SSH用户 (用于连接此客户端)|${LOCAL_SSH_USER}"
                "本地SSH密码 (仅为提示)|${REMINDER_SSH_PWD}"
            )
            show_config_confirmation "客户端" "${client_config_items[@]}"
            install_frp_client
            ;;
        3)
            show_saved_info
            ;;
        4)
            uninstall_frp_user_mode
            ;;
        0)
            clear
            exit 0
            ;;
        *)
            red "无效选择，请重新输入"
            sleep 1
            ;; # main_menu will be called again after this case
    esac
    
    if [[ "$CHOICE" -ge 1 && "$CHOICE" -le 4 ]]; then
        read -rsn1 -p "$(red "按任意键返回主菜单...")"
        echo
    fi
    main_menu
}

# --- Script Entry Point ---
clear
if [ "$(id -u)" = "0" ]; then
    yellow "警告: 此脚本设计为普通用户执行。以root身份运行可能导致文件权限问题或意外行为。"
    yellow "建议切换到普通用户账户再运行此脚本。"
    reading "确实要以root身份继续吗? (y/n) [默认: n]: " CONTINUE_AS_ROOT
    CONTINUE_AS_ROOT=${CONTINUE_AS_ROOT:-"n"}
    if [[ "${CONTINUE_AS_ROOT,,}" != "y" ]]; then
        red "已取消。请以普通用户身份运行。"
        exit 1
    fi
    # If user insists on root, HOME might point to /root.
    # FRP_BASE_DIR_DEFAULT will use this $HOME.
fi

initialize_env
main_menu