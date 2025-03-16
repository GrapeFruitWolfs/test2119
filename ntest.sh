#!/bin/bash

# 定义常量
NOTION_BASE_URL="https://api.notion.com/v1"
API_TOKEN="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"
PAGE_ID="1b5f54b30da880fab349cab11d90c65c"

# 检测是否为受限环境（BusyBox或OpenWrt）
RESTRICTED_ENV=0
if busybox --help >/dev/null 2>&1 && [ "$(readlink -f /bin/sh)" = "/bin/busybox" ]; then
    RESTRICTED_ENV=1
    echo "检测到BusyBox环境，调整为兼容模式"
elif [ -f "/etc/openwrt_release" ] || grep -q "OpenWrt" /etc/os-release 2>/dev/null; then
    RESTRICTED_ENV=1
    echo "检测到OpenWrt环境，调整为兼容模式"
fi

# 检查 HTTP 工具
if command -v curl >/dev/null 2>&1; then
    HTTP_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
    HTTP_TOOL="wget"
else
    echo "错误: 需要 curl 或 wget，请安装一种工具"
    exit 1
fi

# 临时文件处理
cleanup_temp_files() {
    if [ -n "$TEMP_FILES" ]; then
        rm -f $TEMP_FILES 2>/dev/null
    fi
}

create_temp_file() {
    local temp_file
    if [ $RESTRICTED_ENV -eq 1 ]; then
        # 在受限环境下使用固定位置创建临时文件
        temp_file="/tmp/probe_$(date +%s)_$RANDOM"
        touch "$temp_file" 2>/dev/null || temp_file="/var/tmp/probe_$(date +%s)_$RANDOM"
        touch "$temp_file" 2>/dev/null || temp_file="./probe_$(date +%s)_$RANDOM"
    else
        # 标准环境下使用mktemp
        temp_file=$(mktemp 2>/dev/null || mktemp -t probe 2>/dev/null || echo "/tmp/probe_$(date +%s)_$RANDOM")
    fi
    TEMP_FILES="$TEMP_FILES $temp_file"
    echo "$temp_file"
}

# 设置退出陷阱清理临时文件
trap cleanup_temp_files EXIT

# 简化版JSON处理函数（适用于受限环境）
simple_json_get() {
    local json="$1"
    local key="$2"
    local pattern="\"$key\":[[:space:]]*\"([^\"]*)\""
    
    # 尝试匹配"key":"value"模式
    if [[ "$json" =~ $pattern ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    
    # 如果上面的正则不支持，使用更基本的grep方法
    local value=$(echo "$json" | grep -o "\"$key\":\"[^\"]*\"" | cut -d':' -f2 | tr -d '"')
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi
    
    # 最后尝试sed（最基本的方法）
    echo "$json" | sed -n "s/.*\"$key\":\"\\([^\"]*\\)\".*/\\1/p" | head -1
    return 0
}

# JSON 生成函数
json_create_db() {
    local db_name="$1"
    
    # 在受限环境中使用最简单的方式生成JSON
    if [ $RESTRICTED_ENV -eq 1 ]; then
        cat <<EOF
{"parent":{"type":"page_id","page_id":"$PAGE_ID"},"title":[{"type":"text","text":{"content":"$db_name"}}],"properties":{"Name":{"title":{}},"Value":{"rich_text":{}}}}
EOF
    else
        # 标准环境下的JSON生成
        printf '{"parent":{"type":"page_id","page_id":"%s"},"title":[{"type":"text","text":{"content":"%s"}}],"properties":{"Name":{"title":{}},"Value":{"rich_text":{}}}}' "$PAGE_ID" "$db_name"
    fi
}

json_create_entry() {
    local db_id="$1"
    local name="$2"
    local value="$3"
    
    # 转义JSON中的特殊字符（特别为受限环境优化）
    if [ $RESTRICTED_ENV -eq 1 ]; then
        # 使用最基础的sed命令
        local escaped_value=$(echo "$value" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\t/\\t/g' | sed 's/\r/\\r/g')
        escaped_value=$(echo "$escaped_value" | tr '\n' ' ')  # 将换行符替换为空格，避免JSON格式问题
        
        cat <<EOF
{"parent":{"database_id":"$db_id"},"properties":{"Name":{"title":[{"type":"text","text":{"content":"$name"}}]},"Value":{"rich_text":[{"type":"text","text":{"content":"$escaped_value"}}]}}}
EOF
    else
        # 标准环境下的处理
        # 转义JSON中的特殊字符
        value=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\n/\\n/g; s/\r/\\r/g')
        printf '{"parent":{"database_id":"%s"},"properties":{"Name":{"title":[{"type":"text","text":{"content":"%s"}}]},"Value":{"rich_text":[{"type":"text","text":{"content":"%s"}}]}}}' "$db_id" "$name" "$value"
    fi
}

# JSON 解析函数（提取 ID）- 使用简化版JSON处理
json_parse_id() {
    local response="$1"
    
    if [ $RESTRICTED_ENV -eq 1 ]; then
        # 使用专门为受限环境设计的简单JSON解析
        simple_json_get "$response" "id"
    else
        # 标准解析
        echo "$response" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4
    fi
}

# HTTP 请求函数
http_request() {
    local method="$1"
    local url="$2"
    local data="$3"
    local output_file="$4"
    
    if [ "$HTTP_TOOL" = "curl" ]; then
        if [ $RESTRICTED_ENV -eq 1 ]; then
            # 受限环境下使用基础curl命令并将数据写入临时文件
            local temp_data_file=$(create_temp_file)
            echo "$data" > "$temp_data_file"
            
            curl -s -X "$method" "$url" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Notion-Version: 2022-06-28" \
                -H "Content-Type: application/json" \
                --data "@$temp_data_file" > "$output_file" 2>/dev/null
            
            HTTP_CODE=$?
            if [ $HTTP_CODE -eq 0 ]; then
                HTTP_CODE=200
            else
                HTTP_CODE=500
            fi
        else
            # 标准版本
            HTTP_CODE=$(curl -s -o "$output_file" -w "%{http_code}" -X "$method" "$url" \
                -H "Authorization: Bearer $API_TOKEN" \
                -H "Notion-Version: 2022-06-28" \
                -H "Content-Type: application/json" \
                -d "$data")
        fi
    else
        # wget版本
        if [ $RESTRICTED_ENV -eq 1 ]; then
            # 受限环境下的简化版本 - 将数据写入临时文件
            local temp_data_file=$(create_temp_file)
            echo "$data" > "$temp_data_file"
            
            wget -q --header="Authorization: Bearer $API_TOKEN" \
                --header="Notion-Version: 2022-06-28" \
                --header="Content-Type: application/json" \
                --post-file="$temp_data_file" \
                -O "$output_file" "$url" 2>/dev/null
                
            HTTP_CODE=$?
            if [ $HTTP_CODE -eq 0 ]; then
                HTTP_CODE=200
            else
                HTTP_CODE=500
            fi
        else
            # 标准版本
            wget --method="$method" --header="Authorization: Bearer $API_TOKEN" \
                --header="Notion-Version: 2022-06-28" \
                --header="Content-Type: application/json" \
                --body-data="$data" -O "$output_file" "$url" >/dev/null 2>&1
            HTTP_CODE=$?
            HTTP_CODE=$([ $HTTP_CODE -eq 0 ] && echo "200" || echo "500")
        fi
    fi
    
    BODY=$(cat "$output_file")
}

# 测试 API 可用性
test_api() {
    echo "测试 Notion API 可用性..."
    local endpoint="${NOTION_BASE_URL}/pages/${PAGE_ID}"
    local temp_file=$(create_temp_file)
    
    http_request "GET" "$endpoint" "" "$temp_file"
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "API 测试失败，状态码: $HTTP_CODE, 响应: $BODY"
        exit 1
    fi
    echo "API 测试成功！"
}

# 获取外网IP地址 (仅IPv4)
get_external_ip() {
    local ip="未知"
    local temp_file=$(create_temp_file)
    local timeout_opt=""
    
    # 设置超时选项
    if [ "$HTTP_TOOL" = "curl" ]; then
        if curl --help | grep -q max-time; then
            timeout_opt="--max-time 5"
        fi
    else
        if wget --help | grep -q timeout; then
            timeout_opt="--timeout=5"
        fi
    fi
    
    # 纯IPv4服务列表
    local ip_services=("ipv4.icanhazip.com" "ipv4.wtfismyip.com/text" "ip4.seeip.org" "api.ipify.org")
    
    # 尝试多种IP获取服务，提高成功率
    if [ "$HTTP_TOOL" = "curl" ]; then
        for service in "${ip_services[@]}"; do
            if curl -s $timeout_opt "http://$service" -o "$temp_file" 2>/dev/null; then
                ip=$(cat "$temp_file" | tr -d '[:space:]')
                if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    break
                fi
            fi
        done
    else
        for service in "${ip_services[@]}"; do
            if wget -q $timeout_opt -O "$temp_file" "http://$service" 2>/dev/null; then
                ip=$(cat "$temp_file" | tr -d '[:space:]')
                if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    break
                fi
            fi
        done
    fi
    
    # 如果以上都失败，尝试其他通用服务，但仍检查返回是否为IPv4
    if [ "$ip" = "未知" ]; then
        local general_services=("ifconfig.me" "ipinfo.io/ip" "checkip.amazonaws.com")
        if [ "$HTTP_TOOL" = "curl" ]; then
            for service in "${general_services[@]}"; do
                if curl -s $timeout_opt "http://$service" -o "$temp_file" 2>/dev/null; then
                    ip=$(cat "$temp_file" | tr -d '[:space:]')
                    # 严格检查是否为IPv4格式
                    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                        break
                    else
                        ip="未知" # 如果不是IPv4，重置为未知
                    fi
                fi
            done
        else
            for service in "${general_services[@]}"; do
                if wget -q $timeout_opt -O "$temp_file" "http://$service" 2>/dev/null; then
                    ip=$(cat "$temp_file" | tr -d '[:space:]')
                    # 严格检查是否为IPv4格式
                    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                        break
                    else
                        ip="未知" # 如果不是IPv4，重置为未知
                    fi
                fi
            done
        fi
    fi
    
    echo "$ip"
}

# 根据IP地址获取国家代码（简化版）
get_country_code() {
    local ip="$1"
    local country_code="XX" # 默认未知国家
    local temp_file=$(create_temp_file)
    
    # 如果IP未知，使用时区估计
    if [ "$ip" = "未知" ]; then
        return 0
    fi
    
    # 尝试使用IP查询服务获取地理位置信息
    if [ "$HTTP_TOOL" = "curl" ]; then
        # 尝试ipinfo.io
        if curl -s "http://ipinfo.io/$ip/country" -o "$temp_file" 2>/dev/null; then
            country_code=$(cat "$temp_file" | tr -d '[:space:]')
            if [ ${#country_code} -eq 2 ]; then
                echo "$country_code"
                return 0
            fi
        fi
        
        # 尝试ip-api.com
        if curl -s "http://ip-api.com/line/$ip?fields=countryCode" -o "$temp_file" 2>/dev/null; then
            country_code=$(cat "$temp_file" | tr -d '[:space:]')
            if [ ${#country_code} -eq 2 ]; then
                echo "$country_code"
                return 0
            fi
        fi
    else
        # 使用wget
        if wget -q -O "$temp_file" "http://ipinfo.io/$ip/country" 2>/dev/null; then
            country_code=$(cat "$temp_file" | tr -d '[:space:]')
            if [ ${#country_code} -eq 2 ]; then
                echo "$country_code"
                return 0
            fi
        fi
        
        if wget -q -O "$temp_file" "http://ip-api.com/line/$ip?fields=countryCode" 2>/dev/null; then
            country_code=$(cat "$temp_file" | tr -d '[:space:]')
            if [ ${#country_code} -eq 2 ]; then
                echo "$country_code"
                return 0
            fi
        fi
    fi
    
    # 使用时区作为后备方法
    local tz=""
    if [ -f /etc/timezone ]; then
        tz=$(cat /etc/timezone)
    elif command -v timedatectl >/dev/null 2>&1; then
        tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    fi
    
    # 基于时区推断国家代码
    if [ -n "$tz" ]; then
        case "$tz" in
            *Asia/Shanghai*|*Asia/Chongqing*|*Asia/Harbin*|*Asia/Urumqi*)
                country_code="CN"
                ;;
            *America/New_York*|*America/Chicago*|*America/Denver*|*America/Los_Angeles*)
                country_code="US"
                ;;
            *Europe/London*)
                country_code="GB"
                ;;
            *Europe/Paris*|*Europe/Berlin*|*Europe/Rome*)
                country_code="EU"
                ;;
            *Asia/Tokyo*)
                country_code="JP"
                ;;
            *Asia/Seoul*)
                country_code="KR"
                ;;
            *Asia/Singapore*)
                country_code="SG"
                ;;
            *Australia/Sydney*)
                country_code="AU"
                ;;
            *)
                # 提取时区的第一部分作为区域指示
                local region=$(echo "$tz" | cut -d'/' -f1)
                if [ -n "$region" ]; then
                    # 简化为2个字符的缩写
                    country_code=$(echo "$region" | cut -c1-2 | tr '[:lower:]' '[:upper:]')
                fi
                ;;
        esac
    fi
    
    echo "$country_code"
}

# 检查IP是否为内网地址
is_private_ip() {
    local ip="$1"
    
    # 检查是否是常见的内网IP段
    if [[ $ip =~ ^10\. ]] || \
       [[ $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
       [[ $ip =~ ^192\.168\. ]] || \
       [[ $ip =~ ^127\. ]] || \
       [[ $ip =~ ^169\.254\. ]] || \
       [[ $ip =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
        return 0  # 是内网IP
    else
        return 1  # 不是内网IP
    fi
}

# 获取内网IPv4地址 - 优化版
get_internal_ip() {
    local ip="未知"
    local temp_file=$(create_temp_file)
    local external_ip=$(get_external_ip)  # 获取外网IP地址
    
    # 获取所有可能的IP地址列表
    local all_ips=""
    
    # 方法1: 使用hostname -I (如果可用)
    if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
        hostname -I > "$temp_file"
        all_ips="$all_ips $(grep -o -E '([0-9]{1,3}\.){3}[0-9]{1,3}' "$temp_file")"
    fi
    
    # 方法2: 使用ip命令
    if command -v ip >/dev/null 2>&1; then
        # 明确获取IPv4地址
        ip -4 addr show scope global > "$temp_file"
        all_ips="$all_ips $(grep -oP '(?<=inet\s)\d+(\.\d+){3}' "$temp_file")"
    fi
    
    # 方法3: 使用ifconfig命令
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig > "$temp_file"
        all_ips="$all_ips $(grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' "$temp_file" | awk '{print $2}' | sed 's/addr://')"
    fi
    
    # 方法4: OpenWrt/BusyBox专用方法
    if [ $RESTRICTED_ENV -eq 1 ]; then
        # 尝试从/proc/net/fib_trie获取
        if [ -f "/proc/net/fib_trie" ]; then
            cat "/proc/net/fib_trie" > "$temp_file"
            # 寻找非127.0.0.1的地址
            local interfaces=$(ls /sys/class/net/ | grep -v 'lo\|sit\|tun' 2>/dev/null)
            for iface in $interfaces; do
                all_ips="$all_ips $(grep -A4 "/$iface/" "$temp_file" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v "127.0.0")"
            done
        fi
    fi
    
    # 方法5: 解析route命令结果
    if command -v route >/dev/null 2>&1; then
        # 尝试从默认路由的接口获取IP
        local default_if=$(route -n 2>/dev/null | grep '^0.0.0.0' | head -1 | awk '{print $NF}')
        if [ -n "$default_if" ] && command -v ip >/dev/null 2>&1; then
            ip addr show dev "$default_if" > "$temp_file"
            all_ips="$all_ips $(grep -oP '(?<=inet\s)\d+(\.\d+){3}' "$temp_file")"
        fi
    fi
    
    # 去重和过滤IP地址列表
    all_ips=$(echo "$all_ips" | tr ' ' '\n' | grep -v '^$' | sort -u)
    
    # 遍历所有IP，选择第一个满足条件的内网IP地址
    for ip_addr in $all_ips; do
        # 跳过回环地址
        if [[ "$ip_addr" == "127."* ]]; then
            continue
        fi
        
        # 跳过外网IP地址
        if [ "$ip_addr" = "$external_ip" ]; then
            continue
        fi
        
        # 检查是否为内网IP
        if is_private_ip "$ip_addr"; then
            ip="$ip_addr"
            break
        fi
    done
    
    echo "$ip"
}

# 获取系统运行时间
get_uptime() {
    local uptime_str="未知"
    
    # 在受限环境中优先使用简单方法
    if [ $RESTRICTED_ENV -eq 1 ] && [ -e /proc/uptime ]; then
        # 从/proc/uptime获取运行时间（秒）
        local uptime_seconds=$(cat /proc/uptime | cut -d' ' -f1 | cut -d'.' -f1)
        
        # 计算天、小时、分钟
        local days=$((uptime_seconds / 86400))
        local hours=$(((uptime_seconds % 86400) / 3600))
        local minutes=$(((uptime_seconds % 3600) / 60))
        
        # 格式化输出
        uptime_str="${days}天 ${hours}小时 ${minutes}分钟"
    elif [ -f /proc/uptime ]; then
        # 标准Linux环境
        local uptime_seconds=$(awk '{print int($1)}' /proc/uptime)
        
        # 计算天、小时、分钟
        local days=$((uptime_seconds / 86400))
        local hours=$(((uptime_seconds % 86400) / 3600))
        local minutes=$(((uptime_seconds % 3600) / 60))
        
        # 格式化输出
        uptime_str="${days}天 ${hours}小时 ${minutes}分钟"
    elif command -v uptime >/dev/null 2>&1; then
        # 尝试使用uptime命令
        local uptime_output=$(uptime)
        if echo "$uptime_output" | grep -q "days\?\|day\|天"; then
            # 处理包含"天"的情况
            uptime_str=$(echo "$uptime_output" | sed -E 's/.*up[[:space:]]+([^,]*).*/\1/' | sed 's/^ *//g')
        else
            # 处理没有"天"的情况，例如仅显示小时和分钟
            uptime_str=$(echo "$uptime_output" | sed -E 's/.*up[[:space:]]+([^,]*).*/\1/' | sed 's/^ *//g')
            # 如果只有分钟，那么添加"0天"前缀
            if ! echo "$uptime_str" | grep -q "day\|days\|天\|hour\|小时"; then
                uptime_str="0天 $uptime_str"
            fi
        fi
    elif [ -f /sys/devices/virtual/rtc/rtc0/since_epoch ] && [ -f /proc/stat ]; then
        # 对于某些嵌入式系统，尝试使用RTC和启动时间差值
        local current_time=$(date +%s)
        local boot_time=$(grep btime /proc/stat | awk '{print $2}')
        if [ -n "$boot_time" ]; then
            local uptime_seconds=$((current_time - boot_time))
            local days=$((uptime_seconds / 86400))
            local hours=$(((uptime_seconds % 86400) / 3600))
            local minutes=$(((uptime_seconds % 3600) / 60))
            uptime_str="${days}天 ${hours}小时 ${minutes}分钟"
        fi
    fi
    
    echo "$uptime_str"
}

# 获取CPU型号
get_cpu_model() {
    local cpu_model="未知"
    
    # 对于OpenWrt和BusyBox环境的特殊处理
    if [ $RESTRICTED_ENV -eq 1 ]; then
        if [ -f /proc/cpuinfo ]; then
            if grep -q "model name" /proc/cpuinfo; then
                cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | sed 's/.*: //')
            elif grep -q "system type" /proc/cpuinfo; then
                # OpenWrt常见格式
                cpu_model=$(grep "system type" /proc/cpuinfo | head -1 | sed 's/.*: //')
            elif grep -q "Processor" /proc/cpuinfo; then
                cpu_model=$(grep "Processor" /proc/cpuinfo | head -1 | sed 's/.*: //')
            elif grep -q "cpu model" /proc/cpuinfo; then
                cpu_model=$(grep "cpu model" /proc/cpuinfo | head -1 | sed 's/.*: //')
            fi
        fi
    elif [ -f /proc/cpuinfo ]; then
        # 从/proc/cpuinfo获取CPU信息 - 常规Linux
        if grep -q "model name" /proc/cpuinfo; then
            cpu_model=$(grep -m 1 "model name" /proc/cpuinfo | sed 's/model name[[:space:]]*:[[:space:]]*//')
        elif grep -q "Processor" /proc/cpuinfo; then
            # 对于某些ARM处理器
            cpu_model=$(grep -m 1 "Processor" /proc/cpuinfo | sed 's/Processor[[:space:]]*:[[:space:]]*//')
        elif grep -q "cpu" /proc/cpuinfo; then
            # 通用尝试
            cpu_model=$(grep -m 1 "cpu" /proc/cpuinfo | head -1 | sed 's/[[:space:]]*:[[:space:]]*//')
        fi
    elif command -v lscpu >/dev/null 2>&1; then
        # 尝试使用lscpu命令
        cpu_model=$(lscpu | grep -m 1 "Model name" | sed 's/Model name:[[:space:]]*//')
    fi
    
    # 清理多余空格
    cpu_model=$(echo "$cpu_model" | sed 's/  */ /g' | sed 's/^ *//g' | sed 's/ *$//g')
    
    # 如果还是空的，尝试其他方法
    if [ -z "$cpu_model" ] || [ "$cpu_model" = "未知" ]; then
        if command -v sysctl >/dev/null 2>&1 && sysctl -n machdep.cpu.brand_string >/dev/null 2>&1; then
            # macOS 或 FreeBSD
            cpu_model=$(sysctl -n machdep.cpu.brand_string)
        elif [ -d "/sys/firmware/devicetree/base/" ] && [ -f "/sys/firmware/devicetree/base/model" ]; then
            # 某些嵌入式系统使用devicetree
            cpu_model=$(cat "/sys/firmware/devicetree/base/model" 2>/dev/null)
        elif [ -d "/sys/devices/virtual/dmi/id/" ] && [ -r "/sys/devices/virtual/dmi/id/product_name" ]; then
            # 某些 Linux 系统
            cpu_model=$(cat "/sys/devices/virtual/dmi/id/product_name")
        fi
    fi
    
    echo "$cpu_model"
}

# 检查是否存在挖矿软件
check_mining_software() {
    local mining_found="否"
    local mining_details=""
    local temp_file=$(create_temp_file)
    
    # 可疑进程关键词列表
    local mining_keywords=("miner" "xmr" "xmrig" "ethminer" "cpuminer" "bfgminer" "cgminer" "sgminer"
                         "ccminer" "cryptonight" "stratum" "monero" "ethash" "eth_miner" "coinhive" 
                         "minergate" "nicehash" "minerd" "minerc" "mining" "bminer" "excavator")
    
    # 检查是否有任何挖矿相关进程
    local suspicious_processes=""
    
    # 在受限环境中使用最小的命令集
    if [ $RESTRICTED_ENV -eq 1 ]; then
        if command -v ps >/dev/null 2>&1; then
            suspicious_processes=$(ps w 2>/dev/null | grep -v grep)
            for keyword in "${mining_keywords[@]}"; do
                if echo "$suspicious_processes" | grep -i "$keyword" > "$temp_file"; then
                    mining_found="是"
                    mining_details="${mining_details}可疑进程: $(cat "$temp_file" | head -3 | tr '\n' '|')\n"
                fi
            done
        fi
    else
        # 标准环境下的完整检查
        if command -v ps >/dev/null 2>&1; then
            for keyword in "${mining_keywords[@]}"; do
                if ps aux | grep -v grep | grep -i "$keyword" > "$temp_file"; then
                    mining_found="是"
                    mining_details="${mining_details}可疑进程: $(cat "$temp_file" | head -3 | awk '{print $1,$2,$11}' | tr '\n' '|')\n"
                fi
            done
        fi
        
        # 检查常见的挖矿软件路径
        local mining_paths=("/tmp/" "/var/tmp/" "/dev/shm/" "/run/" "/home/" "/root/")
        for path in "${mining_paths[@]}"; do
            if [ -d "$path" ]; then
                for keyword in "${mining_keywords[@]}"; do
                    if find "$path" -name "*$keyword*" -type f -executable 2>/dev/null | head -3 > "$temp_file"; then
                        if [ -s "$temp_file" ]; then
                            mining_found="是"
                            mining_details="${mining_details}可疑文件: $(cat "$temp_file" | tr '\n' '|')\n"
                        fi
                    fi
                done
            fi
        done
        
        # 检查异常CPU使用量
        if command -v top >/dev/null 2>&1; then
            local cpu_hogs=$(top -b -n 1 | head -20 | grep -E '[0-9]{2,3}\.[0-9]' | grep -v "top\|Cpu(s)")
            if [ -n "$cpu_hogs" ]; then
                echo "$cpu_hogs" | while read line; do
                    local cpu_usage=$(echo "$line" | awk '{print $9}')
                    if [ "$(echo "$cpu_usage > 80.0" | bc 2>/dev/null)" = "1" ]; then
                        mining_details="${mining_details}高CPU使用: $(echo "$line" | awk '{print $1,$9,$12}')\n"
                    fi
                done
            fi
        fi
        
        # 检查已知的挖矿网络连接
        if command -v netstat >/dev/null 2>&1 || command -v ss >/dev/null 2>&1; then
            local mining_ports=("3333" "5555" "7777" "14444" "14433" "8545" "9999" "4444")
            local connections=""
            
            if command -v netstat >/dev/null 2>&1; then
                connections=$(netstat -tuna 2>/dev/null)
            else
                connections=$(ss -tuna 2>/dev/null)
            fi
            
            for port in "${mining_ports[@]}"; do
                if echo "$connections" | grep -w "$port" > "$temp_file"; then
                    mining_found="是"
                    mining_details="${mining_details}可疑网络连接 (端口 $port): $(cat "$temp_file" | head -2 | tr '\n' '|')\n"
                fi
            done
        fi
    fi
    
    # 如果没有发现可疑软件，但系统负载异常高，也标记为可疑
    if [ "$mining_found" = "否" ] && [ -f /proc/loadavg ]; then
        local load=$(cat /proc/loadavg | awk '{print $1}')
        local cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1")
        if [ "$(echo "$load > $cores * 0.8" | bc 2>/dev/null)" = "1" ]; then
            mining_details="${mining_details}警告: 系统负载($load)异常高于核心数($cores)\n"
        fi
    fi
    
    # 返回结果
    if [ "$mining_found" = "是" ]; then
        echo "是 - ${mining_details}"
    else
        echo "否"
    fi
}

# 获取硬盘信息（优化版 - 兼容受限环境）
get_disk_info() {
    local mount_point="/"
    local disk_info="未知"
    local result=()
    
    if [ $RESTRICTED_ENV -eq 1 ]; then
        # 受限环境下的简化版
        if command -v df >/dev/null 2>&1; then
            local df_output=$(df "$mount_point" 2>/dev/null | grep -v Filesystem)
            if [ -n "$df_output" ]; then
                local total_kb=$(echo "$df_output" | awk '{print $2}')
                local used_kb=$(echo "$df_output" | awk '{print $3}')
                local avail_kb=$(echo "$df_output" | awk '{print $4}')
                local percent=$(echo "$df_output" | awk '{print $5}' | tr -d '%')
                
                # 使用更基本的计算
                local total_gb=$(awk "BEGIN {printf \"%.1f\", $total_kb / 1024 / 1024}")
                local used_gb=$(awk "BEGIN {printf \"%.1f\", $used_kb / 1024 / 1024}")
                local avail_gb=$(awk "BEGIN {printf \"%.1f\", $avail_kb / 1024 / 1024}")
                
                # 推测磁盘类型 - 简化版
                local disk_type="未知"
                local root_device=$(grep " $mount_point " /proc/mounts | awk '{print $1}' | head -1)
                if [ -n "$root_device" ]; then
                    if [[ "$root_device" == *"mmcblk"* ]]; then
                        disk_type="闪存/SD卡"
                    elif [[ "$root_device" == *"nvme"* ]]; then
                        disk_type="NVMe SSD"
                    elif [ -e "/sys/block/${root_device##*/}/queue/rotational" ]; then
                        local is_rotational=$(cat "/sys/block/${root_device##*/}/queue/rotational" 2>/dev/null)
                        if [ "$is_rotational" = "0" ]; then
                            disk_type="SSD"
                        elif [ "$is_rotational" = "1" ]; then
                            disk_type="HDD"
                        fi
                    elif [ -e "/proc/mtd" ]; then
                        # 检查是否为闪存
                        disk_type="闪存"
                    fi
                fi
                
                result=("$total_gb" "$used_gb" "$avail_gb" "$percent" "$disk_type")
            fi
        fi
    else
        # 优先使用df命令获取分区信息 - 标准处理
        if command -v df >/dev/null 2>&1; then
            # 尝试多种格式选项来适应不同系统
            local df_output=""
            if df -h "$mount_point" >/dev/null 2>&1; then
                df_output=$(df -h "$mount_point" | tail -1)
                local filesystem=$(echo "$df_output" | awk '{print $1}')
                local disk_total=$(echo "$df_output" | awk '{print $2}')
                local disk_used=$(echo "$df_output" | awk '{print $3}')
                local disk_avail=$(echo "$df_output" | awk '{print $4}')
                local disk_percent=$(echo "$df_output" | awk '{print $5}' | tr -d '%')
                
                # 尝试获取磁盘类型
                local disk_type="未知"
                if [ -b "$filesystem" ] && command -v lsblk >/dev/null 2>&1; then
                    # 尝试使用lsblk获取磁盘类型
                    disk_type=$(lsblk -d -o TYPE "$filesystem" 2>/dev/null | tail -1)
                    if [ -z "$disk_type" ]; then
                        # 尝试区分 SSD 和 HDD
                        local parent_dev=$(lsblk -no PKNAME "$filesystem" 2>/dev/null | head -1)
                        if [ -n "$parent_dev" ]; then
                            if [ -d "/sys/block/$parent_dev/queue/rotational" ]; then
                                local is_rotational=$(cat "/sys/block/$parent_dev/queue/rotational" 2>/dev/null)
                                if [ "$is_rotational" = "0" ]; then
                                    disk_type="SSD"
                                elif [ "$is_rotational" = "1" ]; then
                                    disk_type="HDD"
                                fi
                            fi
                        fi
                    fi
                fi
                
                # 尝试检测是否为闪存/eMMC/SD卡
                if [ -z "$disk_type" ] || [ "$disk_type" = "未知" ]; then
                    if echo "$filesystem" | grep -q "mmcblk"; then
                        disk_type="闪存/SD卡"
                    elif echo "$filesystem" | grep -q "nvme"; then
                        disk_type="NVMe SSD"
                    fi
                fi
                
                result=("$disk_total" "$disk_used" "$disk_avail" "$disk_percent" "$disk_type")
            elif df -m "$mount_point" >/dev/null 2>&1; then
                # 使用MB为单位的输出
                df_output=$(df -m "$mount_point" | tail -1)
                local total_mb=$(echo "$df_output" | awk '{print $2}')
                local used_mb=$(echo "$df_output" | awk '{print $3}')
                local avail_mb=$(echo "$df_output" | awk '{print $4}')
                local percent=$(echo "$df_output" | awk '{print $5}' | tr -d '%')
                
                # 将MB转换为人类可读格式
                local total_gb=$(awk "BEGIN {printf \"%.1f GB\", $total_mb / 1024}")
                local used_gb=$(awk "BEGIN {printf \"%.1f GB\", $used_mb / 1024}")
                local avail_gb=$(awk "BEGIN {printf \"%.1f GB\", $avail_mb / 1024}")
                
                result=("$total_gb" "$used_gb" "$avail_gb" "$percent" "未知")
            fi
        fi
        
        # 如果还没有获得结果，尝试手动解析 /proc/mounts
        if [ ${#result[@]} -eq 0 ] && [ -f /proc/mounts ]; then
            local device=$(grep " $mount_point " /proc/mounts | awk '{print $1}')
            if [ -n "$device" ] && [ -b "$device" ]; then
                local block_size=512  # 默认块大小
                if command -v blockdev >/dev/null 2>&1; then
                    local block_count=$(blockdev --getsz "$device" 2>/dev/null)
                    if [ -n "$block_count" ]; then
                        local total_bytes=$((block_size * block_count))
                        local total_gb=$(awk "BEGIN {printf \"%.1f GB\", $total_bytes / 1024 / 1024 / 1024}")
                        result=("$total_gb" "未知" "未知" "未知" "未知")
                    fi
                fi
            fi
        fi
    fi
    
    # 如果还是没有结果，返回未知
    if [ ${#result[@]} -eq 0 ]; then
        result=("未知" "未知" "未知" "未知" "未知")
    fi
    
    echo "${result[*]}"
}

# 收集系统信息
collect_system_info() {
    local os="未知"
    local distribution="未知"
    local kernel_ver="未知"
    local arch="未知"
    local cpus="未知"
    local hostname="未知"
    local time="未知"
    
    # 检测操作系统和发行版
    if [ -f /etc/os-release ]; then
        os=$(grep -w "ID" /etc/os-release | cut -d= -f2 | tr -d '"')
        distribution=$(grep -w "VERSION_ID" /etc/os-release | cut -d= -f2 | tr -d '"' || echo "未知")
    elif [ -f /etc/openwrt_release ]; then
        os="OpenWrt"
        distribution=$(grep -w "DISTRIB_RELEASE" /etc/openwrt_release | cut -d= -f2 | tr -d "'")
    else
        os=$(uname -s)
    fi
    
    kernel_ver=$(uname -r)
    arch=$(uname -m)
    cpus=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1")
    hostname=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "unknown")
    time=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
    
    # 获取CPU型号
    local cpu_model=$(get_cpu_model)
    
    # 获取CPU负载
    local cpu_load="未知"
    if [ -f /proc/loadavg ]; then
        cpu_load=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    fi
    
    # 获取系统运行时间
    local uptime=$(get_uptime)
    
    # 获取外网IP地址 (仅IPv4)
    local external_ip=$(get_external_ip)
    
    # 获取内网IPv4地址 - 优先调用 get_internal_ip
    local internal_ip=$(get_internal_ip)
    
    # 如果内网IP与外网IP相同，设为未知（这种情况通常是IP检测错误）
    if [ "$internal_ip" = "$external_ip" ] && [ "$external_ip" != "未知" ]; then
        internal_ip="未知"
    fi
    
    # 获取内存信息
    local mem_total="N/A"
    local mem_used="N/A"
    local mem_percent="N/A"
    if [ -f /proc/meminfo ]; then
        local mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        local mem_available_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
        
        if [ -n "$mem_available_kb" ]; then
            # 新版本内核提供 MemAvailable
            local mem_used_kb=$((mem_total_kb - mem_available_kb))
        else
            # 旧版本内核需要手动计算
            local mem_free_kb=$(awk '/MemFree/ {print $2}' /proc/meminfo)
            local buffers_kb=$(awk '/Buffers/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
            local cached_kb=$(awk '/^Cached/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
            local mem_used_kb=$((mem_total_kb - mem_free_kb - buffers_kb - cached_kb))
        fi
        
        # 根据环境选择计算方式
        if [ $RESTRICTED_ENV -eq 1 ]; then
            # 简单算法
            mem_total=$((mem_total_kb / 1024 / 1024))
            mem_used=$((mem_used_kb / 1024 / 1024))
            if [ $mem_total -gt 0 ]; then
                mem_percent=$((mem_used_kb * 100 / mem_total_kb))
            fi
        else
            # 使用bc进行精确计算
            mem_total=$(awk "BEGIN {printf \"%.1f\", $mem_total_kb / 1024 / 1024}")
            mem_used=$(awk "BEGIN {printf \"%.1f\", $mem_used_kb / 1024 / 1024}")
            mem_percent=$(awk "BEGIN {printf \"%.1f\", ($mem_used_kb / $mem_total_kb * 100)}")
        fi
    fi
    
    # 获取硬盘信息（优化版）
    IFS=' ' read -r -a disk_info <<< "$(get_disk_info)"
    local disk_total="${disk_info[0]:-未知}"
    local disk_used="${disk_info[1]:-未知}"
    local disk_avail="${disk_info[2]:-未知}"
    local disk_percent="${disk_info[3]:-未知}"
    local disk_type="${disk_info[4]:-未知}"
    
    # 收集用户权限
    local user_privileges="未知"
    local uid=$(id -u 2>/dev/null || echo "unknown")
    if [ "$uid" = "0" ]; then
        user_privileges="root"
    else
        local username=$(id -un 2>/dev/null || echo "$USER")
        local groups=$(id -Gn 2>/dev/null | tr ' ' ',')
        user_privileges="$username (UID: $uid, Groups: $groups)"
    fi
    
    # 获取设备唯一标识符
    local device_id="未知"
    if [ -f /etc/machine-id ]; then
        device_id=$(cat /etc/machine-id)
    elif [ -f /var/lib/dbus/machine-id ]; then
        device_id=$(cat /var/lib/dbus/machine-id)
    elif command -v dmidecode >/dev/null 2>&1; then
        device_id=$(dmidecode -s system-uuid 2>/dev/null)
    elif [ -f /sys/class/net/eth0/address ]; then
        # 使用MAC地址作为备选
        device_id=$(cat /sys/class/net/eth0/address | sed 's/://g')
    elif [ -f /sys/class/net/wlan0/address ]; then
        device_id=$(cat /sys/class/net/wlan0/address | sed 's/://g')
    fi
    
    # 检测是否存在挖矿软件
    local mining_check=$(check_mining_software)
    
    # 输出结果
    echo "OS=$os"
    echo "Distribution=$distribution"
    echo "KernelVersion=$kernel_ver"
    echo "Architecture=$arch"
    echo "CPUs=$cpus"
    echo "CPUModel=$cpu_model"
    echo "CPULoad=$cpu_load"
    echo "Hostname=$hostname"
    echo "DeviceID=$device_id"
    echo "Time=$time"
    echo "Uptime=$uptime"
    echo "ExternalIP=$external_ip"
    echo "InternalIP=$internal_ip"
    echo "DownloadSpeed=未测试"
    echo "UploadSpeed=未测试"
    echo "PingTime=未测试"
    echo "MemoryTotal=$mem_total GB"
    echo "MemoryUsed=$mem_used GB"
    echo "MemoryPercent=$mem_percent%"
    echo "DiskTotal=$disk_total"
    echo "DiskUsed=$disk_used"
    echo "DiskAvailable=$disk_avail"
    echo "DiskPercent=$disk_percent%"
    echo "DiskType=$disk_type"
    echo "UserPrivileges=$user_privileges"
    echo "MiningDetected=$mining_check"
}

# 生成设备分类标识（兼容性增强版）
generate_device_type() {
    local sys_info="$1"
    local cpu_model=$(echo "$sys_info" | grep "^CPUModel=" | cut -d'=' -f2)
    local cpu_count=$(echo "$sys_info" | grep "^CPUs=" | cut -d'=' -f2)
    local mem_total=$(echo "$sys_info" | grep "^MemoryTotal=" | cut -d'=' -f2 | sed 's/ GB//')
    local disk_type=$(echo "$sys_info" | grep "^DiskType=" | cut -d'=' -f2)
    local os=$(echo "$sys_info" | grep "^OS=" | cut -d'=' -f2)
    local distribution=$(echo "$sys_info" | grep "^Distribution=" | cut -d'=' -f2)
    local arch=$(echo "$sys_info" | grep "^Architecture=" | cut -d'=' -f2)
    
    # 设备分类
    local device_type="标准"
    
    # 检测是否为OpenWrt/LEDE
    if [[ "$os" == *"openwrt"* ]] || [[ "$os" == *"lede"* ]] || [[ "$distribution" == *"OpenWrt"* ]]; then
        device_type="路由器"
    # 检测是否为ARM架构
    elif [[ "$arch" == *"arm"* ]] || [[ "$arch" == *"aarch"* ]]; then
        device_type="ARM"
        
        # 检测常见嵌入式设备
        if [[ "$cpu_model" == *"BCM"* ]] || [[ "$cpu_model" == *"Broadcom"* ]] || [[ "$cpu_model" == *"Raspberry"* ]]; then
            device_type="树莓派"
        elif [[ "$cpu_model" == *"Allwinner"* ]]; then
            device_type="全志"
        elif [[ "$cpu_model" == *"Rockchip"* ]] || [[ "$cpu_model" == *"RK"* ]]; then
            device_type="瑞芯微"
        elif [[ "$cpu_model" == *"Amlogic"* ]] || [[ "$cpu_model" == *"Meson"* ]]; then
            device_type="晶晨"
        elif [[ "$cpu_model" == *"MT"* ]] || [[ "$cpu_model" == *"MediaTek"* ]]; then
            device_type="联发科"
        elif [[ "$mem_total" != "未知" ]] && awk "BEGIN {exit !($mem_total <= 1)}"; then
            device_type="微控制器"
        fi
    else
        # x86/x64架构
        if [[ "$cpu_model" == *"Atom"* ]] || [[ "$cpu_model" == *"Celeron"* ]] || 
           [[ "$cpu_model" == *"J1900"* ]] || [[ "$cpu_model" == *"J3160"* ]] || 
           [[ "$cpu_model" == *"N"[0-9]"00"* ]]; then
            device_type="工控机"
        elif [[ "$cpu_model" == *"Xeon"* ]]; then
            device_type="服务器"
        elif [[ "$cpu_model" == *"QEMU"* ]] || [[ "$cpu_model" == *"Virtual"* ]]; then
            device_type="虚拟机"
        elif [[ "$mem_total" != "未知" ]] && awk "BEGIN {exit !($mem_total >= 64)}"; then
            device_type="高性能"
        elif [[ "$mem_total" != "未知" ]] && awk "BEGIN {exit !($mem_total <= 4)}"; then
            device_type="低配"
        fi
    fi
    
    # 根据磁盘类型进一步细分
    if [[ "$disk_type" == *"闪存"* ]] || [[ "$disk_type" == *"SD"* ]] || [[ "$disk_type" == *"eMMC"* ]]; then
        device_type="$device_type-闪存"
    elif [[ "$disk_type" == *"SSD"* ]] || [[ "$disk_type" == *"Solid"* ]]; then
        device_type="$device_type-SSD"
    elif [[ "$disk_type" == *"HDD"* ]] || [[ "$disk_type" == *"硬盘"* ]]; then
        device_type="$device_type-HDD"
    elif [[ "$disk_type" == *"NVMe"* ]]; then
        device_type="$device_type-NVMe"
    fi
    
    # 根据操作系统类型进一步细分
    if [[ "$os" == *"Linux"* ]] || [[ -z "$os" ]]; then
        if [[ "$distribution" == *"Ubuntu"* ]] || [[ "$distribution" == *"Debian"* ]] || 
           [[ "$distribution" == *"Raspbian"* ]]; then
            device_type="$device_type-Debian系"
        elif [[ "$distribution" == *"CentOS"* ]] || [[ "$distribution" == *"RedHat"* ]] || 
             [[ "$distribution" == *"Fedora"* ]]; then
            device_type="$device_type-RedHat系"
        elif [[ "$distribution" == *"Alpine"* ]]; then
            device_type="$device_type-Alpine"
        elif [[ "$distribution" == *"Arch"* ]] || [[ "$distribution" == *"Manjaro"* ]]; then
            device_type="$device_type-Arch系"
        fi
    elif [[ "$os" == *"BSD"* ]]; then
        device_type="$device_type-BSD"
    fi
    
    # 检测矿机
    local mining_detected=$(echo "$sys_info" | grep "^MiningDetected=" | cut -d'=' -f2)
    if [[ "$mining_detected" == "是"* ]]; then
        device_type="矿机-$device_type"
    fi
    
    echo "$device_type"
}

# 新版生成数据库名称函数
generate_db_name() {
    local sys_info="$1"
    local device_type=$(generate_device_type "$sys_info")
    local hostname=$(echo "$sys_info" | grep "^Hostname=" | cut -d'=' -f2)
    
    # 获取IP地址和国家代码
    local external_ip=$(echo "$sys_info" | grep "^ExternalIP=" | cut -d'=' -f2)
    local country_code=$(get_country_code "$external_ip")
    
    # 获取当前日期 - YYMMDD格式
    local date_ymd=$(date +"%y%m%d")
    
    # 如果国家代码为空，使用时区进行代替
    if [ -z "$country_code" ] || [ "$country_code" = "XX" ]; then
        # 尝试从时区获取地区信息
        if [ -f /etc/timezone ]; then
            local tz=$(cat /etc/timezone)
            local tz_region=$(echo "$tz" | cut -d'/' -f1 | cut -c1-2 | tr '[:lower:]' '[:upper:]')
            country_code="$tz_region"
        else
            country_code="UN" # 未知
        fi
    fi
    
    # 生成设备标识符和emoji部分
    local type_emoji=""
    case $device_type in
        *"矿机"*) type_emoji="⛏️" ;;
        *"路由器"*) type_emoji="📶" ;;
        *"树莓派"*) type_emoji="🍓" ;;
        *"全志"*) type_emoji="☀️" ;;
        *"瑞芯微"*) type_emoji="🔷" ;;
        *"晶晨"*) type_emoji="📺" ;;
        *"联发科"*) type_emoji="📱" ;;
        *"微控制器"*) type_emoji="🔌" ;;
        *"工控机"*) type_emoji="🏭" ;;
        *"服务器"*) type_emoji="🖥️" ;;
        *"虚拟机"*) type_emoji="👻" ;;
        *"高性能"*) type_emoji="🚀" ;;
        *"ARM"*) type_emoji="📱" ;;
        *"低配"*) type_emoji="🐢" ;;
    esac
    
    # 基于存储类型选择emoji
    local storage_emoji=""
    if [[ "$device_type" == *"-NVMe"* ]]; then
        storage_emoji="⚡"
    elif [[ "$device_type" == *"-SSD"* ]]; then
        storage_emoji="💫"
    elif [[ "$device_type" == *"-HDD"* ]]; then
        storage_emoji="💿"
    elif [[ "$device_type" == *"-闪存"* ]]; then
        storage_emoji="💾"
    fi
    
    # 组合得到最终的数据库名称
    echo "${device_type}-${country_code}-${date_ymd}-${hostname}${type_emoji}${storage_emoji}"
}

# 创建数据库
create_database() {
    local db_name="$1"
    local sys_info="$2"
    local endpoint="${NOTION_BASE_URL}/databases"
    local temp_file=$(create_temp_file)
    
    local json_data=$(json_create_db "$db_name")
    http_request "POST" "$endpoint" "$json_data" "$temp_file"
    
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "创建数据库失败，状态码: $HTTP_CODE, 响应: $BODY"
        exit 1
    fi
    
    local db_id=$(json_parse_id "$BODY")
    echo "成功创建数据库"
    
    echo "开始添加数据库条目..."
    local success_count=0
    local failed_count=0
    
    # 使用临时文件存储条目
    local entries_file=$(create_temp_file)
    echo "$sys_info" > "$entries_file"
    
    # 获取总条目数
    local total_count=$(grep -c "=" "$entries_file")
    
    # 逐行读取并添加条目
    local count=0
    while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            count=$((count + 1))
            printf "  [%02d/%02d] %-18s : %s" "$count" "$total_count" "$key" "$value"
            
            if add_database_entry "$db_id" "$key" "$value"; then
                success_count=$((success_count + 1))
                echo " [成功]"
            else
                failed_count=$((failed_count + 1))
                echo " [失败]"
            fi
            
            # 添加小延迟避免API限制
            sleep 0.3
        fi
    done < "$entries_file"
    
    echo "数据库条目添加完成，总计 $total_count 条，成功 $success_count 条，失败 $failed_count 条"
    echo "ID: $db_id"
}

# 添加数据库条目
add_database_entry() {
    local db_id="$1"
    local name="$2"
    local value="$3"
    local endpoint="${NOTION_BASE_URL}/pages"
    local temp_file=$(create_temp_file)
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        local json_data=$(json_create_entry "$db_id" "$name" "$value")
        http_request "POST" "$endpoint" "$json_data" "$temp_file"
        
        if [ "$HTTP_CODE" -eq 200 ]; then
            return 0
        elif [ "$HTTP_CODE" -eq 429 ]; then
            # 如果遇到限流，等待然后重试
            retry_count=$((retry_count + 1))
            sleep $((retry_count * 2))
        else
            # 其他错误，记录后返回失败
            echo "添加条目失败: $name, 状态码: $HTTP_CODE, 响应: $BODY" >&2
            return 1
        fi
    done
    
    echo "添加条目失败: $name, 重试 $max_retries 次后仍失败" >&2
    return 1
}

# 主函数
main() {
    TEMP_FILES=""
    test_api
    echo "运行探针..."
    local sys_info_raw=$(collect_system_info)
    
    # 添加设备类型标识
    local device_type=$(generate_device_type "$sys_info_raw")
    sys_info="$sys_info_raw"$'\n'"DeviceType=$device_type"
    
    echo "探针收集到的系统信息:"
    echo "$sys_info" | while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            printf "  %-18s : %s\n" "$key" "$value"
        fi
    done
    
    local db_name=$(generate_db_name "$sys_info")
    echo "创建数据库: $db_name"
    create_database "$db_name" "$sys_info"
    echo "操作完成"
    
    # 清理所有临时文件
    cleanup_temp_files
}

# 执行主函数
main
