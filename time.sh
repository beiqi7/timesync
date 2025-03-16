#!/bin/bash

# 显示同步前的系统时间
echo "当前系统时间: $(date)"

# 确保ntpdate已安装
if ! command -v ntpdate &>/dev/null; then
    echo "正在安装ntpdate..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y ntpdate
    elif command -v yum &>/dev/null; then
        sudo yum install -y ntpdate
    else
        echo "无法安装ntpdate，请手动安装后再运行此脚本"
        exit 1
    fi
fi

# 停止ntpd服务(如果正在运行)
if systemctl is-active --quiet ntpd; then
    sudo systemctl stop ntpd
fi

# 同步时间
echo "正在同步时间..."
sudo ntpdate time.windows.com || sudo ntpdate time.nist.gov || sudo ntpdate pool.ntp.org

# 启动ntpd服务(如果已安装)
if command -v ntpd &>/dev/null; then
    sudo systemctl start ntpd &>/dev/null || sudo service ntpd start &>/dev/null || echo "无法启动ntpd服务"
fi

# 如果系统支持chronyd，则优先使用
if command -v chronyd &>/dev/null; then
    sudo systemctl restart chronyd &>/dev/null || sudo service chronyd restart &>/dev/null || echo "无法重启chronyd服务"
fi

# 设置硬件时钟
sudo hwclock --systohc

# 显示同步后的系统时间
echo "同步后系统时间: $(date)"
echo "时间同步完成!"
