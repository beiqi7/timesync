#!/bin/bash

# 显示同步前的系统时间
echo "当前系统时间: $(date)"
echo "正在同步时间..."

# 等待apt锁释放的函数
wait_for_apt() {
    local max_wait=300  # 最多等待300秒
    local wait_time=0
    
    echo "检查apt锁状态..."
    
    while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1 || lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [ "$wait_time" -gt "$max_wait" ]; then
            echo "等待apt锁释放超时，请手动检查系统中的apt进程"
            ps aux | grep -i apt
            return 1
        fi
        
        echo "另一个apt进程正在运行，等待锁释放... ($wait_time 秒)"
        sleep 5
        wait_time=$((wait_time+5))
    done
    
    return 0
}

# 确保ntpdate已安装
if ! command -v ntpdate &>/dev/null; then
    echo "正在安装ntpdate..."
    
    # 等待apt锁释放
    if wait_for_apt; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y ntpdate
        elif command -v yum &>/dev/null; then
            sudo yum install -y ntpdate
        else
            echo "无法安装ntpdate，请手动安装后再运行此脚本"
            exit 1
        fi
    else
        # 尝试使用备选方法同步时间
        echo "无法安装ntpdate，尝试其他方式同步时间..."
        if command -v date &>/dev/null && curl --version >/dev/null 2>&1; then
            # 使用curl获取网络时间
            echo "使用HTTP时间同步..."
            TIME_SERVER="http://worldtimeapi.org/api/ip"
            CURRENT_TIME=$(curl -s $TIME_SERVER | grep -oP '(?<="datetime":")[^"]*' | cut -d'.' -f1)
            if [ ! -z "$CURRENT_TIME" ]; then
                sudo date -s "$CURRENT_TIME"
                echo "使用HTTP API同步时间成功"
            else
                echo "HTTP时间同步失败"
            fi
        fi
    fi
fi

# 停止ntpd服务(如果正在运行)
if systemctl is-active --quiet ntpd 2>/dev/null; then
    sudo systemctl stop ntpd
fi

# 同步时间 - 尝试多种方法
if command -v ntpdate &>/dev/null; then
    # 使用ntpdate同步
    sudo ntpdate time.windows.com || sudo ntpdate time.nist.gov || sudo ntpdate pool.ntp.org
elif command -v chronyd &>/dev/null; then
    # 使用chronyd同步
    sudo chronyd -q 'server time.windows.com iburst'
elif command -v timedatectl &>/dev/null; then
    # 使用timedatectl同步
    sudo timedatectl set-ntp true
    sleep 2
    sudo timedatectl set-ntp false
    sudo timedatectl set-ntp true
fi

# 启动ntpd服务(如果已安装)
if command -v ntpd &>/dev/null; then
    sudo systemctl start ntpd &>/dev/null || sudo service ntpd start &>/dev/null || echo "无法启动ntpd服务"
fi

# 如果系统支持chronyd，则优先使用
if command -v chronyd &>/dev/null; then
    sudo systemctl restart chronyd &>/dev/null || sudo service chronyd restart &>/dev/null || echo "无法重启chronyd服务"
fi

# 设置硬件时钟
if command -v hwclock &>/dev/null; then
    sudo hwclock --systohc
fi

# 显示同步后的系统时间
echo "同步后系统时间: $(date)"
echo "时间同步完成!"

# =================== 添加日志清理功能 ===================
echo "开始清理系统日志..."

# 清理系统日志目录 - 只包含实际存在的目录
LOG_DIRS=()
for dir in "/var/log" "/var/adm" "/var/spool/mail"; do
    if [ -d "$dir" ]; then
        LOG_DIRS+=("$dir")
    fi
done

# 清理多少天前的日志
DAYS_TO_KEEP=7
# 日志文件扩展名模式
LOG_PATTERNS=("*.log" "*.log.*" "*.gz" "*.old" "*.1" "*.2" "*.3" "*.4" "*.5")

# 创建清理记录
CLEANUP_LOG="/var/log/timesync_cleanup.log"
echo "===== 日志清理开始于 $(date) =====" >> $CLEANUP_LOG

# 检查磁盘使用率
check_disk_usage() {
    local dir=$1
    local threshold=80  # 当使用率超过80%时清理
    
    # 检查目录是否存在
    if [ ! -d "$dir" ]; then
        echo "目录 $dir 不存在，跳过" >> $CLEANUP_LOG
        return 1
    fi
    
    # 获取目录所在磁盘的使用率
    local usage=$(df -h "$dir" | awk 'NR==2 {print $5}' | sed 's/%//')
    
    # 确保usage是一个数字
    if [[ "$usage" =~ ^[0-9]+$ ]]; then
        if [ "$usage" -gt "$threshold" ]; then
            echo "磁盘使用率: ${usage}%, 高于阈值 ${threshold}%, 需要清理" >> $CLEANUP_LOG
            return 0
        else
            echo "磁盘使用率: ${usage}%, 低于阈值 ${threshold}%, 无需清理" >> $CLEANUP_LOG
            return 1
        fi
    else
        echo "无法获取 $dir 的磁盘使用率，默认执行清理" >> $CLEANUP_LOG
        return 0  # 默认执行清理
    fi
}

# 清理指定目录中的日志文件
cleanup_logs() {
    local dir=$1
    local days=$2
    local count=0
    local size_before=0
    local size_after=0
    
    # 检查目录是否存在
    if [ ! -d "$dir" ]; then
        echo "目录 $dir 不存在，跳过" >> $CLEANUP_LOG
        return
    fi
    
    # 获取清理前的目录大小
    size_before=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    
    echo "清理 $dir 中 $days 天前的日志文件..." >> $CLEANUP_LOG
    
    # 清理各种日志文件
    for pattern in "${LOG_PATTERNS[@]}"; do
        local files=$(find "$dir" -type f -name "$pattern" -mtime +"$days" 2>/dev/null)
        for file in $files; do
            if [ -f "$file" ]; then  # 确保文件存在
                echo "删除文件: $file" >> $CLEANUP_LOG
                rm -f "$file" 2>/dev/null
                if [ $? -eq 0 ]; then
                    count=$((count+1))
                fi
            fi
        done
    done
    
    # 获取清理后的目录大小
    size_after=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    
    echo "已清理 $dir: 删除了 $count 个文件，目录大小从 $size_before 变为 $size_after" >> $CLEANUP_LOG
}

# 清理常见日志文件
for dir in "${LOG_DIRS[@]}"; do
    if check_disk_usage "$dir"; then
        cleanup_logs "$dir" $DAYS_TO_KEEP
    fi
done

# 清理特定应用程序日志
# 检查并清理应用程序日志目录
APP_LOG_DIRS=()
for pattern in "/opt/logs" "/var/www/logs" "/usr/local/logs" "/home/*/logs"; do
    for dir in $(find / -path "$pattern" -type d 2>/dev/null); do
        if [ -d "$dir" ]; then
            APP_LOG_DIRS+=("$dir")
        fi
    done
done

for dir in "${APP_LOG_DIRS[@]}"; do
    if check_disk_usage "$dir"; then
        cleanup_logs "$dir" $DAYS_TO_KEEP
    fi
done

# 处理journal日志（如果系统使用systemd）
if [ -d "/var/log/journal" ]; then
    echo "清理systemd journal日志..." >> $CLEANUP_LOG
    if check_disk_usage "/var/log/journal"; then
        journalctl --vacuum-time="${DAYS_TO_KEEP}d" >> $CLEANUP_LOG 2>&1
        echo "已清理 journal 日志" >> $CLEANUP_LOG
    fi
fi

# 清除空的日志文件
for dir in "${LOG_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        find "$dir" -type f -name "*.log" -size 0 -delete 2>/dev/null
    fi
done

# 压缩大型日志文件但保留它们
for dir in "${LOG_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        find "$dir" -type f -name "*.log" -size +50M -not -name "*.gz" -exec gzip {} \; 2>/dev/null
    fi
done

echo "===== 日志清理结束于 $(date) =====" >> $CLEANUP_LOG

# 只保留最近10次的清理日志记录
if [ -f "$CLEANUP_LOG" ]; then
    tail -n 1000 "$CLEANUP_LOG" > "${CLEANUP_LOG}.tmp" && mv "${CLEANUP_LOG}.tmp" "$CLEANUP_LOG"
fi

echo "日志清理完成! 详细信息记录在 $CLEANUP_LOG"
