#!/bin/bash

# 定义常量
NOTION_BASE_URL="https://api.notion.com/v1"
API_TOKEN="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"
PAGE_ID="1b5f54b30da880fab349cab11d90c65c"

# 测试 Notion API 可用性
test_api() {
    echo "测试 Notion API 可用性..."
    ENDPOINT="${NOTION_BASE_URL}/pages/${PAGE_ID}"
    
    # 使用 wget 替代 curl
    wget -q -O /tmp/api_test --header="Authorization: Bearer $API_TOKEN" \
        --header="Notion-Version: 2022-06-28" \
        --header="Content-Type: application/json" "$ENDPOINT" 2>/tmp/wget_err
    STATUS=$?
    
    if [ $STATUS -ne 0 ]; then
        echo "API 测试失败，错误: $(cat /tmp/wget_err)"
        rm -f /tmp/api_test /tmp/wget_err
        exit 1
    fi
    echo "API 测试成功！"
    rm -f /tmp/api_test /tmp/wget_err
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
    
    # 使用 heredoc 创建 JSON 字符串，不依赖 jq
    cat << EOF > /tmp/sys_info.json
{
    "OS": "$OS",
    "Architecture": "$ARCH",
    "CPUs": "$CPUS",
    "Hostname": "$HOSTNAME",
    "Time": "$TIME",
    "MemoryTotal": "$MEM_TOTAL_GB GB",
    "MemoryUsed": "$MEM_USED_GB GB",
    "MemoryPercent": "$MEM_PERCENT%",
    "DiskTotal": "$DISK_TOTAL_GB GB",
    "DiskUsed": "$DISK_USED_GB GB",
    "DiskPercent": "$DISK_PERCENT%"
}
EOF
}

# 生成数据库名称
generate_db_name() {
    local hostname=$(awk -F'"' '/Hostname/ {print $4}' /tmp/sys_info.json)
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local cpus=$(awk -F'"' '/CPUs/ {print $4}' /tmp/sys_info.json)
    local mem_total=$(awk -F'"' '/MemoryTotal/ {print $4}' /tmp/sys_info.json | cut -d' ' -f1)
    
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
    if [ "$(echo "$mem_total <= 4" | bc)" -eq 1 ]; then
        mem_emoji="📀"
    elif [ "$(echo "$mem_total <= 16" | bc)" -eq 1 ]; then
        mem_emoji="💾"
    elif [ "$(echo "$mem_total <= 64" | bc)" -eq 1 ]; then
        mem_emoji="💿"
    else
        mem_emoji="🖥️"
    fi
    
    echo "Probe-${hostname}-${timestamp}${cpu_emoji}${mem_emoji}"
}

# 创建数据库
create_database() {
    local db_name=$1
    ENDPOINT="${NOTION_BASE_URL}/databases"
    
    # 构建 JSON 数据
    cat << EOF > /tmp/db_create.json
{
    "parent": {"type": "page_id", "page_id": "$PAGE_ID"},
    "title": [{"type": "text", "text": {"content": "$db_name"}}],
    "properties": {
        "Name": {"title": {}},
        "Value": {"rich_text": {}}
    }
}
EOF
    
    # 使用 wget 发送 POST 请求
    wget -q -O /tmp/db_response --header="Authorization: Bearer $API_TOKEN" \
        --header="Notion-Version: 2022-06-28" \
        --header="Content-Type: application/json" \
        --post-file=/tmp/db_create.json "$ENDPOINT" 2>/tmp/wget_err
    STATUS=$?
    
    if [ $STATUS -ne 0 ]; then
        echo "创建数据库失败，错误: $(cat /tmp/wget_err)"
        rm -f /tmp/db_create.json /tmp/db_response /tmp/wget_err
        exit 1
    fi
    
    # 提取数据库 ID
    DB_ID=$(awk -F'"' '/"id":/ {print $4}' /tmp/db_response)
    echo "$DB_ID"
    
    # 添加系统信息条目
    while IFS= read -r line; do
        if echo "$line" | grep -q '": "'; then
            key=$(echo "$line" | cut -d'"' -f2)
            value=$(echo "$line" | cut -d'"' -f4)
            add_database_entry "$DB_ID" "$key" "$value"
        fi
    done < /tmp/sys_info.json
    
    rm -f /tmp/db_create.json /tmp/db_response /tmp/wget_err
}

# 添加数据库条目
add_database_entry() {
    local db_id=$1
    local name=$2
    local value=$3
    ENDPOINT="${NOTION_BASE_URL}/pages"
    
    # 构建 JSON 数据
    cat << EOF > /tmp/entry_create.json
{
    "parent": {"database_id": "$db_id"},
    "properties": {
        "Name": {"title": [{"text": {"content": "$name"}}]},
        "Value": {"rich_text": [{"text": {"content": "$value"}}]}
    }
}
EOF
    
    # 发送 POST 请求
    wget -q -O /tmp/entry_response --header="Authorization: Bearer $API_TOKEN" \
        --header="Notion-Version: 2022-06-28" \
        --header="Content-Type: application/json" \
        --post-file=/tmp/entry_create.json "$ENDPOINT" 2>/tmp/wget_err
    
    rm -f /tmp/entry_create.json /tmp/entry_response /tmp/wget_err
}

# 主函数
main() {
    test_api
    collect_system_info
    echo "探针收集到的系统信息:"
    cat /tmp/sys_info.json
    DB_NAME=$(generate_db_name)
    echo "创建数据库: $DB_NAME"
    DB_ID=$(create_database "$DB_NAME")
    echo "成功创建数据库，ID: $DB_ID"
    rm -f /tmp/sys_info.json
}

# 执行主函数
main
