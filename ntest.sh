#!/bin/bash

# 定义常量
NOTION_BASE_URL="https://api.notion.com/v1"
API_TOKEN="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"
PAGE_ID="1b5f54b30da880fab349cab11d90c65c"

# 检查 HTTP 工具
if command -v curl >/dev/null 2>&1; then
    HTTP_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
    HTTP_TOOL="wget"
else
    echo "错误: 需要 curl 或 wget，请安装一种工具"
    exit 1
fi

# JSON 生成函数
json_create_db() {
    local db_name="$1"
    printf '{"parent":{"type":"page_id","page_id":"%s"},"title":[{"type":"text","text":{"content":"%s"}}],"properties":{"Name":{"title":{}},"Value":{"rich_text":{}}}}' "$PAGE_ID" "$db_name"
}

json_create_entry() {
    local db_id="$1"
    local name="$2"
    local value="$3"
    printf '{"parent":{"database_id":"%s"},"properties":{"Name":{"title":[{"type":"text","text":{"content":"%s"}}]},"Value":{"rich_text":[{"type":"text","text":{"content":"%s"}}]}}}' "$db_id" "$name" "$value"
}

# JSON 解析函数（提取 ID）
json_parse_id() {
    local response="$1"
    echo "$response" | grep -o '"id":"[^"]*' | head -1 | cut -d'"' -f4
}

# HTTP 请求函数
http_request() {
    local method="$1"
    local url="$2"
    local data="$3"
    local output_file="$4"
    
    if [ "$HTTP_TOOL" = "curl" ]; then
        HTTP_CODE=$(curl -s -o "$output_file" -w "%{http_code}" -X "$method" "$url" \
            -H "Authorization: Bearer $API_TOKEN" \
            -H "Notion-Version: 2022-06-28" \
            -H "Content-Type: application/json" \
            -d "$data")
        BODY=$(cat "$output_file")
    else
        wget --method="$method" --header="Authorization: Bearer $API_TOKEN" \
            --header="Notion-Version: 2022-06-28" \
            --header="Content-Type: application/json" \
            --body-data="$data" -O "$output_file" "$url" >/dev/null 2>&1
        HTTP_CODE=$([ $? -eq 0 ] && echo "200" || echo "500")
        BODY=$(cat "$output_file")
    fi
}

# 测试 API 可用性
test_api() {
    echo "测试 Notion API 可用性..."
    local endpoint="${NOTION_BASE_URL}/pages/${PAGE_ID}"
    local temp_file=$(mktemp)
    
    http_request "GET" "$endpoint" "" "$temp_file"
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "API 测试失败，状态码: $HTTP_CODE, 响应: $BODY"
        rm -f "$temp_file"
        exit 1
    fi
    echo "API 测试成功！"
    rm -f "$temp_file"
}

# 收集系统信息（新增用户权限）
collect_system_info() {
    local os=$(uname -s)
    local arch=$(uname -m)
    local cpus=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "1")
    local hostname=$(hostname 2>/dev/null || echo "unknown")
    local time=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
    
    local mem_total="N/A"
    local mem_used="N/A"
    local mem_percent="N/A"
    if [ -f /proc/meminfo ]; then
        local mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        local mem_free_kb=$(awk '/MemFree/ {print $2}' /proc/meminfo)
        local mem_used_kb=$((mem_total_kb - mem_free_kb))
        mem_total=$(awk "BEGIN {printf \"%.1f\", $mem_total_kb / 1024 / 1024}")
        mem_used=$(awk "BEGIN {printf \"%.1f\", $mem_used_kb / 1024 / 1024}")
        mem_percent=$(awk "BEGIN {printf \"%.1f\", ($mem_used_kb / $mem_total_kb * 100)}")
    fi
    
    local disk_total="N/A"
    local disk_used="N/A"
    local disk_percent="N/A"
    local disk_info=$(df -m / 2>/dev/null | tail -1 | awk '{print $2,$3}')
    if [ -n "$disk_info" ]; then
        local disk_total_mb=$(echo "$disk_info" | cut -d' ' -f1)
        local disk_used_mb=$(echo "$disk_info" | cut -d' ' -f2)
        disk_total=$(awk "BEGIN {printf \"%.1f\", $disk_total_mb / 1024}")
        disk_used=$(awk "BEGIN {printf \"%.1f\", $disk_used_mb / 1024}")
        disk_percent=$(awk "BEGIN {printf \"%.1f\", ($disk_used_mb / $disk_total_mb * 100)}")
    fi
    
    # 收集用户权限
    local user_privileges
    local uid=$(id -u 2>/dev/null || echo "unknown")
    if [ "$uid" = "0" ]; then
        user_privileges="root"
    else
        local username=$(id -un 2>/dev/null || echo "$USER")
        local groups=$(id -Gn 2>/dev/null || echo "unknown")
        user_privileges="$username (UID: $uid, Groups: $groups)"
    fi
    
    printf "OS=%s\nArchitecture=%s\nCPUs=%s\nHostname=%s\nTime=%s\nMemoryTotal=%s GB\nMemoryUsed=%s GB\nMemoryPercent=%s%%\nDiskTotal=%s GB\nDiskUsed=%s GB\nDiskPercent=%s%%\nUserPrivileges=%s" \
        "$os" "$arch" "$cpus" "$hostname" "$time" "$mem_total" "$mem_used" "$mem_percent" "$disk_total" "$disk_used" "$disk_percent" "$user_privileges"
}

# 生成数据库名称
generate_db_name() {
    local sys_info="$1"
    local hostname=$(echo "$sys_info" | grep "^Hostname=" | cut -d'=' -f2)
    local timestamp=$(date +"%Y%m%d-%H%M%S")
    local cpus=$(echo "$sys_info" | grep "^CPUs=" | cut -d'=' -f2)
    local mem_total=$(echo "$sys_info" | grep "^MemoryTotal=" | cut -d'=' -f2 | cut -d' ' -f1)
    
    local cpu_emoji
    case $cpus in
        [0-4]) cpu_emoji="🐢" ;;
        [5-8]) cpu_emoji="🐇" ;;
        9|1[0-6]) cpu_emoji="🐎" ;;
        *) cpu_emoji="🚀" ;;
    esac
    
    local mem_emoji
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
    
    printf "Probe-%s-%s%s%s" "$hostname" "$timestamp" "$cpu_emoji" "$mem_emoji"
}

# 创建数据库
create_database() {
    local db_name="$1"
    local sys_info="$2"
    local endpoint="${NOTION_BASE_URL}/databases"
    local temp_file=$(mktemp)
    
    local json_data=$(json_create_db "$db_name")
    http_request "POST" "$endpoint" "$json_data" "$temp_file"
    
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "创建数据库失败，状态码: $HTTP_CODE, 响应: $BODY"
        rm -f "$temp_file"
        exit 1
    fi
    
    local db_id=$(json_parse_id "$BODY")
    echo "成功创建数据库"
    rm -f "$temp_file"
    
    echo "开始添加数据库条目..."
    local entry_count=0
    local failed_count=0
    echo "$sys_info" | while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            entry_count=$((entry_count + 1))
            printf "  [%02d] %-12s : %s" "$entry_count" "$key" "$value"
            if add_database_entry "$db_id" "$key" "$value"; then
                echo " [成功]"
            else
                failed_count=$((failed_count + 1))
                echo " [失败]"
            fi
        fi
    done
    
    echo "数据库条目添加完成，总计 $entry_count 条，成功 $((entry_count - failed_count)) 条，失败 $failed_count 条"
    echo "ID: $db_id"
}

# 添加数据库条目（返回 0 表示成功，1 表示失败）
add_database_entry() {
    local db_id="$1"
    local name="$2"
    local value="$3"
    local endpoint="${NOTION_BASE_URL}/pages"
    local temp_file=$(mktemp)
    
    local json_data=$(json_create_entry "$db_id" "$name" "$value")
    http_request "POST" "$endpoint" "$json_data" "$temp_file"
    
    if [ "$HTTP_CODE" -ne 200 ]; then
        echo "添加条目失败: $name, 状态码: $HTTP_CODE, 响应: $BODY" >&2
        rm -f "$temp_file"
        return 1
    fi
    rm -f "$temp_file"
    return 0
}

# 主函数
main() {
    test_api
    echo "运行探针..."
    local sys_info=$(collect_system_info)
    echo "探针收集到的系统信息:"
    echo "$sys_info" | while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            printf "  %-12s : %s\n" "$key" "$value"
        fi
    done
    local db_name=$(generate_db_name "$sys_info")
    echo "创建数据库: $db_name"
    create_database "$db_name" "$sys_info"
    echo "操作完成"
}

# 执行主函数
main
