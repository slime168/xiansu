#!/bin/bash
# 终极TC端口限速管理工具 v4.0
# 支持整数速率输入、双向限速、服务管理
# 在线安装: bash <(curl -sL https://raw.githubusercontent.com/slime168/xiansu/main/tc-manager.sh)

VERSION="4.0"
CONFIG_DIR="/etc/tc_manager"
CONFIG_FILE="$CONFIG_DIR/rules.conf"
INTERFACE_FILE="$CONFIG_DIR/interface"
SERVICE_FILE="/etc/systemd/system/tc-manager.service"
LOG_FILE="/var/log/tc-manager.log"

# 初始化配置
init_config() {
    mkdir -p "$CONFIG_DIR"
    touch "$CONFIG_FILE"
    
    # 设置默认网络接口
    if [ ! -f "$INTERFACE_FILE" ]; then
        DEFAULT_INTERFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}')
        [ -z "$DEFAULT_INTERFACE" ] && DEFAULT_INTERFACE="eth0"
        echo "$DEFAULT_INTERFACE" > "$INTERFACE_FILE"
    fi
}

# 获取当前接口
get_interface() {
    cat "$INTERFACE_FILE" 2>/dev/null || echo "eth0"
}

# 设置接口
set_interface() {
    local iface=$1
    if ip link show "$iface" >/dev/null 2>&1; then
        echo "$iface" > "$INTERFACE_FILE"
        echo "已设置网络接口为: $iface"
        return 0
    else
        echo "错误: 网络接口 $iface 不存在"
        return 1
    fi
}

# 日志记录
log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

# 添加限速规则
add_limit() {
    local direction=$1
    local port=$2
    local rate=$3
    local ceil=${4:-$rate}
    
    # 自动添加单位 (mbit)
    [[ "$rate" =~ ^[0-9]+$ ]] && rate="${rate}mbit"
    [[ "$ceil" =~ ^[0-9]+$ ]] && ceil="${ceil}mbit"
    
    local iface=$(get_interface)
    
    # 检查端口是否已存在
    if grep -q "^$direction $port " "$CONFIG_FILE"; then
        echo "错误: $direction 方向端口 $port 已有规则"
        return 1
    fi
    
    # 生成唯一标记
    local mark=$(( (RANDOM % 10000) + 10000 ))
    
    # 保存配置
    echo "$direction $port $rate $ceil $mark" >> "$CONFIG_FILE"
    echo "已添加 $direction 方向端口 $port 限速: 保证 $rate 最大 $ceil"
    
    # 如果服务已启动，立即应用规则
    if systemctl is-active tc-manager >/dev/null; then
        apply_single_rule "$direction" "$port" "$rate" "$ceil" "$mark"
    fi
}

# 应用单条规则
apply_single_rule() {
    local direction=$1
    local port=$2
    local rate=$3
    local ceil=$4
    local mark=$5
    local iface=$(get_interface)
    
    if [ "$direction" == "出站" ]; then
        # 出站限速
        if ! tc qdisc show dev $iface | grep -q "htb"; then
            tc qdisc add dev $iface root handle 1: htb
            tc class add dev $iface parent 1: classid 1:1 htb rate 1000mbit
        fi
        
        # 创建限速类
        tc class add dev $iface parent 1:1 classid 1:$mark htb rate "$rate" ceil "$ceil"
        tc qdisc add dev $iface parent 1:$mark handle ${mark}0: sfq perturb 10
        
        # 标记流量
        iptables -t mangle -A POSTROUTING -o $iface -p tcp --dport $port -j MARK --set-mark $mark
        tc filter add dev $iface parent 1:0 protocol ip handle $mark fw flowid 1:$mark
    
    elif [ "$direction" == "入站" ]; then
        # 入站限速
        if ! ip link show ifb0 >/dev/null 2>&1; then
            modprobe ifb
            ip link set dev ifb0 up
            tc qdisc add dev $iface handle ffff: ingress
            tc filter add dev $iface parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0
            tc qdisc add dev ifb0 root handle 1: htb
            tc class add dev ifb0 parent 1: classid 1:1 htb rate 1000mbit
        fi
        
        # 创建限速类
        tc class add dev ifb0 parent 1:1 classid 1:$mark htb rate "$rate" ceil "$ceil"
        tc qdisc add dev ifb0 parent 1:$mark handle ${mark}0: sfq perturb 10
        
        # 标记流量
        iptables -t mangle -A PREROUTING -i $iface -p tcp --dport $port -j MARK --set-mark $mark
        tc filter add dev ifb0 parent 1:0 protocol ip handle $mark fw flowid 1:$mark
    fi
}

# 删除规则
del_limit() {
    local direction=$1
    local port=$2
    local iface=$(get_interface)
    
    # 从配置文件中查找
    local rule_line=$(grep "^$direction $port " "$CONFIG_FILE")
    if [ -z "$rule_line" ]; then
        echo "错误: 未找到 $direction 方向端口 $port 的规则"
        return 1
    fi
    
    local mark=$(echo "$rule_line" | awk '{print $5}')
    
    # 删除规则
    if [ "$direction" == "出站" ]; then
        tc class del dev $iface classid 1:$mark 2>/dev/null
        iptables -t mangle -D POSTROUTING -o $iface -p tcp --dport $port -j MARK --set-mark $mark 2>/dev/null
    else
        tc class del dev ifb0 classid 1:$mark 2>/dev/null
        iptables -t mangle -D PREROUTING -i $iface -p tcp --dport $port -j MARK --set-mark $mark 2>/dev/null
    fi
    
    # 更新配置文件
    sed -i "/^$direction $port /d" "$CONFIG_FILE"
    echo "已删除 $direction 方向端口 $port 的规则"
}

# 应用所有规则
apply_rules() {
    local iface=$(get_interface)
    
    # 清除所有规则
    tc qdisc del dev $iface root 2>/dev/null
    tc qdisc del dev $iface ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    iptables -t mangle -F
    
    # 初始化入站设备
    modprobe ifb 2>/dev/null
    ip link set dev ifb0 up 2>/dev/null
    
    # 应用配置文件规则
    while IFS= read -r line; do
        if [[ "$line" =~ ^(出站|入站) ]]; then
            direction=$(echo "$line" | awk '{print $1}')
            port=$(echo "$line" | awk '{print $2}')
            rate=$(echo "$line" | awk '{print $3}')
            ceil=$(echo "$line" | awk '{print $4}')
            mark=$(echo "$line" | awk '{print $5}')
            
            apply_single_rule "$direction" "$port" "$rate" "$ceil" "$mark"
        fi
    done < "$CONFIG_FILE"
    
    echo "所有规则已应用"
    log "限速规则已启动"
}

# 清除所有规则
clean_rules() {
    local iface=$(get_interface)
    
    tc qdisc del dev $iface root 2>/dev/null
    tc qdisc del dev $iface ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    iptables -t mangle -F
    
    echo "所有网络规则已清除"
    log "限速规则已停止"
}

# 服务管理
service_control() {
    case "$1" in
        start)
            apply_rules
            ;;
        stop)
            clean_rules
            ;;
        restart)
            clean_rules
            apply_rules
            ;;
    esac
}

# 显示菜单
show_menu() {
    clear
    echo -e "\n==================================="
    echo -e "    TC端口限速管理工具 v$VERSION    "
    echo -e "==================================="
    echo -e "网络接口: $(get_interface)"
    echo -e "服务状态: $(systemctl is-active tc-manager 2>/dev/null || echo "未运行")"
    echo -e "-----------------------------------"
    echo -e "1. 添加限速规则"
    echo -e "2. 删除限速规则"
    echo -e "3. 查看当前规则"
    echo -e "4. 批量添加规则"
    echo -e "5. 批量删除规则"
    echo -e "6. 设置网络接口"
    echo -e "7. 服务管理"
    echo -e "8. 卸载本工具"
    echo -e "0. 退出"
    echo -e "===================================\n"
}

# 批量添加规则
batch_add() {
    echo -e "\n批量添加规则说明:"
    echo -e "1. 编辑配置文件: $CONFIG_FILE"
    echo -e "2. 格式: 方向 端口 速率 [最大速率]"
    echo -e "   示例:"
    echo -e "      出站 80 10 20"
    echo -e "      入站 443 20"
    echo -e "3. 保存文件后返回此菜单"
    
    read -p "按Enter键编辑配置文件..." 
    nano "$CONFIG_FILE"
    
    read -p "是否应用这些规则? [y/N] " confirm
    if [[ "$confirm" =~ [Yy] ]]; then
        apply_rules
    fi
}

# 批量删除规则
batch_del() {
    echo -e "\n当前规则:"
    awk '/^(出站|入站)/ {print NR ". " $0}' "$CONFIG_FILE"
    
    read -p "输入要删除的规则编号(多个用空格分隔): " numbers
    if [ -z "$numbers" ]; then
        echo "操作取消"
        return
    fi
    
    # 倒序删除
    for num in $(echo "$numbers" | tr ' ' '\n' | sort -rn); do
        sed -i "${num}d" "$CONFIG_FILE"
    done
    
    echo "已删除选中的规则"
    read -p "是否重新应用规则? [y/N] " confirm
    [[ "$confirm" =~ [Yy] ]] && apply_rules
}

# 服务管理菜单
service_menu() {
    while true; do
        clear
        echo -e "\n=== 服务管理 ==="
        echo -e "1. 启动服务"
        echo -e "2. 停止服务"
        echo -e "3. 重启服务"
        echo -e "4. 启用开机自启"
        echo -e "5. 禁用开机自启"
        echo -e "6. 返回主菜单"
        
        read -p "请选择操作 (1-6): " choice
        case $choice in
            1) service_control start;;
            2) service_control stop;;
            3) service_control restart;;
            4) systemctl enable tc-manager; echo "已启用开机自启";;
            5) systemctl disable tc-manager; echo "已禁用开机自启";;
            6) return;;
            *) echo "无效选择";;
        esac
        sleep 1
    done
}

# 安装服务
install_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=TC Bandwidth Manager
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tc-manager service start
ExecStop=/usr/local/bin/tc-manager service stop
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tc-manager
    echo "系统服务已安装并启用开机自启"
}

# 安装脚本
install() {
    # 检查root
    [ "$(id -u)" != "0" ] && echo "必须使用root权限" && exit 1
    
    # 安装依赖
    if ! command -v tc &>/dev/null; then
        echo "安装依赖: iproute2, iptables"
        apt-get update
        apt-get install -y iproute2 iptables
    fi
    
    # 复制脚本
    cp -f "$0" /usr/local/bin/tc-manager
    chmod +x /usr/local/bin/tc-manager
    
    # 初始化配置
    init_config
    
    # 安装服务
    install_service
    
    echo -e "\n\033[1;32m✓ TC限速管理工具 v$VERSION 安装成功\033[0m"
    echo -e "使用命令: \033[1;33mtc-manager\033[0m 启动管理界面"
}

# 卸载脚本
uninstall() {
    # 停止服务
    systemctl stop tc-manager 2>/dev/null
    systemctl disable tc-manager 2>/dev/null
    
    # 清除规则
    clean_rules
    
    # 删除文件
    rm -f /usr/local/bin/tc-manager
    rm -f "$SERVICE_FILE"
    rm -rf "$CONFIG_DIR"
    
    systemctl daemon-reload
    echo -e "\n\033[1;32m✓ TC限速管理工具已卸载\033[0m"
}

# 主函数
main() {
    # 命令行参数处理
    case "$1" in
        install)
            install
            exit 0
            ;;
        uninstall)
            uninstall
            exit 0
            ;;
        service)
            service_control "$2"
            exit 0
            ;;
        apply-rules)
            apply_rules
            exit 0
            ;;
        clean-rules)
            clean_rules
            exit 0
            ;;
    esac
    
    # 交互式菜单
    while true; do
        show_menu
        read -p "请选择操作 (0-8): " choice
        
        case $choice in
            1)  # 添加规则
                echo -e "\n--- 添加限速规则 ---"
                read -p "方向 (出站/入站): " direction
                read -p "端口: " port
                read -p "保证带宽 (整数，单位Mbps): " rate
                read -p "最大带宽 (整数，单位Mbps，回车使用保证带宽): " ceil
                
                if [[ "$direction" =~ ^(出站|入站)$ ]] && [[ "$port" =~ ^[0-9]+$ ]] && [[ "$rate" =~ ^[0-9]+$ ]]; then
                    add_limit "$direction" "$port" "$rate" "$ceil"
                else
                    echo "输入无效，请确保方向为出站/入站，端口和带宽为整数"
                fi
                ;;
            
            2)  # 删除规则
                echo -e "\n--- 删除限速规则 ---"
                read -p "方向 (出站/入站): " direction
                read -p "端口: " port
                
                if [[ "$direction" =~ ^(出站|入站)$ ]] && [[ "$port" =~ ^[0-9]+$ ]]; then
                    del_limit "$direction" "$port"
                else
                    echo "输入无效"
                fi
                ;;
            
            3)  # 查看规则
                echo -e "\n--- 当前限速规则 ---"
                echo -e "方向\t端口\t保证带宽\t最大带宽"
                echo "------------------------------------"
                awk '/^(出站|入站)/ {print $1 "\t" $2 "\t" $3 "\t\t" $4}' "$CONFIG_FILE"
                read -p "按Enter键继续..."
                ;;
            
            4)  # 批量添加
                batch_add
                ;;
            
            5)  # 批量删除
                batch_del
                ;;
            
            6)  # 设置接口
                echo -e "\n当前网络接口: $(get_interface)"
                ip -o link show | awk -F': ' '{print $2}'
                read -p "输入新网络接口名称: " new_iface
                set_interface "$new_iface"
                ;;
            
            7)  # 服务管理
                service_menu
                ;;
            
            8)  # 卸载
                read -p "确定卸载TC限速管理工具? [y/N] " confirm
                [[ "$confirm" =~ [Yy] ]] && uninstall && exit 0
                ;;
            
            0)  # 退出
                echo "感谢使用!"
                exit 0
                ;;
            
            *)
                echo "无效选择"
                ;;
        esac
    done
}

# 启动主函数
if [ $# -ge 1 ]; then
    case "$1" in
        install|uninstall|service|apply-rules|clean-rules)
            main "$@"
            ;;
        *)
            echo "用法: tc-manager [install|uninstall|service start|stop|restart|apply-rules|clean-rules]"
            exit 1
            ;;
    esac
else
    main
fi