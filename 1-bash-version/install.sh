#!/bin/bash
# ====================================================
# NVIDIA GPU 智能温度管理系统 - Bash 版本安装脚本
# 版本: V2.1 (智能 X 服务检测)
# 日期: 2026-01-20
# ====================================================

set -e

echo "=========================================="
echo "NVIDIA GPU 智能温度管理系统 - Bash 版"
echo "版本: V2.1 (智能 X 服务检测)"
echo "=========================================="
echo ""

# 检查是否以 root 身份运行
if [[ $EUID -eq 0 ]]; then
   echo "❌ 错误: 请不要以 root 身份运行此脚本"
   echo "   正确用法: bash install.sh"
   exit 1
fi

CURRENT_USER=$(whoami)
echo "✓ 当前用户: $CURRENT_USER"

# 检查系统环境
echo ""
echo "步骤 1/7: 检查系统环境..."

# 检查 Bash 版本
BASH_VERSION_NUM=$(bash --version | head -n1 | grep -oP '\d+\.\d+' | head -n1)
echo "✓ Bash 版本: $BASH_VERSION_NUM"

# 检查 NVIDIA 驱动
if ! command -v nvidia-smi &> /dev/null; then
    echo "❌ 错误: 未检测到 nvidia-smi，请先安装 NVIDIA 驱动"
    exit 1
fi
echo "✓ NVIDIA 驱动已安装"

if ! command -v nvidia-settings &> /dev/null; then
    echo "❌ 错误: 未检测到 nvidia-settings，请先安装"
    exit 1
fi
echo "✓ nvidia-settings 已安装"

# X 服务检测
echo ""
echo "步骤 2/7: 检测 X 服务..."

# 快速检测常用 DISPLAY
detect_x_display() {
    local quick_list=":0 :1 :2 :8 :9 :99 :98"
    for d in $quick_list; do
        if DISPLAY=$d nvidia-settings -q "[gpu:0]/GPUFanControlState" >/dev/null 2>&1; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

FOUND_DISPLAY=$(detect_x_display) || FOUND_DISPLAY=""

if [[ -n "$FOUND_DISPLAY" ]]; then
    echo "✓ 找到可用 X DISPLAY: $FOUND_DISPLAY"
else
    echo "⚠️  未找到可用的系统 X 服务"
    echo ""
    
    # 检查是否有 x_service_helper.sh
    if [[ -f "x_service_helper.sh" ]]; then
        echo "检测到 X 服务智能检测工具，正在启动..."
        echo ""
        sudo bash x_service_helper.sh
        
        # 重新检测
        FOUND_DISPLAY=$(detect_x_display) || FOUND_DISPLAY=""
        
        if [[ -z "$FOUND_DISPLAY" ]]; then
            echo "❌ X 服务配置失败，安装中止"
            exit 1
        fi
        echo "✓ X 服务配置成功: $FOUND_DISPLAY"
    else
        echo "❌ 错误: 未找到可用 X 服务，且 x_service_helper.sh 不存在"
        echo ""
        echo "解决方案:"
        echo "  1. 启动本地 X 服务器"
        echo "  2. 或使用 x_service_helper.sh 安装 Xvfb"
        exit 1
    fi
fi

# 创建工作目录
echo ""
echo "步骤 3/7: 创建工作目录..."
WORK_DIR="/home/fan_control"
sudo mkdir -p "$WORK_DIR"
sudo chown $CURRENT_USER:$CURRENT_USER "$WORK_DIR"
echo "✓ 工作目录已创建: $WORK_DIR"

# 复制脚本文件
echo ""
echo "步骤 4/7: 安装脚本文件..."

if [[ ! -f "fan_control.sh" ]]; then
    echo "❌ 错误: 找不到 fan_control.sh"
    exit 1
fi

if [[ ! -f "nvidia-fan-helper" ]]; then
    echo "❌ 错误: 找不到 nvidia-fan-helper"
    exit 1
fi

cp fan_control.sh "$WORK_DIR/fan_control.sh"
chmod +x "$WORK_DIR/fan_control.sh"
echo "✓ 主脚本已安装: $WORK_DIR/fan_control.sh"

sudo cp nvidia-fan-helper /usr/local/bin/nvidia-fan-helper
sudo chmod +x /usr/local/bin/nvidia-fan-helper
echo "✓ 包装脚本已安装: /usr/local/bin/nvidia-fan-helper"

# 配置 sudo 免密
echo ""
echo "步骤 5/7: 配置 sudo 免密..."

SUDOERS_FILE="/etc/sudoers.d/nvidia-fan-control"
sudo tee "$SUDOERS_FILE" > /dev/null << EOF
# NVIDIA GPU Fan Control - sudo 免密配置
# 创建时间: $(date)
# 用户: $CURRENT_USER

$CURRENT_USER ALL=(ALL) NOPASSWD: /usr/local/bin/nvidia-fan-helper
$CURRENT_USER ALL=(root) NOPASSWD: /usr/bin/nvidia-smi
EOF

sudo chmod 0440 "$SUDOERS_FILE"
echo "✓ sudo 免密配置已完成"

# 配置 systemd 服务
echo ""
echo "步骤 6/7: 配置 systemd 服务..."

SYSTEMD_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_DIR"

cat > "$SYSTEMD_DIR/fan-control.service" << EOF
[Unit]
Description=NVIDIA GPU Auto Fan Control Service
After=graphical-session.target

[Service]
Type=simple
ExecStart=$WORK_DIR/fan_control.sh
Restart=on-failure
RestartSec=10s
StandardOutput=file:$WORK_DIR/fan_control.log
StandardError=file:$WORK_DIR/fan_control.log

[Install]
WantedBy=default.target
EOF

echo "✓ systemd 服务配置已创建"

# 启用服务
systemctl --user daemon-reload
systemctl --user enable fan-control.service
echo "✓ 服务已启用（开机自启）"

# 启用 lingering
loginctl enable-linger "$CURRENT_USER"
echo "✓ 用户 lingering 已启用"

# 启动服务
echo ""
echo "步骤 7/7: 启动服务..."

systemctl --user start fan-control.service

# 等待 2 秒
sleep 2

# 检查服务状态
if systemctl --user is-active --quiet fan-control.service; then
    echo "✓ 服务已成功启动"
else
    echo "❌ 服务启动失败，请查看日志:"
    echo "   tail -f $WORK_DIR/fan_control.log"
    exit 1
fi

# 安装完成
echo ""
echo "=========================================="
echo "✅ 安装完成！"
echo "=========================================="
echo ""
echo "服务状态:"
systemctl --user status fan-control.service --no-pager | head -5
echo ""
echo "查看实时日志:"
echo "  tail -f $WORK_DIR/fan_control.log"
echo ""
echo "管理服务:"
echo "  systemctl --user start fan-control.service    # 启动"
echo "  systemctl --user stop fan-control.service     # 停止"
echo "  systemctl --user restart fan-control.service  # 重启"
echo "  systemctl --user status fan-control.service   # 状态"
echo ""
echo "修改配置:"
echo "  编辑 $WORK_DIR/fan_control.sh 顶部的配置区"
echo "  修改后重启服务: systemctl --user restart fan-control.service"
echo ""
echo "=========================================="
