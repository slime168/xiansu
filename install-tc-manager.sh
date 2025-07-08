#!/bin/bash
# 健壮的TC端口限速管理工具 v3.0
# 支持入站/出站分别限速、批量操作和开机自启
# 在线安装: bash <(curl -sL https://raw.githubusercontent.com/slime168/xiansu/main/tc-manager.sh)

VERSION="3.0"
CONFIG_DIR="/etc/tc_manager"
CONFIG_FILE="$CONFIG_DIR/rules.conf"
INTERFACE_FILE="$CONFIG_DIR/interface"
SERVICE_FILE="/etc/systemd/system/tc-manager.service"
LOG_FILE="/var/log/tc-manager.log"
INSTALL_LOG="/var/log/tc-manager-install.log"
MIN_SCRIPT_SIZE=10000  # 最小脚本大小（10KB）

# 初始化日志
init_log() {
    mkdir -p $(dirname "$LOG_FILE")
    touch "$LOG_FILE"
    exec 3>&1 4>&2
    exec > >(tee -a "$INSTALL_LOG") 2>&1
}

# 记录日志
log() {
    local message="$1"
    local level="INFO"
    [ -n "$2" ] && level="$2"
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$LOG_FILE"
}

# 检查root权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        log "必须使用root权限运行此脚本" "ERROR"
        exit 1
    fi
}

# 安装依赖
install_dependencies() {
    log "检查依赖项"
    local missing=()
    
    if ! command -v tc &> /dev/null; then
        missing+=("iproute2")
    fi
    
    if ! command -v iptables &> /dev/null; then
        missing+=("iptables")
    fi
    
    if ! command -v ip &> /dev/null; then
        missing+=("iproute2")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        log "安装依赖: ${missing[*]}"
        if command -v apt-get &> /dev/null; then
            apt-get update >/dev/null 2>&1
            apt-get install -y "${missing[@]}" >/dev/null 2>&1
        elif command -v yum &> /dev/null; then
            yum install -y "${missing[@]}" >/dev/null 2>&1
        else
            log "无法自动安装依赖，请手动安装: ${missing[*]}" "ERROR"
            exit 1
        fi
    fi
    log "依赖检查完成"
}

# 初始化配置目录
init_config() {
    log "初始化配置目录"
    mkdir -p "$CONFIG_DIR"
    touch "$CONFIG_FILE"
    
    if [ ! -f "$INTERFACE_FILE" ]; then
        # 自动检测主要网络接口
        DEFAULT_INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}')
        if [ -z "$DEFAULT_INTERFACE" ]; then
            log "无法自动检测网络接口，请手动设置" "WARNING"
            DEFAULT_INTERFACE="eth0"
        fi
        echo "$DEFAULT_INTERFACE" > "$INTERFACE_FILE"
        log "设置默认网络接口为: $DEFAULT_INTERFACE"
    fi
}

# 获取当前接口
get_interface() {
    if [ -f "$INTERFACE_FILE" ]; then
        cat "$INTERFACE_FILE"
    else
        ip route show default 2>/dev/null | awk '/default/ {print $5}'
    fi
}

# 设置接口
set_interface() {
    local new_iface=$1
    if ip link show "$new_iface" >/dev/null 2>&1; then
        echo "$new_iface" > "$INTERFACE_FILE"
        log "已设置网络接口为: $new_iface"
        return 0
    else
        log "网络接口 $new_iface 不存在" "ERROR"
        return 1
    fi
}

# 验证安装
validate_installation() {
    log "验证安装"
    local errors=0
    
    # 检查主文件是否存在
    if [ ! -f "/usr/local/bin/tc-manager" ]; then
        log "主文件未安装" "ERROR"
        errors=$((errors+1))
    fi
    
    # 检查文件大小
    local file_size=$(stat -c%s "/usr/local/bin/tc-manager" 2>/dev/null)
    if [ -z "$file_size" ] || [ "$file_size" -lt $MIN_SCRIPT_SIZE ]; then
        log "主文件不完整（大小: ${file_size:-0}字节）" "ERROR"
        errors=$((errors+1))
    fi
    
    # 检查配置目录
    if [ ! -d "$CONFIG_DIR" ]; then
        log "配置目录不存在" "ERROR"
        errors=$((errors+1))
    fi
    
    # 检查服务文件
    if [ ! -f "$SERVICE_FILE" ]; then
        log "服务文件不存在" "ERROR"
        errors=$((errors+1))
    fi
    
    if [ $errors -gt 0 ]; then
        log "安装验证失败 ($errors 个错误)" "ERROR"
        return 1
    fi
    
    log "安装验证成功"
    return 0
}

# 安装服务
install_service() {
    log "安装系统服务"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=TC Bandwidth Manager
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/tc-manager start
ExecReload=/bin/bash /usr/local/bin/tc-manager reload
ExecStop=/bin/bash /usr/local/bin/tc-manager stop
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable tc-manager >/dev/null 2>&1
    log "系统服务安装完成"
}

# 卸载服务
uninstall_service() {
    log "卸载系统服务"
    systemctl stop tc-manager >/dev/null 2>&1
    systemctl disable tc-manager >/dev/null 2>&1
    rm -f "$SERVICE_FILE" >/dev/null 2>&1
    systemctl daemon-reload >/dev/null 2>&1
    log "系统服务已卸载"
}

# 清除所有规则
clean_all_rules() {
    local iface=$(get_interface)
    log "清除所有网络规则"
    
    # 清除出站规则
    tc qdisc del dev "$iface" root >/dev/null 2>&1
    
    # 清除入站规则
    tc qdisc del dev "$iface" ingress >/dev/null 2>&1
    tc qdisc del dev ifb0 root >/dev/null 2>&1
    
    # 清除iptables标记
    iptables -t mangle -F >/dev/null 2>&1
    
    # 移除IFB设备
    ip link del ifb0 >/dev/null 2>&1
    
    log "所有网络规则已清除"
}

# 安装脚本
install_script() {
    check_root
    init_log
    log "开始安装 TC 限速管理工具 v$VERSION"
    
    # 下载完整脚本
    local temp_script=$(mktemp)
    log "下载安装脚本"
    
    curl -sL https://raw.githubusercontent.com/slime168/xiansu/main/tc.sh -o "$temp_script" || {
        log "下载脚本失败" "ERROR"
        exit 1
    }
    
    # 检查下载的脚本大小
    local script_size=$(stat -c%s "$temp_script")
    if [ "$script_size" -lt $MIN_SCRIPT_SIZE ]; then
        log "下载的脚本不完整（大小: $script_size 字节）" "ERROR"
        exit 1
    fi
    
    # 复制到系统目录
    cp -f "$temp_script" /usr/local/bin/tc-manager
    chmod +x /usr/local/bin/tc-manager
    rm -f "$temp_script"
    
    # 初始化配置
    install_dependencies
    init_config
    
    # 安装服务
    install_service
    
    # 验证安装
    if validate_installation; then
        log "安装成功完成"
        echo -e "\n\033[1;32m✓ TC限速管理工具 v$VERSION 已成功安装\033[0m"
        echo -e "使用命令: \033[1;33mtc-manager\033[0m 启动管理界面"
    else
        log "安装验证失败" "ERROR"
        echo -e "\n\033[1;31m✗ 安装过程中出现问题，请检查日志: $INSTALL_LOG\033[0m"
        exit 1
    fi
}

# 卸载脚本
uninstall_script() {
    check_root
    log "开始卸载"
    
    # 停止服务并清除规则
    clean_all_rules
    uninstall_service
    
    # 删除文件
    rm -f /usr/local/bin/tc-manager
    rm -rf "$CONFIG_DIR"
    
    log "卸载完成"
    echo -e "\n\033[1;32m✓ TC限速管理工具已卸载\033[0m"
}

# 主安装函数
main_install() {
    if [ -f "/usr/local/bin/tc-manager" ]; then
        read -p "检测到已安装版本，是否重新安装? [y/N] " reinstall
        if [[ "$reinstall" =~ ^[Yy]$ ]]; then
            uninstall_script
        else
            echo "安装已取消"
            exit 0
        fi
    fi
    
    install_script
}

# 显示帮助
show_help() {
    cat <<EOF

TC限速管理工具 v$VERSION

安装命令:
  bash <(curl -sL https://raw.githubusercontent.com/slime168/xiansu/main/tc-manager.sh)

管理命令:
  tc-manager [命令]

可用命令:
  install     安装工具
  uninstall   卸载工具
  start       启动限速规则
  stop        停止限速规则
  status      查看状态
  help        显示帮助

安装后使用交互菜单:
  tc-manager

卸载命令:
  tc-manager uninstall

更多信息请访问:
  https://github.com/slime168/xiansu
EOF
}

# 命令行参数处理
case "$1" in
    install)
        main_install
        ;;
    uninstall)
        uninstall_script
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        if [ -f "/usr/local/bin/tc-manager" ]; then
            /usr/local/bin/tc-manager "$@"
        else
            show_help
        fi
        ;;
esac

exit 0