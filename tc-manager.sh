#!/bin/bash
# 高级TC端口限速管理工具 - 数字菜单版
# 支持入站/出站分别限速、批量操作和开机自启
# 在线安装: bash <(curl -sL https://raw.githubusercontent.com/yourusername/tc-manager/master/tc-manager.sh)

VERSION="2.0"
CONFIG_DIR="/etc/tc_manager"
CONFIG_FILE="$CONFIG_DIR/rules.conf"
INTERFACE_FILE="$CONFIG_DIR/interface"
SERVICE_FILE="/etc/systemd/system/tc-manager.service"
LOG_FILE="/var/log/tc-manager.log"
MENU_WIDTH=70

# 初始化配置目录
init_config() {
    mkdir -p $CONFIG_DIR
    touch $CONFIG_FILE
    
    if [ ! -f "$INTERFACE_FILE" ]; then
        # 自动检测主要网络接口
        DEFAULT_INTERFACE=$(ip route show default | awk '/default/ {print $5}')
        echo "$DEFAULT_INTERFACE" > "$INTERFACE_FILE"
    fi
}

# 获取当前接口
get_interface() {
    cat "$INTERFACE_FILE"
}

# 设置接口
set_interface() {
    clear
    echo -e "\n$(center_text "设置网络接口")\n"
    echo -e "当前网络接口: \033[1;32m$(get_interface)\033[0m"
    echo -e "\n可用的网络接口:"
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo
    
    read -p $'\n请输入新网络接口名称: ' new_iface
    if ip link show $new_iface >/dev/null 2>&1; then
        echo "$new_iface" > "$INTERFACE_FILE"
        echo -e "\n\033[1;32m✓ 已设置网络接口为: $new_iface\033[0m"
        sleep 1
        return 0
    else
        echo -e "\n\033[1;31m✗ 错误: 网络接口 $new_iface 不存在\033[0m"
        sleep 2
        return 1
    fi
}

# 日志功能
log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" >> "$LOG_FILE"
}

# 检查root权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "\n\033[1;31m错误: 必须使用root权限运行此脚本\033[0m"
        exit 1
    fi
}

# 检查必要工具
check_dependencies() {
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
            apt-get update
            apt-get install -y "${missing[@]}"
        elif command -v yum &> /dev/null; then
            yum install -y "${missing[@]}"
        else
            echo -e "\n\033[1;31m错误: 无法自动安装依赖，请手动安装: ${missing[*]}\033[0m"
            exit 1
        fi
    fi
}

# 初始化IFB设备（用于入站限速）
init_ifb() {
    local iface=$(get_interface)
    
    # 加载ifb模块
    modprobe ifb numifbs=1
    
    # 启用ifb0设备
    ip link set dev ifb0 up
    
    # 清除现有规则
    tc qdisc del dev $iface ingress >/dev/null 2>&1
    tc qdisc del dev ifb0 root >/dev/null 2>&1
    
    # 重定向入口流量到ifb0
    tc qdisc add dev $iface handle ffff: ingress
    tc filter add dev $iface parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0
    
    # 为ifb0设置根队列
    tc qdisc add dev ifb0 root handle 1: htb default 20
    tc class add dev ifb0 parent 1: classid 1:1 htb rate 1000mbit
    
    log "IFB设备已初始化"
}

# 清除所有规则
clean_all() {
    local iface=$(get_interface)
    
    # 清除出站规则
    tc qdisc del dev $iface root >/dev/null 2>&1
    
    # 清除入站规则
    tc qdisc del dev $iface ingress >/dev/null 2>&1
    tc qdisc del dev ifb0 root >/dev/null 2>&1
    
    # 清除iptables标记
    iptables -t mangle -F
    
    log "已清除所有TC规则和iptables标记"
}

# 添加端口限速
add_limit() {
    local direction=$1
    local port=$2
    local rate=$3
    local ceil=${4:-$rate}
    local burst=${5:-32k}
    local iface=$(get_interface)
    
    # 检查端口是否已存在
    if grep -q "^$direction $port " "$CONFIG_FILE"; then
        echo -e "\033[1;31m错误: $direction 方向端口 $port 已有规则，请先删除或更新\033[0m"
        return 1
    fi
    
    # 生成唯一标记
    local mark=$(( (RANDOM % 10000) + 10000 ))
    
    # 添加出站限速
    if [ "$direction" == "出站" ]; then
        # 创建根队列（如果不存在）
        if ! tc qdisc show dev $iface | grep -q "htb"; then
            tc qdisc add dev $iface root handle 1: htb default 20
            tc class add dev $iface parent 1: classid 1:1 htb rate 1000mbit
        fi
        
        # 创建限速类
        local classid="1:$mark"
        tc class add dev $iface parent 1:1 classid $classid htb rate $rate ceil $ceil burst $burst
        tc qdisc add dev $iface parent $classid handle ${classid#*:}0: sfq perturb 10
        
        # 标记流量
        iptables -t mangle -A POSTROUTING -o $iface -p tcp --sport $port -j MARK --set-mark $mark
        iptables -t mangle -A POSTROUTING -o $iface -p tcp --dport $port -j MARK --set-mark $mark
        tc filter add dev $iface parent 1:0 protocol ip handle $mark fw flowid $classid
    
    # 添加入站限速
    elif [ "$direction" == "入站" ]; then
        init_ifb
        
        # 创建限速类
        local classid="1:$mark"
        tc class add dev ifb0 parent 1:1 classid $classid htb rate $rate ceil $ceil burst $burst
        tc qdisc add dev ifb0 parent $classid handle ${classid#*:}0: sfq perturb 10
        
        # 标记流量（在入口处）
        iptables -t mangle -A PREROUTING -i $iface -p tcp --sport $port -j MARK --set-mark $mark
        iptables -t mangle -A PREROUTING -i $iface -p tcp --dport $port -j MARK --set-mark $mark
        tc filter add dev ifb0 parent 1:0 protocol ip handle $mark fw flowid $classid
    fi
    
    # 保存配置
    echo "$direction $port $rate $ceil $burst $mark" >> "$CONFIG_FILE"
    echo -e "\033[1;32m✓ 已添加 $direction 方向端口 $port 限速: 保证 $rate 最大 $ceil\033[0m"
    sleep 1
}

# 删除端口限速
del_limit() {
    local direction=$1
    local port=$2
    local iface=$(get_interface)
    
    # 从配置文件中查找规则
    local rule=$(grep "^$direction $port " "$CONFIG_FILE")
    if [ -z "$rule" ]; then
        echo -e "\033[1;31m错误: 未找到 $direction 方向端口 $port 的限速规则\033[0m"
        return 1
    fi
    
    # 提取标记值
    local mark=$(echo $rule | awk '{print $6}')
    
    # 删除出站规则
    if [ "$direction" == "出站" ]; then
        # 删除TC规则
        tc filter del dev $iface parent 1:0 protocol ip handle $mark fw
        tc class del dev $iface classid 1:$mark
        
        # 删除iptables规则
        iptables -t mangle -L PREROUTING --line-numbers | grep "MARK set $mark" | awk '{print $1}' | sort -rn | \
            while read line; do iptables -t mangle -D PREROUTING $line; done
    
    # 删除入站规则
    elif [ "$direction" == "入站" ]; then
        # 删除TC规则
        tc filter del dev ifb0 parent 1:0 protocol ip handle $mark fw
        tc class del dev ifb0 classid 1:$mark
        
        # 删除iptables规则
        iptables -t mangle -L POSTROUTING --line-numbers | grep "MARK set $mark" | awk '{print $1}' | sort -rn | \
            while read line; do iptables -t mangle -D POSTROUTING $line; done
    fi
    
    # 更新配置文件
    sed -i "/^$direction $port /d" "$CONFIG_FILE"
    echo -e "\033[1;32m✓ 已删除 $direction 方向端口 $port 的限速规则\033[0m"
    sleep 1
}

# 更新限速规则
update_limit() {
    local direction=$1
    local port=$2
    local new_rate=$3
    local new_ceil=${4:-$new_rate}
    
    # 先删除旧规则
    del_limit "$direction" "$port" >/dev/null 2>&1
    
    # 添加新规则
    add_limit "$direction" "$port" "$new_rate" "$new_ceil"
}

# 批量添加限速
batch_add() {
    clear
    echo -e "\n$(center_text "批量添加限速规则")\n"
    
    if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
        echo -e "\033[1;33m配置文件 $CONFIG_FILE 为空或不存在\033[0m"
        read -p $'\n是否创建示例配置文件? (y/n): ' create_example
        if [ "$create_example" == "y" ]; then
            echo "# 方向 端口 速率 最大速率 突发值" > "$CONFIG_FILE"
            echo "出站 80 1mbit 2mbit 32k" >> "$CONFIG_FILE"
            echo "入站 443 512kbit 1mbit" >> "$CONFIG_FILE"
            echo "出站 22 100kbit" >> "$CONFIG_FILE"
            echo -e "\033[1;32m✓ 已创建示例配置文件\033[0m"
        else
            return 1
        fi
    fi
    
    echo -e "当前配置文件内容:\n"
    cat "$CONFIG_FILE"
    
    read -p $'\n是否应用这些规则? (y/n): ' confirm
    if [ "$confirm" == "y" ]; then
        while read -r line; do
            if [[ ! "$line" =~ ^# ]] && [ -n "$line" ]; then
                add_limit $line
            fi
        done < "$CONFIG_FILE"
        echo -e "\033[1;32m✓ 批量添加完成\033[0m"
    else
        echo -e "\033[1;33m操作已取消\033[0m"
    fi
    sleep 2
}

# 批量删除限速
batch_del() {
    clear
    echo -e "\n$(center_text "批量删除限速规则")\n"
    
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "\033[1;33m没有可删除的规则\033[0m"
        sleep 1
        return
    fi
    
    echo -e "当前限速规则:\n"
    awk '!/^#/ && NF {print "端口: " $2 " (" $1 "), 速率: " $3}' "$CONFIG_FILE"
    
    read -p $'\n请输入要删除的端口(多个端口用空格分隔): ' ports
    if [ -z "$ports" ]; then
        echo -e "\033[1;33m未输入端口，操作取消\033[0m"
        sleep 1
        return
    fi
    
    for port in $ports; do
        # 删除出站
        del_limit 出站 "$port" >/dev/null 2>&1
        # 删除入站
        del_limit 入站 "$port" >/dev/null 2>&1
    done
    
    echo -e "\033[1;32m✓ 批量删除完成\033[0m"
    sleep 1
}

# 启用系统服务
enable_service() {
    cat > $SERVICE_FILE <<EOF
[Unit]
Description=TC Bandwidth Manager
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/tc-manager start
ExecReload=/usr/local/bin/tc-manager reload
ExecStop=/usr/local/bin/tc-manager stop

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable tc-manager >/dev/null 2>&1
    echo -e "\033[1;32m✓ 已启用开机自启服务\033[0m"
    sleep 1
}

# 禁用系统服务
disable_service() {
    systemctl disable tc-manager >/dev/null 2>&1
    rm -f $SERVICE_FILE
    systemctl daemon-reload
    echo -e "\033[1;32m✓ 已禁用开机自启服务\033[0m"
    sleep 1
}

# 显示当前规则
show_rules() {
    local iface=$(get_interface)
    
    clear
    echo -e "\n$(center_text "当前限速规则")\n"
    
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "\033[1;33m没有配置限速规则\033[0m"
    else
        echo -e "\033[1;36m方向\t端口\t保证带宽\t最大带宽\033[0m"
        echo "------------------------------------------------"
        awk '!/^#/ && NF {print $1 "\t" $2 "\t" $3 "\t\t" $4}' "$CONFIG_FILE"
    fi
    
    echo -e "\n$(center_text "网络接口状态")\n"
    echo -e "网络接口: \033[1;32m$iface\033[0m"
    echo -e "服务状态: \033[1;33m$(systemctl is-active tc-manager 2>/dev/null || echo "未运行")\033[0m"
    
    read -p $'\n按Enter键返回主菜单...'
}

# 启动服务
start_service() {
    clean_all
    if [ -s "$CONFIG_FILE" ]; then
        while read -r line; do
            if [[ ! "$line" =~ ^# ]] && [ -n "$line" ]; then
                add_limit $line
            fi
        done < "$CONFIG_FILE"
        echo -e "\033[1;32m✓ 已从配置文件加载所有规则\033[0m"
    else
        echo -e "\033[1;33m没有配置规则，服务已启动但未添加限速\033[0m"
    fi
    sleep 1
}

# 安装脚本
install() {
    check_root
    init_config
    check_dependencies
    
    # 复制脚本到系统目录
    cp $0 /usr/local/bin/tc-manager
    chmod +x /usr/local/bin/tc-manager
    
    # 创建默认配置文件
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "# 方向 端口 速率 最大速率 突发值" > "$CONFIG_FILE"
        echo "# 示例: 出站 80 1mbit 2mbit 32k" >> "$CONFIG_FILE"
    fi
    
    echo -e "\n\033[1;32m✓ TC限速管理工具 v$VERSION 已安装\033[0m"
    echo -e "使用命令: \033[1;33mtc-manager\033[0m 启动管理界面"
    sleep 2
}

# 卸载脚本
uninstall() {
    check_root
    clean_all
    disable_service
    
    rm -f /usr/local/bin/tc-manager
    rm -rf $CONFIG_DIR
    rm -f $SERVICE_FILE
    
    echo -e "\033[1;32m✓ TC限速管理工具已卸载\033[0m"
    sleep 2
}

# 添加单个限速规则菜单
add_limit_menu() {
    clear
    echo -e "\n$(center_text "添加限速规则")\n"
    
    # 选择方向
    echo -e "1. 出站限速 (egress)"
    echo -e "2. 入站限速 (ingress)"
    read -p $'\n请选择限速方向 (1/2): ' direction_choice
    
    case $direction_choice in
        1) direction="出站" ;;
        2) direction="入站" ;;
        *) 
            echo -e "\033[1;31m无效选择\033[0m"
            sleep 1
            return
            ;;
    esac
    
    # 输入端口
    read -p $'\n请输入端口号: ' port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "\033[1;31m错误: 端口号无效 (1-65535)\033[0m"
        sleep 1
        return
    fi
    
    # 输入速率
    read -p $'\n请输入保证带宽 (如 1mbit, 512kbit): ' rate
    if ! [[ "$rate" =~ ^[0-9]+[mk]bit$ ]]; then
        echo -e "\033[1;31m错误: 带宽格式无效 (示例: 1mbit, 512kbit)\033[0m"
        sleep 1
        return
    fi
    
    # 输入最大速率
    read -p $'请输入最大带宽 (可选，直接回车使用保证带宽): ' ceil
    if [ -z "$ceil" ]; then
        ceil=$rate
    elif ! [[ "$ceil" =~ ^[0-9]+[mk]bit$ ]]; then
        echo -e "\033[1;31m错误: 带宽格式无效 (示例: 1mbit, 512kbit)\033[0m"
        sleep 1
        return
    fi
    
    # 添加规则
    add_limit "$direction" "$port" "$rate" "$ceil"
}

# 删除单个限速规则菜单
del_limit_menu() {
    clear
    echo -e "\n$(center_text "删除限速规则")\n"
    
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "\033[1;33m没有可删除的规则\033[0m"
        sleep 1
        return
    fi
    
    echo -e "当前限速规则:\n"
    awk '!/^#/ && NF {print NR ". 端口: " $2 " (" $1 "), 速率: " $3}' "$CONFIG_FILE"
    
    read -p $'\n请选择要删除的规则编号: ' rule_num
    if ! [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        echo -e "\033[1;31m错误: 无效的规则编号\033[0m"
        sleep 1
        return
    fi
    
    local rule=$(sed -n "${rule_num}p" "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$rule" ]; then
        echo -e "\033[1;31m错误: 找不到指定规则\033[0m"
        sleep 1
        return
    fi
    
    local direction=$(echo $rule | awk '{print $1}')
    local port=$(echo $rule | awk '{print $2}')
    
    read -p $'\n确定要删除这条规则吗? (y/n): ' confirm
    if [ "$confirm" == "y" ]; then
        del_limit "$direction" "$port"
    else
        echo -e "\033[1;33m操作已取消\033[0m"
        sleep 1
    fi
}

# 更新限速规则菜单
update_limit_menu() {
    clear
    echo -e "\n$(center_text "更新限速规则")\n"
    
    if [ ! -s "$CONFIG_FILE" ]; then
        echo -e "\033[1;33m没有可更新的规则\033[0m"
        sleep 1
        return
    fi
    
    echo -e "当前限速规则:\n"
    awk '!/^#/ && NF {print NR ". 端口: " $2 " (" $1 "), 速率: " $3}' "$CONFIG_FILE"
    
    read -p $'\n请选择要更新的规则编号: ' rule_num
    if ! [[ "$rule_num" =~ ^[0-9]+$ ]]; then
        echo -e "\033[1;31m错误: 无效的规则编号\033[0m"
        sleep 1
        return
    fi
    
    local rule=$(sed -n "${rule_num}p" "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$rule" ]; then
        echo -e "\033[1;31m错误: 找不到指定规则\033[0m"
        sleep 1
        return
    fi
    
    local direction=$(echo $rule | awk '{print $1}')
    local port=$(echo $rule | awk '{print $2}')
    local old_rate=$(echo $rule | awk '{print $3}')
    
    echo -e "\n当前设置: 端口 $port ($direction), 带宽: $old_rate"
    
    # 输入新速率
    read -p $'\n请输入新的保证带宽 (如 1mbit, 512kbit): ' new_rate
    if ! [[ "$new_rate" =~ ^[0-9]+[mk]bit$ ]]; then
        echo -e "\033[1;31m错误: 带宽格式无效 (示例: 1mbit, 512kbit)\033[0m"
        sleep 1
        return
    fi
    
    # 输入新最大速率
    read -p $'请输入新的最大带宽 (可选，直接回车使用新保证带宽): ' new_ceil
    if [ -z "$new_ceil" ]; then
        new_ceil=$new_rate
    elif ! [[ "$new_ceil" =~ ^[0-9]+[mk]bit$ ]]; then
        echo -e "\033[1;31m错误: 带宽格式无效 (示例: 1mbit, 512kbit)\033[0m"
        sleep 1
        return
    fi
    
    # 更新规则
    update_limit "$direction" "$port" "$new_rate" "$new_ceil"
}

# 服务管理菜单
service_menu() {
    while true; do
        clear
        echo -e "\n$(center_text "服务管理")\n"
        
        # 显示服务状态
        local status=$(systemctl is-active tc-manager 2>/dev/null || echo "未运行")
        local color="\033[1;32m"
        [ "$status" != "active" ] && color="\033[1;31m"
        
        echo -e "当前服务状态: ${color}$status\033[0m"
        echo -e "开机自启状态: \033[1;33m$(systemctl is-enabled tc-manager 2>/dev/null || echo "禁用")\033[0m"
        
        echo -e "\n1. 启动服务"
        echo -e "2. 停止服务"
        echo -e "3. 启用开机自启"
        echo -e "4. 禁用开机自启"
        echo -e "5. 查看服务日志"
        echo -e "6. 返回主菜单"
        
        read -p $'\n请选择操作 (1-6): ' choice
        
        case $choice in
            1) 
                start_service
                ;;
            2) 
                clean_all
                echo -e "\033[1;32m✓ 服务已停止\033[0m"
                sleep 1
                ;;
            3) 
                enable_service
                ;;
            4) 
                disable_service
                ;;
            5)
                clear
                echo -e "\n$(center_text "服务日志")\n"
                if [ -f "$LOG_FILE" ]; then
                    tail -n 20 "$LOG_FILE"
                else
                    echo "暂无日志"
                fi
                read -p $'\n按Enter键返回...'
                ;;
            6)
                return
                ;;
            *)
                echo -e "\033[1;31m无效选择，请重新输入\033[0m"
                sleep 1
                ;;
        esac
    done
}

# 中心对齐文本
center_text() {
    local text="$1"
    local width=$MENU_WIDTH
    local padding=$(( ($width - ${#text}) / 2 ))
    printf "%${padding}s" ''
    echo -n "$text"
    printf "%${padding}s" ''
}

# 显示主菜单
main_menu() {
    while true; do
        clear
        echo -e "\n$(center_text "TC端口限速管理工具 v$VERSION")\n"
        echo -e "网络接口: \033[1;32m$(get_interface)\033[0m"
        echo -e "服务状态: \033[1;33m$(systemctl is-active tc-manager 2>/dev/null || echo "未运行")\033[0m"
        
        echo -e "\n1. 添加限速规则"
        echo -e "2. 删除限速规则"
        echo -e "3. 更新限速规则"
        echo -e "4. 批量添加规则"
        echo -e "5. 批量删除规则"
        echo -e "6. 查看当前规则"
        echo -e "7. 清除所有规则"
        echo -e "8. 设置网络接口"
        echo -e "9. 服务管理"
        echo -e "10. 卸载本工具"
        echo -e "0. 退出"
        
        read -p $'\n请选择操作 (0-10): ' choice
        
        case $choice in
            1) add_limit_menu ;;
            2) del_limit_menu ;;
            3) update_limit_menu ;;
            4) batch_add ;;
            5) batch_del ;;
            6) show_rules ;;
            7) 
                clean_all
                echo -e "\033[1;32m✓ 所有规则已清除\033[0m"
                sleep 1
                ;;
            8) set_interface ;;
            9) service_menu ;;
            10) 
                read -p $'\n确定要卸载本工具吗? (y/n): ' confirm
                if [ "$confirm" == "y" ]; then
                    uninstall
                    exit 0
                fi
                ;;
            0) 
                echo -e "\n感谢使用!"
                exit 0
                ;;
            *) 
                echo -e "\033[1;31m无效选择，请重新输入\033[0m"
                sleep 1
                ;;
        esac
    done
}

# 安装检查
if [ ! -f "/usr/local/bin/tc-manager" ]; then
    echo -e "\n\033[1;33mTC限速管理工具未安装，正在安装...\033[0m"
    install
fi

# 启动主菜单
init_config
main_menu