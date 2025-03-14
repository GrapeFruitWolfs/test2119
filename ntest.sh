#!/bin/bash

# 定义常量
NOTION_BASE_URL="https://api.notion.com/v1"
API_TOKEN="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"
PAGE_ID="1b5f54b30da880fab349cab11d90c65c"

# 检查工具并设置模式
USE_CURL_JQ=1
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "警告: curl 或 jq 未安装，尝试使用 wget 和基础方法"
    if ! command -v wget >/dev/null 2>&1; then
        echo "错误: 需要 curl 或 wget，请至少安装一种工具"
        exit 1
    fi
    USE_CURL_JQ=0
fi

# 测试 Notion API 可用性
test_api() {
    echo "测试 Notion API 可用性..."
    ENDPOINT="${NOTION_BASE_URL}/pages/${PAGE_ID}"
    
    if [ "$USE_CURL_JQ" -eq 1 ]; then
        RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$ENDPOINT" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Notion-Version: 2022-06-28" \
            -H "Content-Type: application/json")
    else
        RESPONSE=$(wget -q --method=GET --header="Authorization: Bearer $API_TOKEN" \
            --header="Notion-Version: 2022-06-28" \
            --header="Content-Type: application/json" \
            -O - "$ENDPOINT" >/dev/null 2>&1 && echo "200" || echo "500")
    fi
    
    if [ "$RESPONSE" -ne 200 ]; then
        echo "API 测试失败，状态码: $RESPONSE"
        exit 1
    fi
    echo "API 测试成功！"
}

# 收集系统信息
collect_system_info() {
    OS=$(uname -s)
    ARCH=$(uname -m)
    CPUS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1")
    HOSTNAME=$(hostname 2>/dev/null || echo "unknown")
    TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
    
    # 内存信息（单位: MB）
    if [ -f /proc/meminfo ]; then
        MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo) # KB
        MEM_FREE=$(awk '/MemFree/ {print $2}' /proc/meminfo)   # KB
        MEM_USED=$((MEM_TOTAL - MEM_FREE))
        MEM_TOTAL_MB=$((MEM_TOTAL / 1024))
        MEM_USED_MB=$((MEM_USED / 1024))
        MEM_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($MEM_USED / $MEM_TOTAL * 100)}")
    else
        MEM_TOTAL_MB="N/A"
        MEM_USED_MB="N/A"
        MEM_PERCENT="N/A"
    fi
    
    # 磁盘信息（根目录，单位: MB）
    DISK_INFO=$(df -m / 2>/dev/null | tail -1 | awk '{print $2,$3,$4}')
    if [ -n "$DISK_INFO" ]; then
        DISK_TOTAL=$(echo "$DISK_INFO" | cut -d' ' -f1)
        DISK_USED=$(echo "$DISK_INFO" | cut -d' ' -f2)
        DISK_FREE=$(echo "$DISK_INFO" | cut -d' ' -f3)
        DISK_PERCENT=$(awk "BEGIN {printf \"%.1f\", ($DISK_USED / $DISK_TOTAL * 100)}")
    else
        DISK_TOTAL="N/A"
        DISK_USED="N/A"
        DISK_PERCENT="N/A"
    fi
    
    # 转换为 GB
    if [ "$MEM_TOTAL_MB" != "N/A" ]; then
        MEM_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_TOTAL_MB / 1024}")
        MEM_USED_GB=$(awk "BEGIN {printf \"%.1f\", $MEM_USED_MB / 1024}")
    else
        MEM_TOTAL_GB="N/A"
        MEM_USED_GB="N/A"
    fi
    if [ "$DISK_TOTAL" != "N/A" ]; then
        DISK_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_TOTAL / 1024}")
        DISK_USED_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_USED / 1024}")
    else
        DISK_TOTAL_GB="N/A"
        DISK_USED_GB="N/A"
    fi
    
    # 输出格式化信息
    SYS_INFO="OS=$OS\nArchitecture=$ARCH\nCPUs=$CPUS\nHostname=$HOSTNAME\nTime=$TIME\nMemoryTotal=$MEM_TOTAL_GB GB\nMemoryUsed=$MEM_USED_GB GB\nMemoryPercent=$MEM_PERCENT%\nDiskTotal=$DISK_TOTAL_GB GB\nDiskUsed=$DISK_USED_GB GB\nDiskPercent=$DISK_PERCENT%"
    echo "$SYS_INFO"
}

# 生成数据库名称
generate_db_name() {
    local sys_info=$1
    local hostname=$(echo "$sys_info" | grep "^Hostname=" | cut -d'=' -f2)
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local cpus=$(echo "$sys_info" | grep "^CPUs=" | cut -d'=' -f2)
    local mem_total=$(echo "$sys_info" | grep "^MemoryTotal=" | cut -d'=' -f2 | cut -d' ' -f1)
    
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
    if [ "$mem_total" = "N/A" ] || [ -z "$mem_total" ]; then
        mem_emoji="📀"
    elif awk "BEGIN {exit !($mem_total <= 4)}"; then
        mem_emoji="📀"
    elif awk "BEGIN {exit !($mem_total <= 16)}"; then
        mem_emoji="💾"
    elif awk "BEGIN {exit !($mem_total <= 64)}"; then
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
    if [ "$USE_CURL_JQ" -eq 1 ]; then
        JSON_DATA=$(jq -n \
            --arg page_id "$PAGE_ID" \
            --arg db_name "$db_name" \
            '{parent: {type: "page_id", page_id: $page_id}, title: [{type: "text", text: {content: $db_name}}], properties: {Name: {title: {}}, Value: {rich_text: {}}}}')
    else
        JSON_DATA='{"parent":{"type":"page_id","page_id":"'"$PAGE_ID"'"},"title":[{"type":"text","text":{"content":"'"$db_name"'"}}],"properties":{"Name":{"title":{}},"Value":{"rich_text":{}}}}'
    fi
    
    # 发送 POST 请求
    TEMP_FILE=$(mktemp)
    if [ "$USE_CURL_JQ" -eq 1 ]; then
        RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$ENDPOINT" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Notion-Version: 2022-06-28" \
            -H "Content-Type: application/json" \
            -d "$JSON_DATA")
    else
        RESPONSE=$(wget --method=POST --header="Authorization: Bearer $API_TOKEN" \
            --header="Notion-Version: 2022-06-28" \
            --header="Content-Type: application/json" \
            --body-data="$JSON_DATA" \
            -O "$TEMP_FILE" "$ENDPOINT" >/dev/null 2>&1 && echo "200" || echo "500")
        RESPONSE="$RESPONSE\n$(cat "$TEMP_FILE")"
    fi
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "创建数据库失败，状态码: $HTTP_CODE, 响应: $BODY"
        rm -f "$TEMP_FILE"
        exit 1
    fi
    
    # 提取数据库 ID
    if [ "$USE_CURL_JQ" -eq 1 ]; then
        DB_ID=$(echo "$BODY" | jq -r '.id')
    else
        DB_ID=$(echo "$BODY" | grep -o '"id":"[^"]*' | cut -d'"' -f4)
    fi
    rm -f "$TEMP_FILE"
    echo "$DB_ID"
    
    # 添加系统信息条目
    echo "$sys_info" | while IFS= read -r line; do
        key=$(echo "$line" | cut -d'=' -f1)
        value=$(echo "$line" | cut -d'=' -f2-)
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
    if [ "$USE_CURL_JQ" -eq 1 ]; then
        JSON_DATA=$(jq -n \
            --arg db_id "$db_id" \
            --arg name "$name" \
            --arg value "$value" \
            '{parent: {database_id: $db_id}, properties: {Name: {title: [{text: {content: $name}}]}, Value: {rich_text: [{text: {content: $value}}]}}}')
    else
        JSON_DATA='{"parent":{"database_id":"'"$db_id"'"},"properties":{"Name":{"title":[{"text":{"content":"'"$name"'"}}]},"Value":{"rich_text":[{"text":{"content":"'"$value"'"}}}]}}'
    fi
    
    # 发送 POST 请求
    TEMP_FILE=$(mktemp)
    if [ "$USE_CURL_JQ" -eq 1 ]; then
        RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$ENDPOINT" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Notion-Version: 2022-06-28" \
            -H "Content-Type: application/json" \
            -d "$JSON_DATA")
    else
        RESPONSE=$(wget --method=POST --header="Authorization: Bearer $API_TOKEN" \
            --header="Notion-Version: 2022-06-28" \
            --header="Content-Type: application/json" \
            --body-data="$JSON_DATA" \
            -O "$TEMP_FILE" "$ENDPOINT" >/dev/null 2>&1 && echo "200" || echo "500")
        RESPONSE="$RESPONSE\n$(cat "$TEMP_FILE")"
    fi
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "添加条目失败: $name, 状态码: $HTTP_CODE, 响应: $BODY"
    fi
    rm -f "$TEMP_FILE"
}

# 主函数
main() {
    test_api
    SYS_INFO=$(collect_system_info)
    echo "探针收集到的系统信息:"
    echo "$SYS_INFO"
    DB_NAME=$(generate_db_name "$SYS_INFO")
    echo "创建数据库: $DB_NAME"
    DB_ID=$(create_database "$DB_NAME" "$SYS_INFO")
    echo "成功创建数据库，ID: $DB_ID"
}

# 执行主函数
main
