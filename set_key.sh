#!/bin/bash

# SSH密钥登录配置脚本
# 从Backblaze B2或类似S3的公开存储桶获取公钥
# 包含回退选项，以防密钥登录失败

set -e

# 彩色输出函数
print_green() {
    echo -e "\033[0;32m$1\033[0m"
}

print_red() {
    echo -e "\033[0;31m$1\033[0m"
}

print_yellow() {
    echo -e "\033[0;33m$1\033[0m"
}

print_blue() {
    echo -e "\033[0;34m$1\033[0m"
}

# 检查是否以root用户运行
if [ "$(id -u)" -ne 0 ]; then
    print_red "请以root用户运行此脚本"
    exit 1
fi

# 备份SSH配置
backup_ssh_config() {
    print_yellow "备份当前SSH配置..."
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
    
    # 创建恢复脚本
    cat > /root/restore_ssh_config.sh << 'EOF'
#!/bin/bash
# 恢复SSH配置的脚本

# 获取最新的备份
LATEST_BACKUP=$(ls -t /etc/ssh/sshd_config.bak.* | head -n1)

if [ -z "$LATEST_BACKUP" ]; then
    echo "未找到SSH配置备份，无法恢复"
    exit 1
fi

echo "正在恢复SSH配置从: $LATEST_BACKUP"
cp "$LATEST_BACKUP" /etc/ssh/sshd_config
chmod 644 /etc/ssh/sshd_config

echo "重启SSH服务..."
systemctl restart sshd || service ssh restart

echo "SSH配置已恢复，密码登录应该已重新启用"
echo "如果您之前创建了新用户，该用户仍然存在"
EOF

    chmod +x /root/restore_ssh_config.sh
    print_green "已创建恢复脚本: /root/restore_ssh_config.sh"
}

# 主配置函数
configure_ssh_keys() {
    # 提示用户输入信息
    read -p "请输入公钥的完整URL (例如: https://f002.backblazeb2.com/file/bucket-name/id_rsa.pub): " PUBLIC_KEY_URL
    read -p "请输入要配置密钥登录的用户名: " USERNAME

    # 备份当前SSH配置
    backup_ssh_config

    # 检查curl是否安装
    if ! command -v curl &> /dev/null; then
        print_yellow "正在安装curl..."
        apt-get update
        apt-get install -y curl
    fi

    # 检查用户是否存在，如不存在则创建
    if ! id "$USERNAME" &>/dev/null; then
        print_yellow "用户 $USERNAME 不存在，正在创建..."
        useradd -m -s /bin/bash "$USERNAME"
        print_green "用户 $USERNAME 创建成功"
    fi

    # 确保用户的.ssh目录存在
    USER_HOME=$(eval echo ~$USERNAME)
    SSH_DIR="$USER_HOME/.ssh"
    mkdir -p "$SSH_DIR"

    # 下载公钥
    print_yellow "正在下载公钥..."
    curl -s "$PUBLIC_KEY_URL" -o "$SSH_DIR/authorized_keys" || {
        print_red "下载公钥失败，请检查URL是否正确"
        exit 1
    }

    # 验证下载的文件是否为有效的SSH公钥
    if ! grep -q "ssh-rsa\|ssh-ed25519\|ecdsa-sha2" "$SSH_DIR/authorized_keys"; then
        print_red "下载的文件不是有效的SSH公钥，请检查URL"
        cat "$SSH_DIR/authorized_keys"
        rm "$SSH_DIR/authorized_keys"
        exit 1
    fi

    print_green "成功下载公钥"

    # 设置正确的权限
    chown -R "$USERNAME":"$USERNAME" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"

    # 配置SSH服务
    print_yellow "配置SSH服务..."
    sed -i 's/#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

    # 重启SSH服务
    print_yellow "重启SSH服务..."
    systemctl restart sshd || service ssh restart

    print_green "SSH密钥登录配置完成！"
    print_yellow "重要提示: 请保持当前SSH会话开启，并在新窗口测试密钥登录"
    print_blue "测试命令: ssh $USERNAME@<服务器IP>"
    print_yellow "如果无法登录，请在此会话中运行以下命令恢复配置:"
    print_blue "    /root/restore_ssh_config.sh"
}

# 恢复函数
restore_ssh_config() {
    if [ -f /root/restore_ssh_config.sh ]; then
        print_yellow "正在恢复SSH配置..."
        /root/restore_ssh_config.sh
        print_green "SSH配置已恢复！密码登录应该已重新启用。"
    else
        print_red "未找到恢复脚本，无法自动恢复"
        print_yellow "您可以手动编辑 /etc/ssh/sshd_config 文件，将 PasswordAuthentication 设置为 yes"
        print_yellow "然后重启SSH服务: systemctl restart sshd 或 service ssh restart"
    fi
}

# 主菜单
show_menu() {
    echo ""
    print_blue "===== SSH密钥登录配置工具 ====="
    echo "1) 配置SSH密钥登录"
    echo "2) 恢复SSH配置（如果密钥登录测试失败）"
    echo "3) 退出"
    echo ""
    read -p "请选择操作 [1-3]: " choice

    case $choice in
        1) configure_ssh_keys ;;
        2) restore_ssh_config ;;
        3) exit 0 ;;
        *) print_red "无效选择，请重新输入" && show_menu ;;
    esac
}

# 显示主菜单
show_menu
