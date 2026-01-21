#!/bin/bash
# =============================================================================
# X 服务智能检测与自动部署工具 V2.1
# 
# 功能：
# 1. 遍历 :0 到 :99 的 DISPLAY 编号查找可用 X 服务
# 2. 自动安装 Xvfb 虚拟 X 服务（如果需要）
# 3. 创建 Xvfb systemd 服务确保开机自启
# 4. 将找到的 DISPLAY 写入包装脚本
#
# 使用方法：
#   sudo bash x_service_helper.sh
#
# 发布日期: 2026-01-20
# =============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
HELPER_SCRIPT="/usr/local/bin/nvidia-fan-helper"
XVFB_DISPLAY=":99"
XVFB_SERVICE_NAME="xvfb-nvidia-fan"

# ------------------- 日志函数 -------------------
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# ------------------- 检查 nvidia-settings 是否可用 -------------------
check_nvidia_settings() {
    if ! command -v nvidia-settings &>/dev/null; then
        log_error "nvidia-settings 未安装，请先安装 NVIDIA 驱动"
        return 1
    fi
    return 0
}

# ------------------- 检测 SSH 转发的 DISPLAY -------------------
is_ssh_display() {
    local display=$1
    # SSH 转发的 DISPLAY 格式通常是 localhost:10.0 或 hostname:10.0
    if [[ "$display" == *":"*"."* ]] && [[ "$display" != ":"* ]]; then
        return 0  # 是 SSH 转发
    fi
    return 1  # 不是 SSH 转发
}

# ------------------- 测试单个 DISPLAY -------------------
test_display() {
    local display=$1
    DISPLAY=$display nvidia-settings -q "[gpu:0]/GPUFanControlState" >/dev/null 2>&1
    return $?
}

# ------------------- 快速检测常用 DISPLAY -------------------
quick_detect_display() {
    log_step "正在快速检测常用 X DISPLAY..."
    
    local quick_list=":0 :1 :2 :8 :9 :99 :98"
    
    for d in $quick_list; do
        echo -n "  检测 DISPLAY=$d ... "
        if test_display "$d"; then
            echo -e "${GREEN}✔ 可用${NC}"
            FOUND_DISPLAY="$d"
            return 0
        else
            echo -e "${RED}✖ 不可用${NC}"
        fi
    done
    
    return 1
}

# ------------------- 全面检测 DISPLAY (:0 到 :99) -------------------
full_detect_display() {
    log_step "正在全面检测 X DISPLAY (:0 到 :99)..."
    echo ""
    
    local found=0
    local available_displays=()
    
    for i in $(seq 0 99); do
        local d=":$i"
        # 显示进度
        printf "\r  扫描进度: %3d/100 - 当前检测 DISPLAY=$d " "$((i+1))"
        
        if test_display "$d"; then
            available_displays+=("$d")
            ((found++))
        fi
    done
    
    echo ""
    echo ""
    
    if [[ $found -gt 0 ]]; then
        log_info "找到 $found 个可用 X DISPLAY:"
        for d in "${available_displays[@]}"; do
            echo "  ✔ $d"
        done
        FOUND_DISPLAY="${available_displays[0]}"
        return 0
    else
        log_warn "未找到任何可用的 X DISPLAY"
        return 1
    fi
}

# ------------------- 检测 Xvfb 是否已安装 -------------------
check_xvfb_installed() {
    if command -v Xvfb &>/dev/null; then
        return 0
    fi
    return 1
}

# ------------------- 安装 Xvfb -------------------
install_xvfb() {
    log_step "正在安装 Xvfb 虚拟显示服务..."
    
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y xvfb
    elif command -v yum &>/dev/null; then
        yum install -y xorg-x11-server-Xvfb
    elif command -v dnf &>/dev/null; then
        dnf install -y xorg-x11-server-Xvfb
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm xorg-server-xvfb
    else
        log_error "无法识别包管理器，请手动安装 Xvfb"
        return 1
    fi
    
    if check_xvfb_installed; then
        log_info "Xvfb 安装成功"
        return 0
    else
        log_error "Xvfb 安装失败"
        return 1
    fi
}

# ------------------- 创建 Xvfb systemd 服务 -------------------
create_xvfb_service() {
    log_step "正在创建 Xvfb systemd 服务..."
    
    local service_file="/etc/systemd/system/${XVFB_SERVICE_NAME}.service"
    
    cat > "$service_file" <<EOF
[Unit]
Description=Xvfb Virtual Display for NVIDIA Fan Control
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb ${XVFB_DISPLAY} -screen 0 1024x768x24 -nolisten tcp
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    if [[ -f "$service_file" ]]; then
        log_info "服务文件已创建: $service_file"
        return 0
    else
        log_error "服务文件创建失败"
        return 1
    fi
}

# ------------------- 启动 Xvfb 服务 -------------------
start_xvfb_service() {
    log_step "正在启动 Xvfb 服务..."
    
    systemctl daemon-reload
    systemctl enable "$XVFB_SERVICE_NAME"
    systemctl start "$XVFB_SERVICE_NAME"
    
    # 等待服务启动
    sleep 2
    
    if systemctl is-active --quiet "$XVFB_SERVICE_NAME"; then
        log_info "Xvfb 服务已启动并设置为开机自启"
        return 0
    else
        log_error "Xvfb 服务启动失败"
        systemctl status "$XVFB_SERVICE_NAME"
        return 1
    fi
}

# ------------------- 验证 Xvfb 可用性 -------------------
verify_xvfb() {
    log_step "正在验证 Xvfb 服务..."
    
    if test_display "$XVFB_DISPLAY"; then
        log_info "✔ Xvfb 虚拟 X 服务已就绪 (DISPLAY=$XVFB_DISPLAY)"
        FOUND_DISPLAY="$XVFB_DISPLAY"
        return 0
    else
        log_error "Xvfb 服务验证失败"
        return 1
    fi
}

# ------------------- 更新包装脚本的候选 DISPLAY 列表 -------------------
update_helper_script() {
    local new_display=$1
    
    if [[ ! -f "$HELPER_SCRIPT" ]]; then
        log_warn "包装脚本不存在: $HELPER_SCRIPT"
        return 1
    fi
    
    log_step "正在更新包装脚本的 DISPLAY 候选列表..."
    
    # 读取当前的候选列表
    local current_list=$(grep "^CANDIDATE_DISPLAYS=" "$HELPER_SCRIPT" | cut -d'"' -f2)
    
    # 检查新的 DISPLAY 是否已在列表中
    if [[ "$current_list" == *"$new_display"* ]]; then
        log_info "DISPLAY=$new_display 已在候选列表中"
        return 0
    fi
    
    # 将新的 DISPLAY 添加到列表开头（优先使用）
    local new_list="$new_display $current_list"
    
    # 备份原文件
    cp "$HELPER_SCRIPT" "${HELPER_SCRIPT}.bak"
    
    # 更新文件
    sed -i "s|^CANDIDATE_DISPLAYS=.*|CANDIDATE_DISPLAYS=\"$new_list\"|" "$HELPER_SCRIPT"
    
    log_info "已将 DISPLAY=$new_display 添加到候选列表开头"
    log_info "新候选列表: $new_list"
    
    return 0
}

# ------------------- 输出诊断报告 -------------------
print_diagnosis() {
    echo ""
    echo "============================================================"
    echo "                 X 服务环境诊断报告"
    echo "============================================================"
    echo ""
    
    echo "【系统信息】"
    echo "  操作系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2 || uname -s)"
    echo "  内核版本: $(uname -r)"
    echo ""
    
    echo "【NVIDIA 驱动】"
    if command -v nvidia-smi &>/dev/null; then
        echo "  驱动版本: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
        echo "  GPU 数量: $(nvidia-smi --list-gpus 2>/dev/null | wc -l)"
    else
        echo "  状态: 未安装或不可用"
    fi
    echo ""
    
    echo "【X 服务状态】"
    if command -v nvidia-settings &>/dev/null; then
        echo "  nvidia-settings: 已安装"
    else
        echo "  nvidia-settings: 未安装"
    fi
    
    if check_xvfb_installed; then
        echo "  Xvfb: 已安装"
    else
        echo "  Xvfb: 未安装"
    fi
    
    if systemctl is-active --quiet "$XVFB_SERVICE_NAME" 2>/dev/null; then
        echo "  Xvfb 服务: 运行中"
    else
        echo "  Xvfb 服务: 未运行"
    fi
    echo ""
    
    echo "【当前环境 DISPLAY】"
    if [[ -n "$DISPLAY" ]]; then
        if is_ssh_display "$DISPLAY"; then
            echo "  DISPLAY=$DISPLAY (SSH 转发，不可用于 nvidia-settings)"
        else
            echo "  DISPLAY=$DISPLAY"
        fi
    else
        echo "  未设置"
    fi
    echo ""
    
    echo "【可用 X DISPLAY 检测】"
    for d in :0 :1 :2 :8 :9 :99 :98; do
        if test_display "$d"; then
            echo "  $d: ✔ 可用"
        else
            echo "  $d: ✖ 不可用"
        fi
    done
    echo ""
    
    echo "============================================================"
}

# ------------------- 交互式安装函数 -------------------
interactive_setup() {
    echo ""
    echo "============================================================"
    echo "       X 服务智能检测与自动部署工具 V2.1"
    echo "============================================================"
    echo ""
    
    # 检查 nvidia-settings
    if ! check_nvidia_settings; then
        exit 1
    fi
    
    # 快速检测
    if quick_detect_display; then
        log_info "快速检测成功！找到可用 X DISPLAY: $FOUND_DISPLAY"
        update_helper_script "$FOUND_DISPLAY"
        echo ""
        log_info "X 服务配置完成！"
        return 0
    fi
    
    # 快速检测失败，提示用户
    echo ""
    log_warn "没有找到可用的系统 X 服务"
    echo ""
    read -p "是否进行全面扫描 (检测 :0 到 :99)？[y/N] " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if full_detect_display; then
            log_info "全面扫描成功！找到可用 X DISPLAY: $FOUND_DISPLAY"
            update_helper_script "$FOUND_DISPLAY"
            echo ""
            log_info "X 服务配置完成！"
            return 0
        fi
    fi
    
    # 全面扫描也失败，询问是否安装 Xvfb
    echo ""
    log_warn "仍然没有找到可用的系统 X 服务"
    echo ""
    echo "我可以为您安装 Xvfb 虚拟 X 服务。这将："
    echo "  1. 安装 Xvfb 软件包"
    echo "  2. 创建 systemd 服务 (开机自启)"
    echo "  3. 启动虚拟 X 服务 (DISPLAY=$XVFB_DISPLAY)"
    echo ""
    read -p "是否安装 Xvfb 虚拟 X 服务？[y/N] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "用户取消安装"
        echo ""
        echo "您可以手动执行以下操作："
        echo "  1. 安装 Xvfb: apt-get install xvfb (或 yum install xorg-x11-server-Xvfb)"
        echo "  2. 启动 Xvfb: Xvfb :99 -screen 0 1024x768x24 &"
        echo "  3. 设置环境: export DISPLAY=:99"
        return 1
    fi
    
    # 安装 Xvfb
    if ! check_xvfb_installed; then
        if ! install_xvfb; then
            log_error "Xvfb 安装失败"
            return 1
        fi
    else
        log_info "Xvfb 已安装"
    fi
    
    # 创建并启动服务
    if ! create_xvfb_service; then
        return 1
    fi
    
    if ! start_xvfb_service; then
        return 1
    fi
    
    # 验证
    if ! verify_xvfb; then
        return 1
    fi
    
    # 更新包装脚本
    update_helper_script "$FOUND_DISPLAY"
    
    echo ""
    log_info "============================================================"
    log_info "  Xvfb 虚拟 X 服务配置完成！"
    log_info "  DISPLAY: $FOUND_DISPLAY"
    log_info "  服务名: $XVFB_SERVICE_NAME"
    log_info "============================================================"
    
    return 0
}

# ------------------- 主函数 -------------------
main() {
    # 检查 root 权限
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        echo "请使用: sudo bash $0"
        exit 1
    fi
    
    case "${1:-}" in
        --diagnose|-d)
            print_diagnosis
            ;;
        --quick|-q)
            check_nvidia_settings || exit 1
            if quick_detect_display; then
                echo "$FOUND_DISPLAY"
                exit 0
            fi
            exit 1
            ;;
        --full|-f)
            check_nvidia_settings || exit 1
            if full_detect_display; then
                echo "$FOUND_DISPLAY"
                exit 0
            fi
            exit 1
            ;;
        --install-xvfb|-x)
            install_xvfb && create_xvfb_service && start_xvfb_service && verify_xvfb
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --diagnose, -d    输出 X 服务环境诊断报告"
            echo "  --quick, -q       快速检测常用 DISPLAY"
            echo "  --full, -f        全面检测 :0 到 :99"
            echo "  --install-xvfb, -x  直接安装 Xvfb"
            echo "  --help, -h        显示此帮助信息"
            echo ""
            echo "不带参数时运行交互式安装向导"
            ;;
        *)
            interactive_setup
            ;;
    esac
}

main "$@"
