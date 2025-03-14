#!/bin/bash

# 定义常量
NOTION_BASE_URL="https://api.notion.com/v1"
API_TOKEN="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"
PAGE_ID="1b5f54b30da880fab349cab11d90c65c"

# 检查依赖
command -v curl >/dev/null 2>&1 || { echo "错误: 需要安装 curl"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "错误: 需要安装 jq"; exit 1; }

# 测试 Notion API 可用性
test_api() {
    echo "测试 Notion API 可用性..."
    ENDPOINT="${NOTION_BASE_URL}/pages/${PAGE_ID}"
    RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$ENDPOINT" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Notion-Version: 2022-06-28" \
        -H "Content-Type: application/json")
    
    if [ "$RESPONSE" -ne 200 ]; then
        echo "API 测试失败，状态码: $RESPONSE"
        exit 1
    fi
    echo "API 测试成功！"
}

# 收集系统信息
collect_system_info() {
    # 基本信息
    OS=$(uname -s)
    ARCH=$(uname -m)
    CPUS=$(nproc)
    HOSTNAME=$(hostname)
    TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # 内存信息 (单位: MB)
    MEM_INFO=$(free -m | awk '/Mem:/ {print $2,$3,$4}')
    MEM_TOTAL=$(echo "$MEM_INFO" | cut -d' ' -f1)
    MEM_USED=$(echo "$MEM_INFO" | cut -d' ' -f2)
    MEM_FREE=$(echo "$MEM_INFO" | cut -d' ' -f3)
    MEM_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED / $MEM_TOTAL * 100)}")
    
    # 磁盘信息（根目录，单位: MB）
    DISK_INFO=$(df -m / | tail -1 | awk '{print $2,$3,$4}')
    DISK_TOTAL=$(echo "$DISK_INFO" | cut -d' ' -f1)
    DISK_USED=$(echo "$DISK_INFO" | cut -d' ' -f2)
    DISK_FREE=$(echo "$DISK_INFO" | cut -d' ' -f3)
    DISK_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($DISK_USED / $DISK_TOTAL * 100)}")
    
    # 转换为 GB
    MEM_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_TOTAL / 1024}")
    MEM_USED_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_USED / 1024}")
    DISK_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_TOTAL / 1024}")
    DISK_USED_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_USED / 1024}")
    
    # 输出 JSON 格式
    jq -n \
        --arg os "$OS" \
        --arg arch "$ARCH" \
        --arg cpus "$CPUS" \
        --arg hostname "$HOSTNAME" \
        --arg time "$TIME" \
        --arg mem_total "$MEM_TOTAL_GB GB" \
        --arg mem_used "$MEM_USED_GB GB" \
        --arg mem_percent "$MEM_PERCENT%" \
        --arg disk_total "$DISK_TOTAL_GB GB" \
        --arg disk_used "$DISK_USED_GB GB" \
        --arg disk_percent "$DISK_PERCENT%" \
        '{OS: $os, Architecture: $arch, CPUs: $cpus, Hostname: $hostname, Time: $time, MemoryTotal: $mem_total, MemoryUsed: $mem_used, MemoryPercent: $mem_percent, DiskTotal: $disk_total, DiskUsed: $disk_used, DiskPercent: $disk_percent}'
}

# 生成数据库名称
generate_db_name() {
    local sys_info=$1
    local hostname=$(echo "$sys_info" | jq -r '.Hostname')
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local cpus=$(echo "$sys_info" | jq -r '.CPUs')
    local mem_total=$(echo "$sys_info" | jq -r '.MemoryTotal' | cut -d' ' -f1)
    
    # CPU emoji
    if [ "$cpus" -le 4 ]; then
        cpu_emoji="🐢"
    elif [ "$cpus" -le 8 ]; then
        cpu_emoji="🐇"
    elif [ "$cpus" -le 16 ]; then
        cpu_emoji="🐎"
    else
        cpu_emoji="🚀"
    fi
    
    # 内存 emoji
    if (( $(echo "$mem_total <= 4" | bc -l) )); then
        mem_emoji="📀"
    elif (( $(echo "$mem_total <= 16" | bc -l) )); then
        mem_emoji="💾"
    elif (( $(echo "$mem_total <= 64" | bc -l) )); then
        mem_emoji="💿"
    else
        mem_emoji="🖥️"
    fi
    
    echo "Probe-${hostname}-${timestamp}${cpu_emoji}${mem_emoji}"
}

# 创建数据库
create_database() {
    local db_name=$1
    local sys_info=$2
    ENDPOINT="${NOTION_BASE_URL}/databases"
    
    # 构建 JSON 数据
    JSON_DATA=$(jq -n \
        --arg page_id "$PAGE_ID" \
        --arg db_name "$db_name" \
        '{parent: {type: "page_id", page_id: $page_id}, title: [{type: "text", text: {content: $db_name}}], properties: {Name: {title: {}}, Value: {rich_text: {}}}}')
    
    # 发送 POST 请求
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$ENDPOINT" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Notion-Version: 2022-06-28" \
        -H "Content-Type: application/json" \
        -d "$JSON_DATA")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "创建数据库失败，状态码: $HTTP_CODE, 响应: $BODY"
        exit 1
    fi
    
    DB_ID=$(echo "$BODY" | jq -r '.id')
    echo "$DB_ID"
    
    # 添加系统信息条目
    for key in $(echo "$sys_info" | jq -r 'keys[]'); do
        value=$(echo "$sys_info" | jq -r ".${key}")
        add_database_entry "$DB_ID" "$key" "$value"
    done
}

# 添加数据库条目
add_database_entry() {
    local db_id=$1
    local name=$2
    local value=$3
    ENDPOINT="${NOTION_BASE_URL}/pages"
    
    # 构建 JSON 数据
    JSON_DATA=$(jq -n \
        --arg db_id "$db_id" \
        --arg name "$name" \
        --arg value "$value" \
        '{parent: {database_id: $db_id}, properties: {Name: {title: [{text: {content: $name}}]}, Value: {rich_text: [{text: {content: $value}}]}}}')
    
    # 发送 POST 请求
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$ENDPOINT" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Notion-Version: 2022-06-28" \
        -H "Content-Type: application/json" \
        -d "$JSON_DATA")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "添加条目失败: $name, 状态码: $HTTP_CODE, 响应: $BODY"
    fi
}

# 主函数
main() {
    test_api
    SYS_INFO=$(collect_system_info)
    echo "探针收集到的系统信息: $SYS_INFO"
    DB_NAME=$(generate_db_name "$SYS_INFO")
    echo "创建数据库: $DB_NAME"
    DB_ID=$(create_database "$DB_NAME" "$SYS_INFO")
    echo "成功创建数据库，ID: $DB_ID"
}

# 执行主函数
main
