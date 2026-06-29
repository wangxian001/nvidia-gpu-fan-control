#!/bin/bash
# =============================================================================
# NVIDIA GPU 智能温度管理系统 - 部署脚本
# 版本: 2026-06-30
# 用法: ./deploy.sh <服务器IP> [服务器用户名]
#       默认用户名: wangxian
# 示例: ./deploy.sh 192.168.2.167 wangxian
# =============================================================================

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "错误: 请指定服务器 IP 地址"
    echo "用法: $0 <服务器IP> [用户名]"
    echo "示例: $0 192.168.2.167 wangxian"
    exit 1
fi

SERVER_IP="$1"
SSH_USER="${2:-wangxian}"
SSH_DEST="${SSH_USER}@${SERVER_IP}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=============================================="
echo " NVIDIA GPU 智能温度管理系统 - 部署"
echo " 目标服务器: ${SSH_DEST}"
echo "=============================================="

# ==================== 步骤 1: 检查连接 ====================
echo ""
echo "[1/5] 检查 SSH 连接..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "${SSH_DEST}" "echo OK" 2>/dev/null; then
    echo "警告: SSH 连接需要密码，请确保已配置 SSH 密钥或准备好输入密码"
    echo "建议: ssh-copy-id ${SSH_DEST}"
    echo ""
fi

# ==================== 步骤 2: 上传文件 ====================
echo ""
echo "[2/5] 上传文件到服务器..."
# 创建远程目录
ssh "${SSH_DEST}" "sudo mkdir -p /home/fan_control/xdiag && sudo mkdir -p /home/fan_control/log"

# 部署核心文件
scp "${SCRIPT_DIR}/fan_control.sh"       "${SSH_DEST}:/tmp/fan_control.sh"
scp "${SCRIPT_DIR}/nvidia-fan-helper"    "${SSH_DEST}:/tmp/nvidia-fan-helper"
scp "${SCRIPT_DIR}/fan-control.service"  "${SSH_DEST}:/tmp/fan-control.service"
scp "${SCRIPT_DIR}/xdiag/xdiag.sh"       "${SSH_DEST}:/tmp/xdiag.sh"
scp "${SCRIPT_DIR}/xdiag/xdiag.service"  "${SSH_DEST}:/tmp/xdiag.service"

echo "  上传完成"

# ==================== 步骤 3: 安装（含备份） ====================
echo ""
echo "[3/5] 安装文件到目标位置（自动备份旧文件）..."
ssh "${SSH_DEST}" << 'INSTALL_EOF'
    BACKUP_SUFFIX=".bak_$(date +%Y%m%d_%H%M%S)"

    # fan_control.sh
    if [[ -f /home/fan_control/fan_control.sh ]]; then
        cp /home/fan_control/fan_control.sh "/home/fan_control/fan_control.sh${BACKUP_SUFFIX}"
        echo "  已备份 fan_control.sh → fan_control.sh${BACKUP_SUFFIX}"
    fi
    cp /tmp/fan_control.sh /home/fan_control/fan_control.sh
    chmod 755 /home/fan_control/fan_control.sh
    chown wangxian:wangxian /home/fan_control/fan_control.sh
    echo "  安装 fan_control.sh ✓"

    # nvidia-fan-helper
    if [[ -f /usr/local/bin/nvidia-fan-helper ]]; then
        cp /usr/local/bin/nvidia-fan-helper "/usr/local/bin/nvidia-fan-helper${BACKUP_SUFFIX}"
        echo "  已备份 nvidia-fan-helper → nvidia-fan-helper${BACKUP_SUFFIX}"
    fi
    cp /tmp/nvidia-fan-helper /usr/local/bin/nvidia-fan-helper
    chmod 755 /usr/local/bin/nvidia-fan-helper
    chown root:root /usr/local/bin/nvidia-fan-helper
    echo "  安装 nvidia-fan-helper ✓"

    # fan-control.service (user service)
    if [[ -f /home/wangxian/.config/systemd/user/fan-control.service ]]; then
        cp /home/wangxian/.config/systemd/user/fan-control.service \
           "/home/wangxian/.config/systemd/user/fan-control.service${BACKUP_SUFFIX}"
        echo "  已备份 fan-control.service → fan-control.service${BACKUP_SUFFIX}"
    fi
    mkdir -p /home/wangxian/.config/systemd/user
    cp /tmp/fan-control.service /home/wangxian/.config/systemd/user/fan-control.service
    chown wangxian:wangxian /home/wangxian/.config/systemd/user/fan-control.service
    echo "  安装 fan-control.service ✓"

    # xdiag 诊断脚本
    if [[ -f /home/fan_control/xdiag/xdiag.sh ]]; then
        cp /home/fan_control/xdiag/xdiag.sh "/home/fan_control/xdiag/xdiag.sh${BACKUP_SUFFIX}"
        echo "  已备份 xdiag.sh → xdiag.sh${BACKUP_SUFFIX}"
    fi
    cp /tmp/xdiag.sh /home/fan_control/xdiag/xdiag.sh
    chmod 755 /home/fan_control/xdiag/xdiag.sh
    chown wangxian:wangxian /home/fan_control/xdiag/xdiag.sh
    echo "  安装 xdiag.sh ✓"

    # xdiag.service (system service, 仅作为诊断工具保留)
    if [[ -f /etc/systemd/system/xdiag.service ]]; then
        cp /etc/systemd/system/xdiag.service "/etc/systemd/system/xdiag.service${BACKUP_SUFFIX}"
        echo "  已备份 xdiag.service → xdiag.service${BACKUP_SUFFIX}"
    fi
    sudo cp /tmp/xdiag.service /etc/systemd/system/xdiag.service
    sudo chmod 644 /etc/systemd/system/xdiag.service
    sudo chown root:root /etc/systemd/system/xdiag.service
    echo "  安装 xdiag.service ✓"

    # 清理临时文件
    rm -f /tmp/fan_control.sh /tmp/nvidia-fan-helper /tmp/fan-control.service /tmp/xdiag.sh /tmp/xdiag.service

INSTALL_EOF

echo "  全部安装完成"

# ==================== 步骤 4: 注册并启动服务 ====================
echo ""
echo "[4/5] 注册并启动 fan-control 服务..."
ssh "${SSH_DEST}" << 'SERVICE_EOF'
    # 重新加载 systemd --user 配置
    sudo -u wangxian -H XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload

    # 启用服务（开机自启）
    sudo -u wangxian -H XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable fan-control.service
    echo "  已启用 fan-control.service (开机自启)"

    # 重启服务
    sudo -u wangxian -H XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart fan-control.service
    echo "  已重启 fan-control.service"

    # 检查状态
    echo ""
    echo "  服务状态:"
    sudo -u wangxian -H XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status fan-control.service --no-pager | head -15
SERVICE_EOF

echo ""

# ==================== 步骤 5: 验证 ====================
echo ""
echo "[5/5] 验证服务..."
sleep 3
ssh "${SSH_DEST}" << 'VERIFY_EOF'
    # 检查进程
    if pgrep -f fan_control.sh >/dev/null 2>&1; then
        echo "  ✓ fan_control.sh 进程运行中"
    else
        echo "  ✗ fan_control.sh 进程未运行"
    fi

    # 检查日志
    if [[ -f /home/fan_control/fan_control.log ]]; then
        local last_log=$(tail -5 /home/fan_control/fan_control.log)
        if echo "$last_log" | grep -q "已启动"; then
            echo "  ✓ 服务启动成功"
            echo "  --- 最近日志 ---"
            tail -3 /home/fan_control/fan_control.log
        else
            echo "  ⚠ 日志存在但可能未完整启动:"
            tail -3 /home/fan_control/fan_control.log
        fi
    else
        echo "  ✗ 日志文件不存在"
    fi
VERIFY_EOF

echo ""
echo "=============================================="
echo " 部署完成"
echo ""
echo " 常用命令:"
echo "  查看状态:    systemctl --user status fan-control.service"
echo "  查看日志:    tail -f /home/fan_control/fan_control.log"
echo "  重启服务:    systemctl --user restart fan-control.service"
echo "  停止服务:    systemctl --user stop fan-control.service"
echo "  关闭自启:    systemctl --user disable fan-control.service"
echo ""
echo " 部署注意事项:"
echo "  1. 首次部署后需重启服务器以验证开机自启"
echo "  2. 服务器重启后, 服务会在开机 120 秒后自动启动"
echo "  3. 若需要修改风扇策略, 编辑 /home/fan_control/fan_control.sh 顶部的配置区"
echo "  4. 修改配置后执行: systemctl --user restart fan-control.service"
echo "  5. sudoers 配置(首次需要手动添加):"
echo "     wangxian ALL=(ALL) NOPASSWD: /usr/local/bin/nvidia-fan-helper"
echo "=============================================="
