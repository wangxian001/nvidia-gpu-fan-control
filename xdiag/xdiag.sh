#!/bin/bash
# =============================================================================
# X Display 环境演化诊断脚本（只读，不修改任何系统文件）
# 版本: 2026-06-29 v1
# 用途: 从系统启动早期开始，每秒采样一次 X 环境关键状态，持续 5 分钟
#       用于定位 fan-control.service 开机自启失败时的 X 认证机制
# =============================================================================

LOG_FILE="/home/fan_control/xdiag.log"
SAMPLES_TOTAL=300       # 总采样次数（5 分钟）
INTERVAL_SEC=1          # 采样间隔（秒）
BOOT_EPOCH=$(date +%s)  # 脚本启动时间戳

mkdir -p "$(dirname "$LOG_FILE")"

# ---------------------- 日志辅助函数 ----------------------
hline()  { echo "================================================================================" >> "$LOG_FILE"; }
hdr()    { hline; echo "[$1]  开机后第 $2 秒  采样 #$3 / $SAMPLES_TOTAL" >> "$LOG_FILE"; hline; }
sect()   { echo "" >> "$LOG_FILE"; echo "--- $1 ---" >> "$LOG_FILE"; }
log()    { echo "$1" >> "$LOG_FILE"; }

# ---------------------- 各采样字段的检查函数 ----------------------

# 检查 .Xauthority 等文件状态
check_xauth_file() {
    local path="$1"
    local label="$2"
    if [[ -e "$path" ]]; then
        local sz mtime cookies
        sz=$(stat -c %s "$path" 2>/dev/null)
        mtime=$(stat -c %y "$path" 2>/dev/null)
        cookies=$(xauth -f "$path" list 2>/dev/null | head -20)
        log "$label: 存在  大小=${sz}B  mtime=$mtime"
        if [[ -n "$cookies" ]]; then
            log "  cookies:"
            echo "$cookies" | sed 's/^/    /' >> "$LOG_FILE"
        else
            log "  cookies: (空或不可读)"
        fi
    else
        log "$label: 不存在"
    fi
}

# 检查 X server 状态
check_x_server() {
    local xorg_pid xorg_cmdline xlock
    xorg_pid=$(pgrep -f "Xorg.*:0" 2>/dev/null | head -1)
    if [[ -n "$xorg_pid" ]]; then
        xorg_cmdline=$(cat /proc/$xorg_pid/cmdline 2>/dev/null | tr '\0' ' ')
        log "Xorg :0 运行中  PID=$xorg_pid"
        log "  cmdline: $xorg_cmdline"
    else
        log "Xorg :0: 未运行"
    fi
    if [[ -e /tmp/.X0-lock ]]; then
        log "/tmp/.X0-lock 存在"
    else
        log "/tmp/.X0-lock 不存在"
    fi
    # 列出所有 /tmp/.X*-lock
    local locks
    locks=$(ls /tmp/.X*-lock 2>/dev/null | tr '\n' ' ')
    [[ -n "$locks" ]] && log "  其他 X lock: $locks"
}

# 检查 xhost SI 列表（必须用 wangxian 身份且 DISPLAY 设好）
check_xhost() {
    local out
    out=$(sudo -u wangxian -H DISPLAY=:0 xhost 2>&1)
    log "xhost @DISPLAY=:0 输出:"
    echo "$out" | sed 's/^/  /' >> "$LOG_FILE"
}

# 检查 systemd --user 环境（必须用 wangxian 身份）
check_systemd_user_env() {
    local out
    out=$(sudo -u wangxian -H XDG_RUNTIME_DIR=/run/user/1000 systemctl --user show-environment 2>/dev/null | grep -E "^DISPLAY=|^XAUTHORITY=|^WAYLAND")
    if [[ -n "$out" ]]; then
        log "systemd --user 环境:"
        echo "$out" | sed 's/^/  /' >> "$LOG_FILE"
    else
        log "systemd --user 环境: 无 DISPLAY/XAUTHORITY（或 systemd --user 未启动）"
    fi
}

# 列出当前登录会话
check_sessions() {
    log "loginctl list-sessions:"
    loginctl list-sessions --no-legend 2>/dev/null | sed 's/^/  /' >> "$LOG_FILE"
}

# ---------------------- 关键功能验证测试 ----------------------

# TEST_A: wangxian 身份 + 空环境 + 遍历候选 DISPLAY，查询 GPUFanControlState
#   目的: 验证 SI:localuser:wangxian 机制是否独立于 .Xauthority 文件
test_a_wangxian_pure_si() {
    log "TEST_A: wangxian 身份 + env -i + 遍历 DISPLAY 查询 (考察 SI 机制)"
    for d in :0 :1 :2 :8 :9 :99 :98; do
        local out rc
        out=$(sudo -u wangxian -H env -i DISPLAY=$d /usr/bin/nvidia-settings -q "[gpu:0]/GPUFanControlState" 2>&1 | head -1)
        rc=$?
        log "  DISPLAY=$d: rc=$rc  输出: $out"
        [[ $rc -eq 0 && "$out" == *"Attribute"* ]] && break
    done
}

# TEST_B: 完全模拟 fan_control.sh 当前调用方式 (sudo helper get_display)
test_b_current_invocation() {
    log "TEST_B: 当前 fan_control.sh 的调用方式 (sudo helper get_display)"
    # 模拟开机时进程环境 (空 DISPLAY/XAUTHORITY)
    local out rc
    out=$(sudo -u wangxian -H env -i sudo /usr/local/bin/nvidia-fan-helper get_display 2>&1)
    rc=$?
    log "  rc=$rc  输出: $out"
}

# TEST_C: 去掉 sudo 的方案 (helper get_display)
test_c_proposed_fix() {
    log "TEST_C: 提议的修复 (无 sudo, helper get_display)"
    local out rc
    out=$(sudo -u wangxian -H env -i /usr/local/bin/nvidia-fan-helper get_display 2>&1)
    rc=$?
    log "  rc=$rc  输出: $out"
}

# TEST_D: 验证去掉 sudo 后, enable_manual_d/reset_auto_d 在开机环境下能否工作
#   注意: 这会真的修改风扇模式! 所以做完立即恢复
test_d_actual_fan_control() {
    log "TEST_D: 模拟开机环境下设置/恢复风扇模式 (将做实际操作并立即恢复)"
    # 先查原始状态
    local orig
    orig=$(sudo -u wangxian -H env -i /usr/local/bin/nvidia-fan-helper get_display 2>&1)
    log "  当前检测 DISPLAY: $orig"
    if [[ "$orig" == "NONE" || -z "$orig" ]]; then
        log "  跳过 (DISPLAY 不可用)"
        return
    fi

    # 尝试 enable_manual_d
    local out1 rc1
    out1=$(sudo -u wangxian -H env -i /usr/local/bin/nvidia-fan-helper enable_manual_d "$orig" 0 2>&1)
    rc1=$?
    log "  enable_manual_d $orig 0: rc=$rc1  输出: $out1"

    # 立即恢复
    sleep 0.5
    local out2 rc2
    out2=$(sudo -u wangxian -H env -i /usr/local/bin/nvidia-fan-helper reset_auto_d "$orig" 0 2>&1)
    rc2=$?
    log "  reset_auto_d $orig 0 (立即恢复): rc=$rc2  输出: $out2"
}

# ---------------------- 主循环 ----------------------

hline
log "X Display 诊断脚本启动"
log "启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
log "脚本 PID: $$"
log "采样配置: 共 $SAMPLES_TOTAL 次, 间隔 $INTERVAL_SEC 秒"
hline

# 系统启动时间参考
log "uptime: $(uptime)"
log "who -b: $(who -b)"
hline

for ((i=1; i<=SAMPLES_TOTAL; i++)); do
    NOW=$(date '+%Y-%m-%d %H:%M:%S')
    ELAPSED=$(( $(date +%s) - BOOT_EPOCH ))
    hdr "$NOW" "$ELAPSED" "$i"

    # ---- 文件层 ----
    sect "Xauthority 文件状态"
    check_xauth_file "/home/wangxian/.Xauthority" "/home/wangxian/.Xauthority"
    check_xauth_file "/var/lib/lightdm/.Xauthority" "/var/lib/lightdm/.Xauthority"
    # /var/run/lightdm/root/:0 需要 root 才能读 cookies
    if [[ -e "/var/run/lightdm/root/:0" ]]; then
        local_sz=$(stat -c %s "/var/run/lightdm/root/:0" 2>/dev/null)
        local_mt=$(stat -c %y "/var/run/lightdm/root/:0" 2>/dev/null)
        log "/var/run/lightdm/root/:0: 存在  大小=${local_sz}B  mtime=$local_mt"
        cookies=$(xauth -f "/var/run/lightdm/root/:0" list 2>/dev/null | head -5)
        [[ -n "$cookies" ]] && echo "$cookies" | sed 's/^/    /' >> "$LOG_FILE"
    else
        log "/var/run/lightdm/root/:0: 不存在"
    fi

    # ---- X server 层 ----
    sect "X server 状态"
    check_x_server

    # ---- 访问控制层 ----
    sect "X server 访问控制 (xhost)"
    check_xhost

    # ---- systemd --user 层 ----
    sect "systemd --user 环境"
    check_systemd_user_env

    # ---- 会话层 ----
    sect "登录会话"
    check_sessions

    # ---- 功能验证层 ----
    # 这一层每 10 秒做一次（避免日志爆炸）
    if (( i == 1 || i % 10 == 0 )); then
        sect "功能验证测试"
        test_a_wangxian_pure_si
        log ""
        test_b_current_invocation
        log ""
        test_c_proposed_fix
        # TEST_D 涉及实际改风扇，只在前 30 秒做一次，避免反复打扰
        if (( i == 1 )); then
            log ""
            test_d_actual_fan_control
        fi
    fi

    sleep "$INTERVAL_SEC"
done

hline
log "诊断结束 $(date '+%Y-%m-%d %H:%M:%S')"
hline
