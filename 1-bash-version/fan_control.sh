#!/bin/bash
# ====================================================
# NVIDIA GPU 智能温度管理系统（V2.1 - 2026-01-20）
# 优化内容：
# 1. 合并 nvidia-smi 调用（一次调用获取多个属性）
# 2. 优化风扇转速读取（按需读取 + 缓存）
# 3. 优化计时器检查（计数器代替取模）
# 4. 减少 nvidia-fan-helper 调用（读取操作直接调用 nvidia-smi）
# 5. 优化正则表达式（使用 awk 直接提取）
# 6. 批量操作优化（一次读取所有 GPU 信息）
# 【1229-01 新增优化】
# 7. 温度稳定时仅输出心跳，大幅减少日志量
# 8. 温度无变化时跳过后续逻辑判断，降低CPU占用
# 9. 风扇转速解析改用awk，提高兼容性
# ====================================================

# ==================== 用户配置区 ====================
# ==================== 用户配置区 ====================
# ==================== 用户配置区 ====================
# === 若不能理解配置区各参数的含义，建议使用默认值 ======


# 本区域包含所有可调整的参数，根据您的需求修改后重启服务即可生效
# 修改后执行: systemctl --user restart fan-control.service

# -------------------- 温度阈值设置 (°C) --------------------
# 这些阈值决定了系统何时采取行动来控制温度
HIGH_TEMP_THRESHOLD=70      # 高温阈值：GPU温度超过此值时，启动手动风扇控制
                            # 建议值：65-75°C，根据GPU型号和散热条件调整

CRITICAL_TEMP_THRESHOLD=75  # 临界温度阈值：GPU温度超过此值时，启动功率限制
                            # 建议值：70-80°C，应高于HIGH_TEMP_THRESHOLD
                            # 注意：仅在ENABLE_POWER_LIMIT=1时生效

LOW_TEMP_THRESHOLD=65       # 低温阈值：GPU温度低于此值时，恢复自动风扇控制
                            # 建议值：60-70°C，应低于HIGH_TEMP_THRESHOLD
                            # 目的：避免频繁切换风扇模式

COOL_TEMP_THRESHOLD=45      # 冷却阈值：GPU温度低于此值时，恢复默认功率限制
                            # 建议值：40-50°C，应远低于CRITICAL_TEMP_THRESHOLD
                            # 目的：确保GPU充分冷却后再恢复全功率

# -------------------- 持续时间设置 (秒) --------------------
# 这些延迟可以避免温度短暂波动导致的频繁切换
HIGH_TEMP_DURATION=3        # 手动风扇触发延迟：温度持续超过HIGH_TEMP_THRESHOLD多久后启动手动风扇
                            # 建议值：3-10秒，太短会频繁切换，太长响应慢

CRITICAL_TEMP_DURATION=6    # 功率限制触发延迟：温度持续超过CRITICAL_TEMP_THRESHOLD多久后降低功率
                            # 建议值：5-15秒，应大于HIGH_TEMP_DURATION

LOW_TEMP_DURATION=10        # 自动风扇恢复延迟：温度持续低于LOW_TEMP_THRESHOLD多久后恢复自动风扇
                            # 建议值：10-30秒，避免温度刚降下来就切换回自动模式

COOL_TEMP_DURATION=15       # 功率恢复延迟：温度持续低于COOL_TEMP_THRESHOLD多久后恢复默认功率
                            # 建议值：15-60秒，确保GPU充分冷却

# -------------------- 风扇控制设置 --------------------
MANUAL_FAN_SPEED=75         # 手动风扇转速百分比：当启动手动风扇时，设置的转速
                            # 范围：0-100，建议值：70-85
                            # 注意：过高会增加噪音，过低可能散热不足

# -------------------- 功率限制设置 --------------------
REDUCED_POWER_PERCENT=75    # 降低功率百分比：当温度过高时，将功率限制到默认功率的百分之多少
                            # 范围：50-90，建议值：70-80
                            # 例如：默认功率300W，设置75则限制到225W (300 × 0.75)

ENABLE_POWER_LIMIT=1        # 功率限制功能总开关
                            # 1 = 启用（高温时自动降低功率，低温时恢复）
                            # 0 = 禁用（始终保持默认最大功率，仅控制风扇）
                            # 建议：如果您的散热良好，可以禁用以获得最大性能

# -------------------- 系统优化参数 --------------------
# 这些参数影响系统的响应速度和资源占用，一般不需要修改
CHECK_INTERVAL=5            # 主循环检查间隔：每隔多少秒检查一次GPU状态
                            # 建议值：3-10秒，太短会增加CPU占用

STATS_INTERVAL=300          # 统计信息输出间隔：每隔多少秒输出一次统计信息
                            # 默认：300秒（5分钟），可设置为60-600秒

POWER_CHECK_INTERVAL=60     # 功率自救检查间隔：每隔多少秒检查一次功率是否异常降低
                            # 默认：60秒（1分钟），用于自动恢复意外的功率下降

FAN_READ_INTERVAL=10        # 风扇转速缓存时间：风扇转速读取的缓存有效期
                            # 默认：10秒，减少nvidia-settings调用次数

HEARTBEAT_OUTPUT_INTERVAL=60  # 心跳输出间隔：温度稳定时多久输出一次完整信息
                            # 默认：60秒（1分钟），建议值：30-120秒
                            # 注意：实际间隔 = HEARTBEAT_OUTPUT_INTERVAL / CHECK_INTERVAL 次检测

DEEP_SLEEP_OUTPUT_INTERVAL=600  # 深度休眠输出间隔：深度休眠时多久输出一次时长信息
                            # 默认：600秒（10分钟），建议值：300-1800秒
                            # 注意：实际间隔 = DEEP_SLEEP_OUTPUT_INTERVAL / (CHECK_INTERVAL * DEEP_SLEEP_MULTIPLIER) 次检测

HEARTBEAT_VERBOSE_OUTPUT=0  # 心跳详细输出开关：是否输出心跳详细信息
                            # 1 = 启用（每次心跳输出完整信息）
                            # 0 = 禁用（仅输出打点符号，日志更简洁）
                            # 默认：0（禁用，减少日志冗余）

# -------------------- 深度休眠模式配置 --------------------
# 当GPU长时间处于心跳状态时，降低检测频率以进一步减少资源占用
ENABLE_DEEP_SLEEP=1         # 深度休眠模式总开关
                            # 1 = 启用（长时间心跳后降低检测频率）
                            # 0 = 禁用（始终保持正常检测频率）

DEEP_SLEEP_THRESHOLD=900    # 进入深度休眠的心跳持续时间（秒）
                            # 默认：900秒（15分钟）
                            # 建议值：600-1800秒（10-30分钟）

DEEP_SLEEP_MULTIPLIER=10    # 深度休眠时的检测间隔倍数
                            # 默认：10倍（5秒变为50秒）
                            # 建议值：5-20倍


# =============================   用户参数配置区 结束  ================================
# =============================   用户参数配置区 结束  ================================
# =============================   用户参数配置区 结束  ================================


# -------------------- 日志文件路径 --------------------
LOG_FILE="/home/fan_control/fan_control.log"  # 日志文件存放位置
                                             # 旧日志会自动归档到 log/ 子目录

# ------------------- 统计计数器 -------------------------------------------
declare -A STAT_FAN_CONTROL=()    # 手动/自动风扇切换次数
declare -A STAT_POWER_CHANGE=()   # 功率成功修改次数
declare -A STAT_TEMP_CHECKS=()    # 温度读取次数
declare -A STAT_STATE_CHANGES=()  # 状态切换次数
declare -A STAT_ERRORS=()         # 错误次数
declare -A STAT_INITIALIZATIONS=()# 初始化次数
declare -A STAT_FAN_SPEED_SET=()  # 风扇转速设置次数

# ------------------- 状态定义 -------------------------------------------
STATE_IDLE="AUTO"
STATE_MANUAL="MANUAL"
STATE_POWER_LIMITED="POWER_LIMITED"

# ------------------- 全局数组（每块 GPU 对应） -------------------------
declare -A GPU_FANS            # GPU → "fan0 fan1"
declare -A GPU_DEFAULT_POWER   # GPU → 默认功率（W，整数）
declare -A GPU_REDUCED_POWER   # GPU → 降低后功率（W，整数）
declare -A GPU_ORIGINAL_POWER  # 初始读取的功率（用于恢复）
declare -A GPU_CURRENT_POWER   # 当前功率（实时，整数）
declare -A GPU_STATE           # 当前状态（IDLE / MANUAL / …）

# ------------------- 【新增】缓存数组 -------------------------
declare -A GPU_TEMP            # GPU → 温度缓存（整数）
declare -A GPU_FAN_SPEEDS      # GPU → 风扇转速缓存字符串
declare -A GPU_FAN_CACHE_TIME  # GPU → 上次读取风扇的时间戳



# ------------------- 计时器数组 -------------------------
declare -A GPU_FAN_ENTER_TIMER     # 进入手动风扇计时器（IDLE）
declare -A GPU_FAN_RECOVER_TIMER   # 恢复自动风扇计时器（MANUAL）
declare -A GPU_POWER_TRIGGER_TIMER # 功率限制触发计时器（MANUAL）
declare -A GPU_POWER_COOL_TIMER    # 功率恢复冷却计时器（IDLE）
declare -A GPU_POWER_STATE         # NORMAL / POWER_LIMITED
declare -A GPU_MAX_TEMP            # 本轮最高温度（整数）
declare -A GPU_HIST_MAX_TEMP       # 自启动以来的历史最高温度（整数）
declare -A GPU_LAST_VALID_MAX_TEMP # 【新增】上一次有效的5分钟最高温（用于心跳模式下显示回退）
# 【新增 1229-01】温度变化检测和心跳优化
declare -A GPU_LAST_TEMP           # 上次记录的温度
declare -A GPU_HEARTBEAT_COUNTER   # 心跳计数器

# 【新增】深度休眠模式相关变量
declare -A GPU_HEARTBEAT_DURATION  # 心跳持续时间（秒）
declare -A GPU_DEEP_SLEEP_MODE     # 是否处于深度休眠模式（0/1）
declare -A GPU_DEEP_SLEEP_START_TIME  # 进入深度休眠的时间戳（用于计算实际休眠时长）
declare -A GPU_SLEEP_READY_LOGGED     # 【新增】记录是否已输出"准备进入深度休眠"日志
DEEP_SLEEP_START_TIMESTAMP=0       # 全局深度休眠开始时间戳（所有GPU都准备好时记录）


# 【新增】计时器计数器（代替取模运算）
STATS_COUNTER=0
POWER_CHECK_COUNTER=0
# 【新增 1229-02】统计区间状态变化标记
STATS_HAS_CHANGES=false

# 【新增 1229-02】DISPLAY 跟踪
CURRENT_DISPLAY=""                 # 当前使用的虚拟显示器编号
CACHED_DISPLAY=""                  # 缓存的可用 DISPLAY（用于风扇操作）

# 【新增】心跳输出阈值计算
# 根据配置参数自动计算心跳计数器阈值，避免硬编码
# 使用四舍五入以获得更准确的结果（先乘10，加5，再除10实现四舍五入）
HEARTBEAT_COUNTER_THRESHOLD=$(( (HEARTBEAT_OUTPUT_INTERVAL * 10 / CHECK_INTERVAL + 5) / 10 ))
DEEP_SLEEP_COUNTER_THRESHOLD=$(( (DEEP_SLEEP_OUTPUT_INTERVAL * 10 / (CHECK_INTERVAL * DEEP_SLEEP_MULTIPLIER) + 5) / 10 ))

# ==============================================================================
# =============================   工具函数   ================================
# ==============================================================================
initialize_logging() {
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    echo "==============================================================================" >> "$LOG_FILE"
    echo "=======GPU 智能温度管理服务启动于: $(date)========" >> "$LOG_FILE"
    echo "===========================GPU功率自动限制功能: $([ "$ENABLE_POWER_LIMIT" == "1" ] && echo "启用" || echo "禁用")==========================" >> "$LOG_FILE"
    echo "===========================GPU闲时深度休眠功能: $([ "$ENABLE_DEEP_SLEEP" == "1" ] && echo "启用" || echo "禁用")==========================" >> "$LOG_FILE"
    echo "==============================================================================" >> "$LOG_FILE"
}
log() {
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $1" | tee -a "$LOG_FILE"
}
log_count() {
    local name=$1 idx=$2
    ((STAT_${name}[$idx]++))
}
log_progress() {
    local cur=$1 tot=$2 msg=$3
    log "$msg ($cur/$tot)"
}
error_exit() {
    log "错误: $1"
    exit 1
}

# ------------------- 【新增 1229-02】获取当前 DISPLAY -------------------
get_current_display() {
    local display=$(/usr/local/bin/nvidia-fan-helper get_display 2>/dev/null)
    if [[ -n "$display" && "$display" != "NONE" ]]; then
        echo "$display"
    else
        echo "未检测到"
    fi
}

# ------------------- GPU 检测 -----------------------------------------
auto_detect_gpus() {
    log "自动检测已安装的Nvidia GPU 数量..."
    local cnt=$(nvidia-smi --list-gpus | wc -l)
    log "DEBUG: 方法1检测到 $cnt 个 GPU"
    if [[ -z "$cnt" || "$cnt" -eq 0 ]]; then
        local raw=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null)
        log "DEBUG: 方法2原始输出: '$raw'"
        cnt=$(echo "$raw" | head -n 1 | tr -d '\n')
    fi
    if [[ -z "$cnt" || "$cnt" -eq 0 ]]; then
        cnt=$(nvidia-smi -q -x 2>/dev/null | grep -c '<gpu id=')
        log "DEBUG: 方法3检测到 $cnt 个 GPU"
    fi
    [[ -z "$cnt" || ! "$cnt" =~ ^[0-9]+$ || "$cnt" -eq 0 ]] && error_exit "无法检测到 GPU"
    log "最终确认: 检测到 $cnt 个Nvidia GPU"

    # 【新增】打印每个 GPU 的详细信息
    log "GPU 详细信息:"
    local gpu_info
    gpu_info=$(nvidia-smi --query-gpu=index,name,uuid --format=csv,noheader,nounits 2>/dev/null)
    while IFS=',' read -r idx name uuid; do
        idx=$(echo "$idx" | tr -d ' ')
        name=$(echo "$name" | tr -d ' ')
        uuid=$(echo "$uuid" | tr -d ' ')
        log "GPU $idx: $name (UUID: $uuid)"
    done <<< "$gpu_info"

    for ((i=0;i<cnt;i++)); do
        local fan_start=$((i*2))
        GPU_FANS[$i]="$fan_start $((fan_start+1))"
        log "GPU $i: 分配风扇 ${GPU_FANS[$i]}"
    done
    local idx_str=$(printf '%s ' "${!GPU_FANS[@]}")
    local fan_str=$(printf '%s ' "${GPU_FANS[@]}")
    log "监控的GPU (索引): $idx_str"
    log "监控的GPU (风扇映射): $fan_str"
}
# ------------------- 【优化】读取默认功率 ------------------------------------
get_default_power_limit() {
    local i=$1
    local d=$(nvidia-smi -i "$i" --query-gpu=power.default_limit \
                         --format=csv,noheader,nounits 2>/dev/null)
    echo "${d:-0}" | tr -d ' ' | awk '{print int($1)}'
}

# ------------------- 【优化】读取当前功率 ------------------------------------
get_power_limit() {
    local i=$1
    local p=$(nvidia-smi -i "$i" --query-gpu=power.limit \
                         --format=csv,noheader,nounits 2>/dev/null)
    echo "${p:-0}" | tr -d ' ' | awk '{print int($1)}'
    log_count "POWER_CHECKS" "$i"
}

# ------------------- 设置功率 ----------------------------------------
set_power_limit() {
    local i=$1 target=$2
    target=$(printf "%d" "$target")
    log "GPU $i: 尝试设置功率限制为 ${target}W"
    if sudo /usr/local/bin/nvidia-fan-helper set_power_limit "$i" "$target" >/dev/null 2>&1; then
        sleep 0.5
        local cur=$(get_power_limit "$i")
        if (( cur >= target-5 && cur <= target+5 )); then
            log "GPU $i: 功率限制设置成功 (当前: ${cur}W)"
            GPU_CURRENT_POWER[$i]="${cur}"
            log_count "POWER_CHANGE" "$i"
            return 0
        else
            log "GPU $i: 警告 – 实际 ${cur}W，目标 ${target}W"
            log_count "ERRORS" "$i"
            return 1
        fi
    else
        log "GPU $i: 错误 – 设置功率命令失败"
        log_count "ERRORS" "$i"
        return 1
    fi
}

# ------------------- 风扇控制 ----------------------------------------
# 【新增】重新检测 DISPLAY 并更新缓存
refresh_cached_display() {
    log "风扇操作失败，重新检测 X DISPLAY..."
    local display_output
    display_output=$(sudo /usr/local/bin/nvidia-fan-helper get_display_v 2>&1)
    local new_display=$(echo "$display_output" | tail -n 1)
    # 打印检测过程日志
    while IFS= read -r line; do
        [[ -n "$line" ]] && log "$line"
    done <<< "$(echo "$display_output" | head -n -1)"
    
    if [[ -n "$new_display" && "$new_display" != "NONE" ]]; then
        CACHED_DISPLAY="$new_display"
        CURRENT_DISPLAY="$new_display"
        log "✔ 找到新的可用 X DISPLAY=$new_display"
        return 0
    else
        log "✖ 未找到可用的 X DISPLAY"
        return 1
    fi
}

enable_manual_fan() {
    local i=$1
    log "GPU $i: 启用手动风扇"
    # 优先使用缓存的 DISPLAY
    if [[ -n "$CACHED_DISPLAY" && "$CACHED_DISPLAY" != "NONE" ]]; then
        if /usr/local/bin/nvidia-fan-helper enable_manual_d "$CACHED_DISPLAY" "$i" 2>/dev/null; then
            log_count "FAN_CONTROL" "$i"
            return 0
        fi
    fi
    # 缓存失效或无缓存，重新检测 DISPLAY 并重试
    if refresh_cached_display; then
        if /usr/local/bin/nvidia-fan-helper enable_manual_d "$CACHED_DISPLAY" "$i" 2>/dev/null; then
            log_count "FAN_CONTROL" "$i"
            return 0
        fi
    fi
    log "GPU $i: 错误 – 启用手动风扇失败"
    log_count "ERRORS" "$i"
    return 1
}

set_fan_speed() {
    local i=$1 speed=$2
    log "GPU $i: 设置风扇转速为 ${speed}%"
    local ok=true
    for fan in ${GPU_FANS[$i]}; do
        # 优先使用缓存的 DISPLAY
        if [[ -n "$CACHED_DISPLAY" && "$CACHED_DISPLAY" != "NONE" ]]; then
            if /usr/local/bin/nvidia-fan-helper set_fan_speed_d "$CACHED_DISPLAY" "$fan" "$speed" 2>/dev/null; then
                continue
            fi
        fi
        # 回退到动态检测
        if ! /usr/local/bin/nvidia-fan-helper set_fan_speed "$fan" "$speed" >/dev/null 2>&1; then
            log "GPU $i: 错误 – 设置风扇 $fan 失败"
            log_count "ERRORS" "$i"
            ok=false
        fi
    done
    if $ok; then
        log_count "FAN_SPEED_SET" "$i"
        return 0
    else
        return 1
    fi
}

reset_auto_fan() {
    local i=$1
    log "GPU $i: 恢复自动风扇"
    # 优先使用缓存的 DISPLAY
    if [[ -n "$CACHED_DISPLAY" && "$CACHED_DISPLAY" != "NONE" ]]; then
        if /usr/local/bin/nvidia-fan-helper reset_auto_d "$CACHED_DISPLAY" "$i" 2>/dev/null; then
            GPU_CURRENT_POWER[$i]=$(get_power_limit "$i")
            log_count "FAN_CONTROL" "$i"
            return 0
        fi
    fi
    # 缓存失效或无缓存，重新检测 DISPLAY 并重试
    if refresh_cached_display; then
        if /usr/local/bin/nvidia-fan-helper reset_auto_d "$CACHED_DISPLAY" "$i" 2>/dev/null; then
            GPU_CURRENT_POWER[$i]=$(get_power_limit "$i")
            log_count "FAN_CONTROL" "$i"
            return 0
        fi
    fi
    log "GPU $i: 错误 – 恢复自动风扇失败"
    log_count "ERRORS" "$i"
    return 1
}

# ------------------- 【优化】读取并缓存指定 GPU 的所有风扇转速（带缓存） -------------------
get_cached_fan_speeds() {
    local gpu=$1
    local current_time=$(date +%s)
    local last_time=${GPU_FAN_CACHE_TIME[$gpu]:-0}

    # 如果距离上次读取超过 FAN_READ_INTERVAL 秒，或者缓存为空，才重新读取
    if [[ -z "${GPU_FAN_SPEEDS[$gpu]}" ]] || (( current_time - last_time >= FAN_READ_INTERVAL )); then
        local fans="${GPU_FANS[$gpu]}"
        local speeds=()
        for f in $fans; do
            # 【优化】使用 awk 直接提取数字
            local sp=$(/usr/local/bin/nvidia-fan-helper get_fan_speed "$f")
            if [[ "$sp" == "N/A" ]]; then
                speeds+=(":N/A")
            else
                speeds+=("${sp}%")
            fi
        done
        GPU_FAN_SPEEDS[$gpu]=$(echo "${speeds[*]}" | sed 's/ /|/g')
        GPU_FAN_CACHE_TIME[$gpu]=$current_time
    fi

    echo "${GPU_FAN_SPEEDS[$gpu]}"
}

# ------------------- 【优化】批量读取所有 GPU 信息（一次调用） -------------------
batch_read_all_gpu_info() {
    local info
    info=$(nvidia-smi --query-gpu=index,temperature.gpu,power.limit \
                      --format=csv,noheader,nounits 2>/dev/null)

    # 使用 eval 读取 awk 输出，确保变量作用域正确
    while IFS=',' read -r idx temp power; do
        # 去除空格并转换为整数
        idx=$(echo "$idx" | tr -d ' ' | awk '{print int($1)}')
        temp=$(echo "$temp" | tr -d ' ' | awk '{print int($1)}')
        power=$(echo "$power" | tr -d ' ' | awk '{print int($1)}')

        if [[ -n "$idx" && "$idx" =~ ^[0-9]+$ ]]; then
            GPU_TEMP[$idx]=$temp
            GPU_POWER[$idx]=$power
            GPU_CURRENT_POWER[$idx]=$power
        fi
    done <<< "$info"
}

# ------------------- 计算降低功率（百分比） -------------------------
get_reduced_power() {
    local i=$1
    echo "${GPU_REDUCED_POWER[$i]}"
}

# ==============================================================================
# =============================   初始化阶段   ================================
# ==============================================================================
initialize_gpu_states() {
    local i=$1 prog=$2 tot=$3
    log_progress "$prog" "$tot" "初始化 GPU $i 状态"

    # 确保风扇自动（使用全局检测到的 CACHED_DISPLAY）
    if [[ -n "$CACHED_DISPLAY" && "$CACHED_DISPLAY" != "NONE" ]]; then
        if sudo /usr/local/bin/nvidia-fan-helper reset_auto_d "$CACHED_DISPLAY" "$i" 2>/dev/null; then
            log "GPU $i: 风扇模式检查成功：自动模式"
        else
            log "GPU $i: 风扇模式检查：手动模式"
            log "GPU $i: 尝试恢复风扇自动模式"
            # 尝试使用带重试的方式
            if sudo /usr/local/bin/nvidia-fan-helper reset_auto "$i" 2>/dev/null; then
                log "GPU $i: 风扇模式检查成功：自动模式"
            else
                log "GPU $i: 警告 – 风扇自动模式恢复失败"
                log_count "ERRORS" "$i"
            fi
        fi
    else
        # DISPLAY 未检测到，跳过风扇检查
        log "GPU $i: 跳过风扇检查（无可用 DISPLAY）"
    fi

    # 确保功率为默认最大（仅在启用功率限制功能时）
    if [[ "$ENABLE_POWER_LIMIT" == "1" ]]; then
        local cur=$(get_power_limit "$i")
        local max="${GPU_DEFAULT_POWER[$i]}"
        if (( cur < max )); then
            if set_power_limit "$i" "$max"; then
                log "GPU $i: 已恢复功率至最大 ${max}W"
            else
                log "GPU $i: 警告 – 功率恢复失败"
            fi
        else
            log "GPU $i: 功率检测成功，已在额定功率 ${max}W"
        fi
    else
        log "GPU $i: 功率限制已禁用，跳过功率初始化"
    fi
    log_count "INITIALIZATIONS" "$i"
}

initialize_gpus() {
    log "初始化 GPU 状态..."
    auto_detect_gpus
    [[ ${#GPU_FANS[@]} -eq 0 ]] && error_exit "未检测到 GPU"

    # 【新增】全局检测可用的 X DISPLAY（带 verbose 日志）
    log "正在查询系统可用 Display :X 服务"
    local display_output
    display_output=$(sudo /usr/local/bin/nvidia-fan-helper get_display_v 2>&1)
    # 最后一行是实际的 DISPLAY 值，其他是日志
    CACHED_DISPLAY=$(echo "$display_output" | tail -n 1)
    # 打印检测过程日志（除了最后一行）
    while IFS= read -r line; do
        [[ -n "$line" ]] && log "$line"
    done <<< "$(echo "$display_output" | head -n -1)"
    
    if [[ -n "$CACHED_DISPLAY" && "$CACHED_DISPLAY" != "NONE" ]]; then
        log "  ✔ 找到并使用 X DISPLAY=$CACHED_DISPLAY"
    else
        log "警告: 未检测到可用的 X DISPLAY，风扇控制功能可能受限"
        CACHED_DISPLAY=""
    fi

    # 读取默认功率并计算降额（仅在启用功率限制时需要计算）
    if [[ "$ENABLE_POWER_LIMIT" == "1" ]]; then
        log "功率限制功能已启用，正在计算降额功率..."
        for i in "${!GPU_FANS[@]}"; do
            local def=$(get_default_power_limit "$i")
            (( def <= 0 )) && error_exit "GPU $i 默认功率读取失败"
            GPU_DEFAULT_POWER[$i]="$def"
            local reduced=$(( (def * REDUCED_POWER_PERCENT + 50) / 100 ))
            GPU_REDUCED_POWER[$i]="$reduced"
            log "GPU $i: 默认功率 = ${def}W, 降低后 (${REDUCED_POWER_PERCENT}%) = ${reduced}W"
        done
    else
        log "功率限制功能已禁用，跳过功率计算..."
        for i in "${!GPU_FANS[@]}"; do
            local def=$(get_default_power_limit "$i")
            GPU_DEFAULT_POWER[$i]="$def"
            GPU_REDUCED_POWER[$i]="$def"
            log "GPU $i: 默认功率 = ${def}W (功率限制已禁用)"
        done
    fi

    local total=${#GPU_FANS[@]} prog=0
    for i in "${!GPU_FANS[@]}"; do
        ((prog++))
        GPU_STATE[$i]="$STATE_IDLE"
        # 初始化所有计时器
        GPU_FAN_ENTER_TIMER[$i]=0
        GPU_FAN_RECOVER_TIMER[$i]=0
        GPU_POWER_TRIGGER_TIMER[$i]=0
        GPU_POWER_COOL_TIMER[$i]=0
        GPU_POWER_STATE[$i]="NORMAL"
        # 统计计数器归零
        STAT_FAN_CONTROL[$i]=0
        STAT_POWER_CHANGE[$i]=0
        STAT_TEMP_CHECKS[$i]=0
        STAT_STATE_CHANGES[$i]=0
        STAT_ERRORS[$i]=0
        STAT_INITIALIZATIONS[$i]=0
        STAT_FAN_SPEED_SET[$i]=0
        # 初始化缓存变量
        GPU_TEMP[$i]=0
        GPU_FAN_SPEEDS[$i]=""
        GPU_FAN_CACHE_TIME[$i]=0
        # 读取当前功率
        local cur=$(get_power_limit "$i")
        GPU_ORIGINAL_POWER[$i]="${cur:-${GPU_DEFAULT_POWER[$i]}}"
        GPU_CURRENT_POWER[$i]="${cur:-${GPU_DEFAULT_POWER[$i]}}"
        GPU_MAX_TEMP[$i]=0
        GPU_HIST_MAX_TEMP[$i]=0
        GPU_LAST_VALID_MAX_TEMP[$i]=0  # 【新增】初始化有效最高温缓存
        # 【新增 1229-01】初始化温度变化检测变量
        GPU_LAST_TEMP[$i]=0
        GPU_HEARTBEAT_COUNTER[$i]=0
        # 【新增】初始化深度休眠模式变量
        GPU_HEARTBEAT_DURATION[$i]=0
        GPU_DEEP_SLEEP_MODE[$i]=0
        GPU_DEEP_SLEEP_START_TIME[$i]=0
        GPU_SLEEP_READY_LOGGED[$i]=0  # 【新增】初始化日志标志
        initialize_gpu_states "$i" "$prog" "$total"
        log_progress "$prog" "$total" "GPU $i 初始化完毕 (风扇: ${GPU_FANS[$i]}, 默认功率: ${GPU_DEFAULT_POWER[$i]}W)"
    done

    # 初始化时批量读取一次所有 GPU 信息
    batch_read_all_gpu_info
    
    # 记录当前使用的 DISPLAY，后面log显示用到
    CURRENT_DISPLAY="$CACHED_DISPLAY"
#    log "CURRENT_DISPLAY_USE: $CURRENT_DISPLAY"
}

# ==============================================================================
# ============================= 旧日志自动搬迁 ================================
# ==============================================================================
rename_log_on_start() {
    local f="$LOG_FILE"
    if [[ -f "$f" ]]; then
        mkdir -p "$(dirname "$f")/log"
        local ts=$(date +%Y%m%d_%H%M%S)
        local new="$(dirname "$f")/log/fan_control_${ts}.log"
        mv "$f" "$new" 2>/dev/null
        log "旧日志已重命名为: $(basename "$new")并自动归档到 /log/ 子目录"
        touch "$f"
    fi
}

# ==============================================================================
# =============================   主循环（优化版 + 1229-01） ================================
# ==============================================================================
main() {
    rename_log_on_start
    mkdir -p "$(dirname "$LOG_FILE")"
    initialize_logging
    initialize_gpus
    log "====== GPU 智能温度管理服务已启动, 当前X服务Display:$CURRENT_DISPLAY ======"

    # 在脚本退出时打印最终历史最高温度
    trap 'log "=== 脚本结束，最终历史最高温度 ==="; for i in "${!GPU_FANS[@]}"; do log "GPU $i: ${GPU_HIST_MAX_TEMP[$i]}°C"; done' EXIT

    # 计算循环次数阈值
    local stats_threshold=$((STATS_INTERVAL / CHECK_INTERVAL))
    local power_check_threshold=$((POWER_CHECK_INTERVAL / CHECK_INTERVAL))

    while true; do
        # 【优化】先批量读取所有 GPU 信息（一次调用）
        batch_read_all_gpu_info

        for gpu_index in "${!GPU_FANS[@]}"; do
            # 【优化】从缓存读取温度
            local current_temp=${GPU_TEMP[$gpu_index]}
            log_count "TEMP_CHECKS" "$gpu_index"
            [[ -z "$current_temp" ]] && { log "GPU $gpu_index: 无法读取温度，跳过"; continue; }

            # 【优化 1229-01】温度变化检测：使用固定基准温度，避免累计偏差
            local last_temp=${GPU_LAST_TEMP[$gpu_index]:-0}
            local temp_diff=$((current_temp - last_temp))
            temp_diff=${temp_diff#-}  # 取绝对值

            # 温度稳定（变化 < 2°C）且完全处于稳定状态：仅输出心跳，跳过详细逻辑
            # 【优化 1229-02】只有在风扇自动 + 功率正常（或功率限制禁用）时才进入心跳模式
            # 这样可以确保所有状态转换都在主逻辑中完成，日志更清晰
            local in_stable_state=false
            if [[ "${GPU_STATE[$gpu_index]}" == "$STATE_IDLE" ]]; then
                if [[ "$ENABLE_POWER_LIMIT" == "0" ]] || [[ "${GPU_POWER_STATE[$gpu_index]}" == "NORMAL" ]]; then
                    in_stable_state=true
                fi
            fi
            
            if (( temp_diff < 2 )) && $in_stable_state; then
                ((GPU_HEARTBEAT_COUNTER[$gpu_index]++))
                
                # 【新增】累积心跳持续时间（但不超过阈值，避免深度休眠后继续增加）
                if (( GPU_HEARTBEAT_DURATION[$gpu_index] < DEEP_SLEEP_THRESHOLD )); then
                    GPU_HEARTBEAT_DURATION[$gpu_index]=$((GPU_HEARTBEAT_DURATION[$gpu_index] + CHECK_INTERVAL))
                fi
                
                # 【新增】标记此 GPU 已准备好进入深度休眠
                if [[ "$ENABLE_DEEP_SLEEP" == "1" ]] && \
                   (( GPU_HEARTBEAT_DURATION[$gpu_index] >= DEEP_SLEEP_THRESHOLD )); then
                    GPU_DEEP_SLEEP_MODE[$gpu_index]=1
                fi
                
                # 【优化 1229-01】混合方式心跳：每次打点，每N次换行并输出温度
                # N = HEARTBEAT_COUNTER_THRESHOLD（根据配置自动计算）
                if (( GPU_HEARTBEAT_COUNTER[$gpu_index] >= HEARTBEAT_COUNTER_THRESHOLD )); then
                    # 换行并输出完整温度信息
                    local ts=$(date '+%Y-%m-%d %H:%M:%S')
                    
                    # 【修复】深度休眠期间跳过单个GPU的输出（包括换行）
                    if (( DEEP_SLEEP_ACTIVE == 1 )) && (( GPU_DEEP_SLEEP_START_TIME[$gpu_index] > 0 )); then
                        # 已进入深度休眠，完全跳过输出，计数器会在统一输出时重置
                        :  # 空操作，不换行，不输出，不重置计数器
                    else
                        # 未进入深度休眠，正常输出
                        if [[ "${GPU_DEEP_SLEEP_MODE[$gpu_index]}" == "1" ]]; then
                            # 达到条件但还未进入深度休眠
                            # 【新增】只在首次满足条件时输出完整日志
                            if [[ "${GPU_SLEEP_READY_LOGGED[$gpu_index]}" == "0" ]]; then
                                echo "" | tee -a "$LOG_FILE"  # 换行
                                echo "[$ts] GPU $gpu_index: 💤 ${current_temp}°C (基准${last_temp}°C，温度稳定达15分钟，准备进入深度休眠)" | tee -a "$LOG_FILE"
                                GPU_SLEEP_READY_LOGGED[$gpu_index]=1
                            fi
                            # 后续心跳周期不再输出完整日志，只打点（在else分支的打点部分处理）
                        else
                            # 【新增】根据 HEARTBEAT_VERBOSE_OUTPUT 配置决定是否输出详细信息
                            if [[ "$HEARTBEAT_VERBOSE_OUTPUT" == "1" ]]; then
                                echo "" | tee -a "$LOG_FILE"  # 换行
                                echo "[$ts] GPU $gpu_index: ❤ ${current_temp}°C (稳定，基准${last_temp}°C)" | tee -a "$LOG_FILE"
                            fi
                            # 如果禁用详细输出，不换行，不输出任何内容
                        fi
                        GPU_HEARTBEAT_COUNTER[$gpu_index]=0
                    fi
                else
                    # 打点（不换行）
                    if [[ "${GPU_DEEP_SLEEP_MODE[$gpu_index]}" == "1" ]]; then
                        echo -n "💤" | tee -a "$LOG_FILE"  # 深度休眠用不同的符号
                    else
                        echo -n "." | tee -a "$LOG_FILE"
                    fi
                fi
                
                # 【修复 1229-02】心跳模式下清零风扇触发计时器，避免残留计数
                if (( current_temp < HIGH_TEMP_THRESHOLD )); then
                    GPU_FAN_ENTER_TIMER[$gpu_index]=0
                fi
                
                continue  # 跳过后续所有逻辑判断
            fi

            # 温度变化 ≥ 2°C 或处于非IDLE状态：执行完整逻辑并更新基准温度
            # 【修复 1229-01】只在从打点状态切换时才换行
            local was_heartbeat=false
            if (( GPU_HEARTBEAT_COUNTER[$gpu_index] > 0 )); then
                was_heartbeat=true
            fi
            
            # 【新增】检查是否从深度休眠模式唤醒
            local was_deep_sleep=false
            if [[ "${GPU_DEEP_SLEEP_MODE[$gpu_index]}" == "1" ]]; then
                was_deep_sleep=true
                
                # 重要：任何一个 GPU 唤醒时，重置所有 GPU 的深度休眠状态
                local ts=$(date '+%Y-%m-%d %H:%M:%S')
                echo "" | tee -a "$LOG_FILE"
                echo "[$ts] ⏰⏰⏰ 从深度休眠唤醒 (GPU $gpu_index 温度变化: ${last_temp}°C → ${current_temp}°C, 差值: ${temp_diff}°C) ⏰⏰⏰" | tee -a "$LOG_FILE"
                
                # 重置所有 GPU 的深度休眠标记和时间戳
                for i in "${!GPU_FANS[@]}"; do
                    GPU_DEEP_SLEEP_MODE[$i]=0
                    GPU_DEEP_SLEEP_START_TIME[$i]=0
                    GPU_SLEEP_READY_LOGGED[$i]=0  # 【新增】重置日志标志
                done
                
                # 重置全局深度休眠状态和时间戳
                DEEP_SLEEP_ACTIVE=0
                DEEP_SLEEP_START_TIMESTAMP=0  # 【修复】重置全局深度休眠开始时间
            fi

            GPU_LAST_TEMP[$gpu_index]=$current_temp  # 更新基准温度
            GPU_HEARTBEAT_COUNTER[$gpu_index]=0  # 重置心跳计数
            GPU_HEARTBEAT_DURATION[$gpu_index]=0  # 【新增】重置心跳持续时间
            GPU_SLEEP_READY_LOGGED[$gpu_index]=0  # 【新增】重置日志标志

            # 如果之前在打点，先换行
            if $was_heartbeat || $was_deep_sleep; then
                echo "" | tee -a "$LOG_FILE"
            fi

            # 记录本轮最高温度（5 分钟窗口）
            if (( current_temp > GPU_MAX_TEMP[$gpu_index] )); then
                GPU_MAX_TEMP[$gpu_index]=$current_temp
            fi

            # 记录历史最高温度（自启动以来）
            if (( current_temp > GPU_HIST_MAX_TEMP[$gpu_index] )); then
                GPU_HIST_MAX_TEMP[$gpu_index]=$current_temp
            fi

            local current_state="${GPU_STATE[$gpu_index]}"
            local current_power_state="${GPU_POWER_STATE[$gpu_index]}"
            local default_power="${GPU_DEFAULT_POWER[$gpu_index]}"
            local reduced_power="${GPU_REDUCED_POWER[$gpu_index]}"

            # 【优化】使用带缓存的风扇读取
            local fan_speeds=$(get_cached_fan_speeds "$gpu_index")
            local current_power=${GPU_CURRENT_POWER[$gpu_index]}

            # 【优化 1229-01】仅在温度变化时输出详细日志
            log "GPU $gpu_index: ${current_temp}°C, Fan_mode: $current_state: $fan_speeds, GPU-Power: ${current_power}W (default ${default_power}W)"

            # --------------------------------------------------------------
            # ★ 温度回落时统一复位计时器（防止残余计数） ★
            # --------------------------------------------------------------
            if (( current_temp < HIGH_TEMP_THRESHOLD )); then
                GPU_FAN_ENTER_TIMER[$gpu_index]=0
            fi
            if (( current_temp < CRITICAL_TEMP_THRESHOLD )); then
                GPU_POWER_TRIGGER_TIMER[$gpu_index]=0
            fi

            # --------------------------------------------------------------
            # ------------------- 状态机 -------------------
            # 1️⃣ 先处理 **功率**（独立于风扇状态）
            # --------------------------------------------------------------
            if [[ "$ENABLE_POWER_LIMIT" == "1" ]]; then
                # ---------- ① 功率限制 ----------
                if (( current_temp > CRITICAL_TEMP_THRESHOLD )); then
                    if [[ "${GPU_POWER_STATE[$gpu_index]}" == "NORMAL" ]]; then
                        ((GPU_POWER_TRIGGER_TIMER[$gpu_index]++))
                        log_progress "${GPU_POWER_TRIGGER_TIMER[$gpu_index]}" "$CRITICAL_TEMP_DURATION" \
                            "GPU $gpu_index: 功率限制触发"
                        if (( GPU_POWER_TRIGGER_TIMER[$gpu_index] >= CRITICAL_TEMP_DURATION )); then
                            if set_power_limit "$gpu_index" "$reduced_power"; then
                                GPU_POWER_STATE[$gpu_index]="$STATE_POWER_LIMITED"
                                log "GPU $gpu_index: 已将功率限制至 ${reduced_power}W (默认 ${default_power}W)"
                                log_count "POWER_CHANGE" "$gpu_index"
                                STATS_HAS_CHANGES=true  # 标记状态变化
                            else
                                log "GPU $gpu_index: 降功率失败"
                                log_count "ERRORS" "$gpu_index"
                            fi
                            GPU_POWER_TRIGGER_TIMER[$gpu_index]=0
                        fi
                    fi
                else
                    GPU_POWER_TRIGGER_TIMER[$gpu_index]=0
                fi

                # ---------- ② 功率恢复 ----------
                if (( current_temp < COOL_TEMP_THRESHOLD )) && \
                   [[ "${GPU_POWER_STATE[$gpu_index]}" == "$STATE_POWER_LIMITED" ]]; then
                    ((GPU_POWER_COOL_TIMER[$gpu_index]++))
                    log_progress "${GPU_POWER_COOL_TIMER[$gpu_index]}" "$COOL_TEMP_DURATION" \
                        "GPU $gpu_index: 解除功率限制"
                    if (( GPU_POWER_COOL_TIMER[$gpu_index] >= COOL_TEMP_DURATION )); then
                        if set_power_limit "$gpu_index" "$default_power"; then
                            GPU_POWER_STATE[$gpu_index]="NORMAL"
                            log "GPU $gpu_index: 功率已恢复到默认 ${default_power}W"
                            log_count "POWER_CHANGE" "$gpu_index"
                            STATS_HAS_CHANGES=true  # 标记状态变化
                        else
                            log "GPU $gpu_index: 功率恢复失败"
                            log_count "ERRORS" "$gpu_index"
                        fi
                        GPU_POWER_COOL_TIMER[$gpu_index]=0
                    fi
                else
                    GPU_POWER_COOL_TIMER[$gpu_index]=0
                fi
            else
                # 功率限制已禁用，确保状态为 NORMAL
                GPU_POWER_STATE[$gpu_index]="NORMAL"
                GPU_POWER_TRIGGER_TIMER[$gpu_index]=0
                GPU_POWER_COOL_TIMER[$gpu_index]=0
            fi

            # --------------------------------------------------------------
            # 2️⃣ 再处理 **风扇**（保持原有的状态机结构）
            # --------------------------------------------------------------
            case "$current_state" in
                "$STATE_IDLE")
        if (( current_temp > HIGH_TEMP_THRESHOLD )); then
            ((GPU_FAN_ENTER_TIMER[$gpu_index]++))
            log_progress "${GPU_FAN_ENTER_TIMER[$gpu_index]}" "$HIGH_TEMP_DURATION" \
                "GPU $gpu_index: 风扇手动模式触发"

            if (( GPU_FAN_ENTER_TIMER[$gpu_index] >= HIGH_TEMP_DURATION )); then
                # 【优化】失败后立即重试，最多3次
                local retry_count=0
                local max_retries=3
                local success=false

                while (( retry_count < max_retries )); do
                    if enable_manual_fan "$gpu_index" && set_fan_speed "$gpu_index" "$MANUAL_FAN_SPEED"; then
                        success=true
                        break
                    fi
                    ((retry_count++))
                    if (( retry_count < max_retries )); then
                        log "GPU $gpu_index: 手动风扇启用失败，重试 ($retry_count/$max_retries)..."
                        sleep 1  # 短暂等待后重试
                    fi
                done

                if $success; then
                    GPU_STATE[$gpu_index]="$STATE_MANUAL"
                    log_count "STATE_CHANGES" "$gpu_index"
                    STATS_HAS_CHANGES=true  # 标记状态变化
                    GPU_FAN_SPEEDS[$gpu_index]=$(get_cached_fan_speeds "$gpu_index")
                    log "GPU $gpu_index: 手动风扇已成功启用，当前转速: ${GPU_FAN_SPEEDS[$gpu_index]}"
                else
                    log "GPU $gpu_index: 手动风扇启用失败 (已重试 $max_retries 次)，跳过"
                    log_count "ERRORS" "$gpu_index"
                fi

                # 计时器归零
                GPU_FAN_ENTER_TIMER[$gpu_index]=0
                GPU_FAN_RECOVER_TIMER[$gpu_index]=0
            fi
        else
            GPU_FAN_ENTER_TIMER[$gpu_index]=0
        fi
                    ;;
                "$STATE_MANUAL")
        if (( current_temp < LOW_TEMP_THRESHOLD )); then
            ((GPU_FAN_RECOVER_TIMER[$gpu_index]++))
            log_progress "${GPU_FAN_RECOVER_TIMER[$gpu_index]}" "$LOW_TEMP_DURATION" \
                "GPU $gpu_index: 风扇自动模式恢复"

            if (( GPU_FAN_RECOVER_TIMER[$gpu_index] >= LOW_TEMP_DURATION )); then
                # 【优化】失败后立即重试，最多3次
                local retry_count=0
                local max_retries=3
                local success=false

                while (( retry_count < max_retries )); do
                    if reset_auto_fan "$gpu_index"; then
                        success=true
                        break
                    fi
                    ((retry_count++))
                    if (( retry_count < max_retries )); then
                        log "GPU $gpu_index: 自动风扇恢复失败，重试 ($retry_count/$max_retries)..."
                        sleep 1
                    fi
                done

                if $success; then
                    GPU_STATE[$gpu_index]="$STATE_IDLE"
                    GPU_FAN_ENTER_TIMER[$gpu_index]=0
                    GPU_FAN_RECOVER_TIMER[$gpu_index]=0
                    GPU_POWER_TRIGGER_TIMER[$gpu_index]=0
                    GPU_POWER_COOL_TIMER[$gpu_index]=0
                    log_count "STATE_CHANGES" "$gpu_index"
                    STATS_HAS_CHANGES=true  # 标记状态变化
                    GPU_FAN_SPEEDS[$gpu_index]=$(get_cached_fan_speeds "$gpu_index")
                    log "GPU $gpu_index: 自动风扇已成功恢复，当前转速: ${GPU_FAN_SPEEDS[$gpu_index]}"
                else
                    log "GPU $gpu_index: 自动风扇恢复失败 (已重试 $max_retries 次)，跳过"
                    log_count "ERRORS" "$gpu_index"
                    # 恢复失败时，计时器不归零，下个周期继续等待
                    GPU_FAN_RECOVER_TIMER[$gpu_index]=0
                fi
            fi
        else
            GPU_FAN_RECOVER_TIMER[$gpu_index]=0
        fi

                    ;;
                *)
                    log "GPU $gpu_index: 未知状态 $current_state，重置为 IDLE"
                    GPU_STATE[$gpu_index]="$STATE_IDLE"
                    GPU_FAN_ENTER_TIMER[$gpu_index]=0
                    GPU_FAN_RECOVER_TIMER[$gpu_index]=0
                    GPU_POWER_TRIGGER_TIMER[$gpu_index]=0
                    GPU_POWER_COOL_TIMER[$gpu_index]=0
                    ;;
            esac
        done

        # 【新增】全局深度休眠检查：只有所有 GPU 都准备好才真正进入深度休眠
        if [[ "$ENABLE_DEEP_SLEEP" == "1" ]]; then
            local all_gpus_ready=true
            local any_gpu_ready=false
            
            # 检查是否所有 GPU 都准备好进入深度休眠
            for i in "${!GPU_FANS[@]}"; do
                if [[ "${GPU_DEEP_SLEEP_MODE[$i]}" == "1" ]]; then
                    any_gpu_ready=true
                else
                    all_gpus_ready=false
                fi
            done
            
            # 只有所有 GPU 都准备好，且当前不在深度休眠状态时，才进入深度休眠
            if $all_gpus_ready && $any_gpu_ready && (( DEEP_SLEEP_ACTIVE == 0 )); then
                DEEP_SLEEP_ACTIVE=1
                local ts=$(date '+%Y-%m-%d %H:%M:%S')
                local current_timestamp=$(date +%s)
                DEEP_SLEEP_START_TIMESTAMP=$current_timestamp  # 【修复】记录全局深度休眠开始时间
                echo "" | tee -a "$LOG_FILE"
                echo "[$ts] 💤💤💤 所有 GPU 进入深度休眠模式 (检测间隔: ${CHECK_INTERVAL}s → $((CHECK_INTERVAL * DEEP_SLEEP_MULTIPLIER))s) 💤💤💤" | tee -a "$LOG_FILE"
                # 记录每个 GPU 进入深度休眠的时间戳
                for i in "${!GPU_FANS[@]}"; do
                    GPU_DEEP_SLEEP_START_TIME[$i]=$current_timestamp
                done
            fi
            
            # 如果有任何 GPU 不在深度休眠准备状态，退出深度休眠
            if ! $all_gpus_ready && (( DEEP_SLEEP_ACTIVE == 1 )); then
                DEEP_SLEEP_ACTIVE=0
                # 注意：唤醒消息已经在温度变化检测时输出，这里不重复输出
            fi
        fi

        # 【新增】深度休眠期间的统一心跳输出
        # 当处于深度休眠状态时，每N次检测输出一次统一的休眠状态
        # N = DEEP_SLEEP_COUNTER_THRESHOLD（根据配置自动计算）
        if (( DEEP_SLEEP_ACTIVE == 1 )); then
            # 检查是否有任何 GPU 的心跳计数器达到阈值（需要换行输出）
            local need_unified_output=false
            for i in "${!GPU_FANS[@]}"; do
                if (( GPU_HEARTBEAT_COUNTER[$i] >= DEEP_SLEEP_COUNTER_THRESHOLD )); then
                    need_unified_output=true
                    break
                fi
            done
            
            if $need_unified_output; then
                # 计算深度休眠时长（使用全局深度休眠开始时间戳）
                if (( DEEP_SLEEP_START_TIMESTAMP > 0 )); then
                    local sleep_duration=$(( ($(date +%s) - DEEP_SLEEP_START_TIMESTAMP) / 60 ))
                    local ts=$(date '+%Y-%m-%d %H:%M:%S')
                    echo "" | tee -a "$LOG_FILE"
                    echo "[$ts] 💤 深度休眠${sleep_duration}分钟" | tee -a "$LOG_FILE"
                    
                    # 【修复】重置所有 GPU 的心跳计数器
                    for i in "${!GPU_FANS[@]}"; do
                        GPU_HEARTBEAT_COUNTER[$i]=0
                    done
                fi
            fi
        fi

        # 【优化】使用计数器代替取模运算
        ((STATS_COUNTER++))
        ((POWER_CHECK_COUNTER++))

        # 5分钟统计
        if (( STATS_COUNTER >= stats_threshold )); then
            # 【优化 1229-02】只在本统计区间有状态变化时才输出统计
            # 状态变化包括：风扇模式切换、功率变化、错误发生、或温度≥60°C
            local has_activity=false
            
            # 检查是否有全局状态变化标记
            if $STATS_HAS_CHANGES; then
                has_activity=true
            else
                # 如果没有显式状态变化，检查温度是否较高
                for i in "${!GPU_FANS[@]}"; do
                    if (( GPU_MAX_TEMP[$i] >= 60 )); then
                        has_activity=true
                        break
                    fi
                done
            fi

            # 只在有活动时输出统计
            if $has_activity; then
                # 【新增 1229-02】检查 DISPLAY 是否变化
                local new_display=$(get_current_display)
                if [[ "$new_display" != "$CURRENT_DISPLAY" ]]; then
                    log "⚠️ 警告: CURRENT_DISPLAY Changed (旧: $CURRENT_DISPLAY → 新: $new_display)"
                    CURRENT_DISPLAY="$new_display"
                fi
                
                log "=== 统计信息 ==="
                log "CURRENT_DISPLAY: $CURRENT_DISPLAY"
                for i in "${!GPU_FANS[@]}"; do
                    # 【新增】处理心跳模式下的0°C显示问题
                    local display_max_temp=${GPU_MAX_TEMP[$i]}
                    if (( display_max_temp == 0 )); then
                        # 当前值为0，使用上一次有效值
                        display_max_temp=${GPU_LAST_VALID_MAX_TEMP[$i]}
                    else
                        # 当前值有效，更新缓存
                        GPU_LAST_VALID_MAX_TEMP[$i]=$display_max_temp
                    fi
                    
                    log "GPU $i:"
                    log "  *5分钟最高温: ${display_max_temp}°C"
                    log "  **历史最高温: ${GPU_HIST_MAX_TEMP[$i]}°C**"
                    log "  风扇控制次数: ${STAT_FAN_CONTROL[$i]}"
                    log "  转速设置次数: ${STAT_FAN_SPEED_SET[$i]}"
                    log "  功率变化次数: ${STAT_POWER_CHANGE[$i]}"
                    log "  温度检查次数: ${STAT_TEMP_CHECKS[$i]}"
                    log "  状态变化次数: ${STAT_STATE_CHANGES[$i]}"
                    log "  初始化次数: ${STAT_INITIALIZATIONS[$i]}"
                    log "  错误次数: ${STAT_ERRORS[$i]}"
                done
            fi

            # 重置5分钟最高温和状态变化标记（无论是否输出统计）
            for i in "${!GPU_FANS[@]}"; do
                GPU_MAX_TEMP[$i]=0
            done
            STATS_COUNTER=0
            STATS_HAS_CHANGES=false  # 重置状态变化标记
        fi

        # 【优化】每分钟自救（功率意外下降）- 仅在启用功率限制时执行
        if [[ "$ENABLE_POWER_LIMIT" == "1" ]]; then
            if (( POWER_CHECK_COUNTER >= power_check_threshold )); then
                for i in "${!GPU_FANS[@]}"; do
                    local cur=${GPU_CURRENT_POWER[$i]}
                    local max="${GPU_DEFAULT_POWER[$i]}"
                    if [[ -n "$cur" && $(echo "$cur < $max" | bc -l) -eq 1 && "${GPU_POWER_STATE[$i]}" != "$STATE_POWER_LIMITED" ]]; then
                        log "GPU $i: 检测到功率意外降低到 ${cur}W，尝试恢复至默认 ${max}W"
                        set_power_limit "$i" "$max"
                    fi
                done
                POWER_CHECK_COUNTER=0
            fi
        fi

        # 【新增】动态调整 sleep 间隔：如果有 GPU 处于深度休眠，使用更长的间隔
        local actual_interval=$CHECK_INTERVAL
        if [[ "$ENABLE_DEEP_SLEEP" == "1" ]] && (( DEEP_SLEEP_ACTIVE == 1 )); then
            actual_interval=$((CHECK_INTERVAL * DEEP_SLEEP_MULTIPLIER))
        fi
        
        sleep "$actual_interval"
    done
}

# ------------------- 程序入口 -------------------
main
