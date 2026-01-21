#!/usr/bin/env python3
"""
NVIDIA GPU 智能温度管理系统 - 一键部署版
版本: V2.1 (智能 X 服务检测)
日期: 2026-01-20

使用方法:
    sudo python3 gpu_fan_control_installer.py

功能:
    1. 自动检测系统环境
    2. 智能 X 服务检测（遍历 :0 到 :99）
    3. 自动安装 Xvfb 虚拟显示（如需要）
    4. 创建工作目录
    5. 生成主控制脚本（含深度休眠功能）
    6. 配置 systemd 服务
    7. 启动服务

特性:
    - 单文件部署，无需额外文件
    - 智能 X 服务检测与 Xvfb 自动部署
    - 包含深度休眠模式
    - 自动检测用户名
    - 完整的错误检查
"""

import os
import sys
import subprocess
import shutil
import time
from pathlib import Path
from datetime import datetime

# ==================== 配置区 ====================

class DeployConfig:
    """部署配置 - 可在安装前修改"""
    WORK_DIR = "/home/fan_control"
    LOG_FILE = "/home/fan_control/fan_control.log"
    LOG_DIR = "/home/fan_control/log"
    
    # 温度阈值 (°C)
    HIGH_TEMP_THRESHOLD = 70
    CRITICAL_TEMP_THRESHOLD = 75
    LOW_TEMP_THRESHOLD = 65
    COOL_TEMP_THRESHOLD = 45
    
    # 持续时间 (秒)
    HIGH_TEMP_DURATION = 3
    CRITICAL_TEMP_DURATION = 6
    LOW_TEMP_DURATION = 10
    COOL_TEMP_DURATION = 15
    
    # 风扇和功率设置
    MANUAL_FAN_SPEED = 75
    REDUCED_POWER_PERCENT = 75
    ENABLE_POWER_LIMIT = True
    
    # 系统参数
    CHECK_INTERVAL = 5
    STATS_INTERVAL = 300
    POWER_CHECK_INTERVAL = 60
    FAN_READ_INTERVAL = 10
    
    # 深度休眠模式配置
    ENABLE_DEEP_SLEEP = True
    DEEP_SLEEP_THRESHOLD = 900  # 15分钟
    DEEP_SLEEP_MULTIPLIER = 10  # 间隔延长10倍
    
    # 心跳输出配置（新增，与 Bash 版本同步）
    HEARTBEAT_OUTPUT_INTERVAL = 60    # 心跳输出间隔（秒）
    DEEP_SLEEP_OUTPUT_INTERVAL = 600  # 深度休眠输出间隔（秒）
    HEARTBEAT_VERBOSE_OUTPUT = False  # 心跳详细输出开关（False=简洁打点，True=详细）


# ==================== 主控制脚本内容 ====================

MAIN_SCRIPT_CONTENT = '''#!/usr/bin/env python3
"""
NVIDIA GPU 智能温度管理系统 (含深度休眠功能)
自动生成于: {timestamp}
版本: V2.1
"""

import os
import sys
import time
import subprocess
import signal
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, field
from enum import Enum

# ==================== 配置参数 ====================

class Config:
    # 温度阈值
    HIGH_TEMP_THRESHOLD = {HIGH_TEMP_THRESHOLD}
    CRITICAL_TEMP_THRESHOLD = {CRITICAL_TEMP_THRESHOLD}
    LOW_TEMP_THRESHOLD = {LOW_TEMP_THRESHOLD}
    COOL_TEMP_THRESHOLD = {COOL_TEMP_THRESHOLD}
    
    # 持续时间
    HIGH_TEMP_DURATION = {HIGH_TEMP_DURATION}
    CRITICAL_TEMP_DURATION = {CRITICAL_TEMP_DURATION}
    LOW_TEMP_DURATION = {LOW_TEMP_DURATION}
    COOL_TEMP_DURATION = {COOL_TEMP_DURATION}
    
    # 风扇和功率
    MANUAL_FAN_SPEED = {MANUAL_FAN_SPEED}
    REDUCED_POWER_PERCENT = {REDUCED_POWER_PERCENT}
    ENABLE_POWER_LIMIT = {ENABLE_POWER_LIMIT}
    
    # 系统参数
    CHECK_INTERVAL = {CHECK_INTERVAL}
    STATS_INTERVAL = {STATS_INTERVAL}
    POWER_CHECK_INTERVAL = {POWER_CHECK_INTERVAL}
    FAN_READ_INTERVAL = {FAN_READ_INTERVAL}
    
    # 深度休眠配置
    ENABLE_DEEP_SLEEP = {ENABLE_DEEP_SLEEP}
    DEEP_SLEEP_THRESHOLD = {DEEP_SLEEP_THRESHOLD}
    DEEP_SLEEP_MULTIPLIER = {DEEP_SLEEP_MULTIPLIER}
    
    # 心跳输出配置（与 Bash 版本同步）
    HEARTBEAT_OUTPUT_INTERVAL = {HEARTBEAT_OUTPUT_INTERVAL}
    DEEP_SLEEP_OUTPUT_INTERVAL = {DEEP_SLEEP_OUTPUT_INTERVAL}
    HEARTBEAT_VERBOSE_OUTPUT = {HEARTBEAT_VERBOSE_OUTPUT}
    
    # 自动计算阈值（四舍五入）
    HEARTBEAT_COUNTER_THRESHOLD = round({HEARTBEAT_OUTPUT_INTERVAL} / {CHECK_INTERVAL})
    DEEP_SLEEP_COUNTER_THRESHOLD = round({DEEP_SLEEP_OUTPUT_INTERVAL} / ({CHECK_INTERVAL} * {DEEP_SLEEP_MULTIPLIER}))
    
    # 文件路径
    LOG_FILE = "{LOG_FILE}"
    LOG_DIR = "{LOG_DIR}"
    
    # DISPLAY 候选列表
    DISPLAY_CANDIDATES = [":0", ":1", ":2", ":8", ":9", ":99", ":98"]


class FanState(Enum):
    AUTO = "AUTO"
    MANUAL = "MANUAL"


class PowerState(Enum):
    NORMAL = "NORMAL"
    POWER_LIMITED = "POWER_LIMITED"


@dataclass
class GPUState:
    index: int
    fans: List[int]
    fan_state: FanState = FanState.AUTO
    power_state: PowerState = PowerState.NORMAL
    default_power: int = 0
    reduced_power: int = 0
    current_power: int = 0
    current_temp: int = 0
    last_temp: int = 0
    max_temp: int = 0
    hist_max_temp: int = 0
    fan_enter_timer: int = 0
    fan_recover_timer: int = 0
    power_trigger_timer: int = 0
    power_cool_timer: int = 0
    heartbeat_counter: int = 0
    heartbeat_duration: int = 0
    deep_sleep_mode: bool = False
    deep_sleep_start_time: int = 0
    fan_speeds: str = ""
    fan_cache_time: float = 0
    stats: Dict[str, int] = field(default_factory=lambda: {{
        'fan_control': 0, 'fan_speed_set': 0, 'power_change': 0,
        'temp_checks': 0, 'state_changes': 0, 'errors': 0, 'initializations': 0
    }})


class NvidiaHelper:
    @staticmethod
    def detect_display() -> Optional[str]:
        current_display = os.environ.get('DISPLAY')
        if current_display and NvidiaHelper._test_display(current_display):
            return current_display
        for display in Config.DISPLAY_CANDIDATES:
            if NvidiaHelper._test_display(display):
                return display
        return None
    
    @staticmethod
    def _test_display(display: str) -> bool:
        try:
            env = os.environ.copy()
            env['DISPLAY'] = display
            result = subprocess.run(['nvidia-settings', '-q', 'GPUs'],
                                  env=env, capture_output=True, timeout=2)
            return result.returncode == 0
        except:
            return False
    
    @staticmethod
    def get_gpu_count() -> int:
        try:
            result = subprocess.run(['nvidia-smi', '--list-gpus'],
                                  capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                return len([line for line in result.stdout.strip().split('\\n') if line])
        except:
            pass
        return 0
    
    @staticmethod
    def get_gpu_info(gpu_index: int) -> Tuple[int, int]:
        try:
            result = subprocess.run(
                ['nvidia-smi', '-i', str(gpu_index),
                 '--query-gpu=temperature.gpu,power.limit',
                 '--format=csv,noheader,nounits'],
                capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                temp, power = result.stdout.strip().split(',')
                return int(float(temp)), int(float(power))
        except:
            pass
        return 0, 0
    
    @staticmethod
    def get_default_power(gpu_index: int) -> int:
        try:
            result = subprocess.run(
                ['nvidia-smi', '-i', str(gpu_index),
                 '--query-gpu=power.default_limit',
                 '--format=csv,noheader,nounits'],
                capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                return int(float(result.stdout.strip()))
        except:
            pass
        return 0
    
    @staticmethod
    def set_power_limit(gpu_index: int, power: int) -> bool:
        try:
            result = subprocess.run(['nvidia-smi', '-i', str(gpu_index), '-pl', str(power)],
                                  capture_output=True, timeout=5)
            return result.returncode == 0
        except:
            return False
    
    @staticmethod
    def enable_manual_fan(gpu_index: int, display: str) -> bool:
        try:
            env = os.environ.copy()
            env['DISPLAY'] = display
            result = subprocess.run(['nvidia-settings', '-a',
                                   f'[gpu:{{gpu_index}}]/GPUFanControlState=1'],
                                  env=env, capture_output=True, timeout=5)
            return result.returncode == 0
        except:
            return False
    
    @staticmethod
    def set_fan_speed(fan_index: int, speed: int, display: str) -> bool:
        try:
            env = os.environ.copy()
            env['DISPLAY'] = display
            result = subprocess.run(['nvidia-settings', '-a',
                                   f'[fan:{{fan_index}}]/GPUTargetFanSpeed={{speed}}'],
                                  env=env, capture_output=True, timeout=5)
            return result.returncode == 0
        except:
            return False
    
    @staticmethod
    def reset_auto_fan(gpu_index: int, display: str) -> bool:
        try:
            env = os.environ.copy()
            env['DISPLAY'] = display
            result = subprocess.run(['nvidia-settings', '-a',
                                   f'[gpu:{{gpu_index}}]/GPUFanControlState=0'],
                                  env=env, capture_output=True, timeout=5)
            return result.returncode == 0
        except:
            return False
    
    @staticmethod
    def get_fan_speed(fan_index: int, display: str) -> Optional[int]:
        try:
            env = os.environ.copy()
            env['DISPLAY'] = display
            result = subprocess.run(['nvidia-settings', '-q',
                                   f'[fan:{{fan_index}}]/GPUCurrentFanSpeed'],
                                  env=env, capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                for line in result.stdout.split('\\n'):
                    if 'GPUCurrentFanSpeed' in line and ':' in line:
                        speed_str = line.split(':')[-1].strip().rstrip('.')
                        return int(speed_str)
        except:
            pass
        return None


def log(message: str):
    """输出日志"""
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    log_message = f"[{{timestamp}}] {{message}}"
    print(log_message)
    with open(Config.LOG_FILE, 'a') as f:
        f.write(log_message + '\\n')


def log_no_newline(message: str):
    """输出日志（不换行）"""
    print(message, end='', flush=True)
    with open(Config.LOG_FILE, 'a') as f:
        f.write(message)


class GPUFanController:
    def __init__(self):
        self.gpus: Dict[int, GPUState] = {{}}
        self.display: Optional[str] = None
        self.running = True
        self.stats_counter = 0
        self.power_check_counter = 0
        self.stats_has_changes = False
        self.deep_sleep_active = False
        self._setup_logging()
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
    
    def _setup_logging(self):
        Path(Config.LOG_FILE).parent.mkdir(parents=True, exist_ok=True)
        Path(Config.LOG_DIR).mkdir(parents=True, exist_ok=True)
        if Path(Config.LOG_FILE).exists():
            timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
            archive_path = Path(Config.LOG_DIR) / f"fan_control_{{timestamp}}.log"
            Path(Config.LOG_FILE).rename(archive_path)
        log("=" * 40)
        log(f"GPU 智能温度管理服务启动于: {{datetime.now()}}")
        log(f"功率限制功能: {{'启用' if Config.ENABLE_POWER_LIMIT else '禁用'}}")
        log(f"闲时休眠功能: {{'启用' if Config.ENABLE_DEEP_SLEEP else '禁用'}}")
        log("=" * 40)
    
    def _signal_handler(self, signum, frame):
        log("收到退出信号，正在关闭...")
        self.running = False
    
    def initialize(self) -> bool:
        self.display = NvidiaHelper.detect_display()
        if not self.display:
            log("❌ 错误: 无法检测到可用的 DISPLAY")
            return False
        log(f"CURRENT_DISPLAY_USE: {{self.display}}")
        
        gpu_count = NvidiaHelper.get_gpu_count()
        if gpu_count == 0:
            log("❌ 错误: 未检测到 GPU")
            return False
        log(f"检测到 {{gpu_count}} 个 GPU")
        
        for i in range(gpu_count):
            fans = [i * 2, i * 2 + 1]
            gpu = GPUState(index=i, fans=fans)
            gpu.default_power = NvidiaHelper.get_default_power(i)
            if gpu.default_power == 0:
                log(f"❌ GPU {{i}}: 无法读取默认功率")
                return False
            gpu.reduced_power = int(gpu.default_power * Config.REDUCED_POWER_PERCENT / 100)
            log(f"GPU {{i}}: 默认功率 = {{gpu.default_power}}W, "
                f"降低后 ({{Config.REDUCED_POWER_PERCENT}}%) = {{gpu.reduced_power}}W")
            
            if not NvidiaHelper.reset_auto_fan(i, self.display):
                log(f"⚠️ GPU {{i}}: 风扇自动检查失败")
            
            if Config.ENABLE_POWER_LIMIT:
                current_power = NvidiaHelper.get_gpu_info(i)[1]
                if current_power < gpu.default_power:
                    if NvidiaHelper.set_power_limit(i, gpu.default_power):
                        log(f"GPU {{i}}: 已恢复功率至最大 {{gpu.default_power}}W")
            
            gpu.stats['initializations'] += 1
            self.gpus[i] = gpu
        
        log("=== GPU 智能温度管理服务已启动 ===")
        return True
    
    def run(self):
        if not self.initialize():
            return
        
        stats_threshold = Config.STATS_INTERVAL // Config.CHECK_INTERVAL
        power_check_threshold = Config.POWER_CHECK_INTERVAL // Config.CHECK_INTERVAL
        
        while self.running:
            try:
                # 更新所有 GPU
                for gpu in self.gpus.values():
                    self._update_gpu(gpu)
                
                # 全局深度休眠检查
                self._check_deep_sleep()
                
                # 统计和功率检查
                self.stats_counter += 1
                self.power_check_counter += 1
                
                if self.stats_counter >= stats_threshold:
                    self._print_statistics()
                    self.stats_counter = 0
                    self.stats_has_changes = False
                
                if self.power_check_counter >= power_check_threshold:
                    self._power_recovery_check()
                    self.power_check_counter = 0
                
                # 动态 sleep 间隔
                actual_interval = Config.CHECK_INTERVAL
                if Config.ENABLE_DEEP_SLEEP and self.deep_sleep_active:
                    actual_interval = Config.CHECK_INTERVAL * Config.DEEP_SLEEP_MULTIPLIER
                
                time.sleep(actual_interval)
                
            except Exception as e:
                log(f"❌ 主循环错误: {{e}}")
                time.sleep(Config.CHECK_INTERVAL)
        
        log("=== 脚本结束，最终历史最高温度 ===")
        for gpu in self.gpus.values():
            log(f"GPU {{gpu.index}}: {{gpu.hist_max_temp}}°C")
    
    def _update_gpu(self, gpu: GPUState):
        temp, power = NvidiaHelper.get_gpu_info(gpu.index)
        if temp == 0:
            return
        
        gpu.current_temp = temp
        gpu.current_power = power
        gpu.stats['temp_checks'] += 1
        
        # 温度变化检测
        temp_diff = abs(gpu.current_temp - gpu.last_temp)
        in_stable_state = (gpu.fan_state == FanState.AUTO and
                          (not Config.ENABLE_POWER_LIMIT or gpu.power_state == PowerState.NORMAL))
        
        # 心跳模式
        if temp_diff < 2 and in_stable_state:
            gpu.heartbeat_counter += 1
            
            # 累积心跳持续时间（但不超过阈值）
            if gpu.heartbeat_duration < Config.DEEP_SLEEP_THRESHOLD:
                gpu.heartbeat_duration += Config.CHECK_INTERVAL
            
            # 标记准备进入深度休眠
            if Config.ENABLE_DEEP_SLEEP and gpu.heartbeat_duration >= Config.DEEP_SLEEP_THRESHOLD:
                gpu.deep_sleep_mode = True
            
            # 心跳输出（使用参数化阈值）
            if gpu.heartbeat_counter >= Config.HEARTBEAT_COUNTER_THRESHOLD:
                # 换行并输出完整温度信息
                if self.deep_sleep_active and gpu.deep_sleep_start_time > 0:
                    # 已进入深度休眠，跳过单个GPU输出（稍后统一输出）
                    pass
                elif gpu.deep_sleep_mode:
                    # 准备进入深度休眠
                    log_no_newline('\\n')
                    log(f"GPU {{gpu.index}}: 💤 {{gpu.current_temp}}°C "
                        f"(基准{{gpu.last_temp}}°C，温度稳定达15分钟，准备进入深度休眠)")
                    gpu.heartbeat_counter = 0
                elif Config.HEARTBEAT_VERBOSE_OUTPUT:
                    # 详细模式：输出完整心跳信息
                    log_no_newline('\\n')
                    log(f"GPU {{gpu.index}}: ❤ {{gpu.current_temp}}°C (稳定，基准{{gpu.last_temp}}°C)")
                    gpu.heartbeat_counter = 0
                else:
                    # 简洁模式：仅重置计数器，不输出
                    gpu.heartbeat_counter = 0
            else:
                # 打点（不换行）
                if gpu.deep_sleep_mode:
                    log_no_newline('💤')
                else:
                    log_no_newline('.')
            
            # 清零风扇触发计时器
            if gpu.current_temp < Config.HIGH_TEMP_THRESHOLD:
                gpu.fan_enter_timer = 0
            
            return
        
        # 温度变化 >= 2°C，从深度休眠唤醒
        if gpu.deep_sleep_mode:
            log_no_newline('\\n')
            log(f"⏰⏰⏰ 从深度休眠唤醒 (GPU {{gpu.index}} 温度变化: "
                f"{{gpu.last_temp}}°C → {{gpu.current_temp}}°C, 差值: {{temp_diff}}°C) ⏰⏰⏰")
            # 重置所有 GPU 的深度休眠状态
            for g in self.gpus.values():
                g.deep_sleep_mode = False
                g.deep_sleep_start_time = 0
            self.deep_sleep_active = False
        
        # 如果之前在打点，先换行
        if gpu.heartbeat_counter > 0:
            log_no_newline('\\n')
        
        gpu.last_temp = gpu.current_temp
        gpu.heartbeat_counter = 0
        gpu.heartbeat_duration = 0
        
        # 更新最高温度
        if gpu.current_temp > gpu.max_temp:
            gpu.max_temp = gpu.current_temp
        if gpu.current_temp > gpu.hist_max_temp:
            gpu.hist_max_temp = gpu.current_temp
        
        # 获取风扇转速
        fan_speeds = self._get_cached_fan_speeds(gpu)
        
        # 输出详细信息
        log(f"GPU {{gpu.index}}: {{gpu.current_temp}}°C, Fan_mode: {{gpu.fan_state.value}}: {{fan_speeds}}, "
            f"GPU-Power: {{gpu.current_power}}W (default {{gpu.default_power}}W)")
        
        # 清零计时器
        if gpu.current_temp < Config.HIGH_TEMP_THRESHOLD:
            gpu.fan_enter_timer = 0
        if gpu.current_temp < Config.CRITICAL_TEMP_THRESHOLD:
            gpu.power_trigger_timer = 0
        
        # 处理功率和风扇控制
        self._handle_power_limit(gpu)
        self._handle_fan_control(gpu)
    
    def _check_deep_sleep(self):
        """全局深度休眠检查"""
        if not Config.ENABLE_DEEP_SLEEP:
            return
        
        # 检查是否所有 GPU 都准备好
        all_gpus_ready = all(gpu.deep_sleep_mode for gpu in self.gpus.values())
        any_gpu_ready = any(gpu.deep_sleep_mode for gpu in self.gpus.values())
        
        # 进入深度休眠
        if all_gpus_ready and any_gpu_ready and not self.deep_sleep_active:
            self.deep_sleep_active = True
            current_timestamp = int(time.time())
            log_no_newline('\\n')
            log(f"💤💤💤 所有 GPU 进入深度休眠模式 (检测间隔: {{Config.CHECK_INTERVAL}}s → "
                f"{{Config.CHECK_INTERVAL * Config.DEEP_SLEEP_MULTIPLIER}}s) 💤💤💤")
            # 记录时间戳
            for gpu in self.gpus.values():
                gpu.deep_sleep_start_time = current_timestamp
        
        # 退出深度休眠
        if not all_gpus_ready and self.deep_sleep_active:
            self.deep_sleep_active = False
        
        # 深度休眠期间的统一心跳输出（使用参数化阈值）
        if self.deep_sleep_active:
            need_output = any(gpu.heartbeat_counter >= Config.DEEP_SLEEP_COUNTER_THRESHOLD for gpu in self.gpus.values())
            if need_output:
                first_gpu = list(self.gpus.values())[0]
                if first_gpu.deep_sleep_start_time > 0:
                    sleep_duration = (int(time.time()) - first_gpu.deep_sleep_start_time) // 60
                    log_no_newline('\\n')
                    log(f"💤 深度休眠{{sleep_duration}}分钟")
                    # 重置所有 GPU 的心跳计数器
                    for gpu in self.gpus.values():
                        gpu.heartbeat_counter = 0
    
    def _handle_power_limit(self, gpu: GPUState):
        if not Config.ENABLE_POWER_LIMIT:
            gpu.power_state = PowerState.NORMAL
            gpu.power_trigger_timer = 0
            gpu.power_cool_timer = 0
            return
        
        # 触发功率限制
        if gpu.current_temp > Config.CRITICAL_TEMP_THRESHOLD:
            if gpu.power_state == PowerState.NORMAL:
                gpu.power_trigger_timer += 1
                log(f"GPU {{gpu.index}}: 功率限制触发 ({{gpu.power_trigger_timer}}/{{Config.CRITICAL_TEMP_DURATION}})")
                if gpu.power_trigger_timer >= Config.CRITICAL_TEMP_DURATION:
                    if NvidiaHelper.set_power_limit(gpu.index, gpu.reduced_power):
                        gpu.power_state = PowerState.POWER_LIMITED
                        log(f"GPU {{gpu.index}}: 已将功率限制至 {{gpu.reduced_power}}W (默认 {{gpu.default_power}}W)")
                        gpu.stats['power_change'] += 1
                        gpu.stats['state_changes'] += 1
                        self.stats_has_changes = True
                    else:
                        log(f"❌ GPU {{gpu.index}}: 降功率失败")
                        gpu.stats['errors'] += 1
                    gpu.power_trigger_timer = 0
        else:
            gpu.power_trigger_timer = 0
        
        # 恢复功率
        if gpu.current_temp < Config.COOL_TEMP_THRESHOLD and gpu.power_state == PowerState.POWER_LIMITED:
            gpu.power_cool_timer += 1
            log(f"GPU {{gpu.index}}: 解除功率限制 ({{gpu.power_cool_timer}}/{{Config.COOL_TEMP_DURATION}})")
            if gpu.power_cool_timer >= Config.COOL_TEMP_DURATION:
                if NvidiaHelper.set_power_limit(gpu.index, gpu.default_power):
                    gpu.power_state = PowerState.NORMAL
                    log(f"GPU {{gpu.index}}: 功率已恢复到默认 {{gpu.default_power}}W")
                    gpu.stats['power_change'] += 1
                    gpu.stats['state_changes'] += 1
                    self.stats_has_changes = True
                else:
                    log(f"❌ GPU {{gpu.index}}: 功率恢复失败")
                    gpu.stats['errors'] += 1
                gpu.power_cool_timer = 0
        else:
            gpu.power_cool_timer = 0
    
    def _handle_fan_control(self, gpu: GPUState):
        # 启用手动风扇
        if gpu.fan_state == FanState.AUTO:
            if gpu.current_temp > Config.HIGH_TEMP_THRESHOLD:
                gpu.fan_enter_timer += 1
                log(f"GPU {{gpu.index}}: 风扇手动模式触发 ({{gpu.fan_enter_timer}}/{{Config.HIGH_TEMP_DURATION}})")
                if gpu.fan_enter_timer >= Config.HIGH_TEMP_DURATION:
                    if self._enable_manual_fan_with_retry(gpu):
                        gpu.fan_state = FanState.MANUAL
                        gpu.stats['state_changes'] += 1
                        self.stats_has_changes = True
                        log(f"GPU {{gpu.index}}: 手动风扇已成功启用")
                    else:
                        log(f"❌ GPU {{gpu.index}}: 手动风扇启用失败")
                        gpu.stats['errors'] += 1
                    gpu.fan_enter_timer = 0
                    gpu.fan_recover_timer = 0
            else:
                gpu.fan_enter_timer = 0
        
        # 恢复自动风扇
        elif gpu.fan_state == FanState.MANUAL:
            if gpu.current_temp < Config.LOW_TEMP_THRESHOLD:
                gpu.fan_recover_timer += 1
                log(f"GPU {{gpu.index}}: 风扇自动模式恢复 ({{gpu.fan_recover_timer}}/{{Config.LOW_TEMP_DURATION}})")
                if gpu.fan_recover_timer >= Config.LOW_TEMP_DURATION:
                    if self._reset_auto_fan_with_retry(gpu):
                        gpu.fan_state = FanState.AUTO
                        gpu.fan_enter_timer = 0
                        gpu.fan_recover_timer = 0
                        gpu.power_trigger_timer = 0
                        gpu.power_cool_timer = 0
                        gpu.stats['state_changes'] += 1
                        self.stats_has_changes = True
                        log(f"GPU {{gpu.index}}: 自动风扇已成功恢复")
                    else:
                        log(f"❌ GPU {{gpu.index}}: 自动风扇恢复失败")
                        gpu.stats['errors'] += 1
                        gpu.fan_recover_timer = 0
            else:
                gpu.fan_recover_timer = 0
    
    def _enable_manual_fan_with_retry(self, gpu: GPUState, max_retries: int = 3) -> bool:
        for retry in range(max_retries):
            if NvidiaHelper.enable_manual_fan(gpu.index, self.display):
                success = True
                for fan in gpu.fans:
                    if not NvidiaHelper.set_fan_speed(fan, Config.MANUAL_FAN_SPEED, self.display):
                        success = False
                        break
                if success:
                    gpu.stats['fan_control'] += 1
                    gpu.stats['fan_speed_set'] += 1
                    return True
            if retry < max_retries - 1:
                log(f"⚠️ GPU {{gpu.index}}: 手动风扇启用失败，重试 ({{retry+1}}/{{max_retries}})...")
                time.sleep(1)
        return False
    
    def _reset_auto_fan_with_retry(self, gpu: GPUState, max_retries: int = 3) -> bool:
        for retry in range(max_retries):
            if NvidiaHelper.reset_auto_fan(gpu.index, self.display):
                gpu.stats['fan_control'] += 1
                return True
            if retry < max_retries - 1:
                log(f"⚠️ GPU {{gpu.index}}: 自动风扇恢复失败，重试 ({{retry+1}}/{{max_retries}})...")
                time.sleep(1)
        return False
    
    def _get_cached_fan_speeds(self, gpu: GPUState) -> str:
        current_time = time.time()
        if not gpu.fan_speeds or current_time - gpu.fan_cache_time >= Config.FAN_READ_INTERVAL:
            speeds = []
            for fan in gpu.fans:
                speed = NvidiaHelper.get_fan_speed(fan, self.display)
                if speed is not None:
                    speeds.append(f"{{speed}}%")
                else:
                    speeds.append("N/A")
            gpu.fan_speeds = "|".join(speeds)
            gpu.fan_cache_time = current_time
        return gpu.fan_speeds
    
    def _print_statistics(self):
        has_activity = self.stats_has_changes
        if not has_activity:
            for gpu in self.gpus.values():
                if gpu.max_temp >= 60:
                    has_activity = True
                    break
        
        if not has_activity:
            for gpu in self.gpus.values():
                gpu.max_temp = 0
            return
        
        new_display = NvidiaHelper.detect_display()
        if new_display and new_display != self.display:
            log(f"⚠️ 警告: CURRENT_DISPLAY Changed (旧: {{self.display}} → 新: {{new_display}})")
            self.display = new_display
        
        log("=== 统计信息 ===")
        log(f"CURRENT_DISPLAY: {{self.display}}")
        for gpu in self.gpus.values():
            log(f"GPU {{gpu.index}}:")
            log(f"  *5分钟最高温: {{gpu.max_temp}}°C")
            log(f"  **历史最高温: {{gpu.hist_max_temp}}°C**")
            log(f"  风扇控制次数: {{gpu.stats['fan_control']}}")
            log(f"  转速设置次数: {{gpu.stats['fan_speed_set']}}")
            log(f"  功率变化次数: {{gpu.stats['power_change']}}")
            log(f"  温度检查次数: {{gpu.stats['temp_checks']}}")
            log(f"  状态变化次数: {{gpu.stats['state_changes']}}")
            log(f"  初始化次数: {{gpu.stats['initializations']}}")
            log(f"  错误次数: {{gpu.stats['errors']}}")
        
        for gpu in self.gpus.values():
            gpu.max_temp = 0
    
    def _power_recovery_check(self):
        if not Config.ENABLE_POWER_LIMIT:
            return
        for gpu in self.gpus.values():
            if gpu.current_power < gpu.default_power and gpu.power_state != PowerState.POWER_LIMITED:
                log(f"⚠️ GPU {{gpu.index}}: 检测到功率异常降低 "
                    f"({{gpu.current_power}}W < {{gpu.default_power}}W)，尝试恢复...")
                if NvidiaHelper.set_power_limit(gpu.index, gpu.default_power):
                    log(f"GPU {{gpu.index}}: 功率已自动恢复到 {{gpu.default_power}}W")
                else:
                    log(f"❌ GPU {{gpu.index}}: 功率自动恢复失败")


def main():
    if os.geteuid() == 0:
        print("❌ 错误: 请不要以 root 身份运行此脚本")
        sys.exit(1)
    
    controller = GPUFanController()
    controller.run()


if __name__ == "__main__":
    main()
'''



# ==================== X 服务智能检测类 ====================

class XServiceHelper:
    """X 服务智能检测与 Xvfb 自动部署"""
    
    QUICK_DISPLAYS = [":0", ":1", ":2", ":8", ":9", ":99", ":98"]
    XVFB_DISPLAY = ":99"
    XVFB_SERVICE_NAME = "xvfb-nvidia-fan"
    
    @staticmethod
    def test_display(display: str) -> bool:
        """测试指定 DISPLAY 是否可用"""
        try:
            env = os.environ.copy()
            env['DISPLAY'] = display
            result = subprocess.run(
                ['nvidia-settings', '-q', '[gpu:0]/GPUFanControlState'],
                env=env, capture_output=True, timeout=3
            )
            return result.returncode == 0
        except:
            return False
    
    @staticmethod
    def quick_detect() -> str:
        """快速检测常用 DISPLAY"""
        print("  快速检测常用 X DISPLAY...")
        for d in XServiceHelper.QUICK_DISPLAYS:
            print(f"    检测 DISPLAY={d} ... ", end="", flush=True)
            if XServiceHelper.test_display(d):
                print("✔ 可用")
                return d
            print("✖ 不可用")
        return ""
    
    @staticmethod
    def full_detect() -> str:
        """全面检测 :0 到 :99"""
        print("  全面检测 X DISPLAY (:0 到 :99)...")
        available = []
        for i in range(100):
            d = f":{i}"
            print(f"\r    扫描进度: {i+1}/100 - 当前检测 DISPLAY={d} ", end="", flush=True)
            if XServiceHelper.test_display(d):
                available.append(d)
        print()
        if available:
            print(f"  找到 {len(available)} 个可用 X DISPLAY: {', '.join(available[:5])}")
            return available[0]
        print("  未找到任何可用 X DISPLAY")
        return ""
    
    @staticmethod
    def check_xvfb_installed() -> bool:
        """检查 Xvfb 是否已安装"""
        return shutil.which('Xvfb') is not None
    
    @staticmethod
    def install_xvfb() -> bool:
        """安装 Xvfb"""
        print("  正在安装 Xvfb...")
        try:
            if shutil.which('apt-get'):
                subprocess.run(['apt-get', 'update', '-qq'], check=True)
                subprocess.run(['apt-get', 'install', '-y', 'xvfb'], check=True)
            elif shutil.which('yum'):
                subprocess.run(['yum', 'install', '-y', 'xorg-x11-server-Xvfb'], check=True)
            elif shutil.which('dnf'):
                subprocess.run(['dnf', 'install', '-y', 'xorg-x11-server-Xvfb'], check=True)
            else:
                print("  ❌ 无法识别包管理器，请手动安装 Xvfb")
                return False
            return XServiceHelper.check_xvfb_installed()
        except Exception as e:
            print(f"  ❌ Xvfb 安装失败: {e}")
            return False
    
    @staticmethod
    def create_xvfb_service() -> bool:
        """创建 Xvfb systemd 服务"""
        print("  正在创建 Xvfb systemd 服务...")
        service_content = f"""[Unit]
Description=Xvfb Virtual Display for NVIDIA Fan Control
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/Xvfb {XServiceHelper.XVFB_DISPLAY} -screen 0 1024x768x24 -nolisten tcp
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""
        service_path = Path(f"/etc/systemd/system/{XServiceHelper.XVFB_SERVICE_NAME}.service")
        try:
            service_path.write_text(service_content)
            return True
        except Exception as e:
            print(f"  ❌ 服务文件创建失败: {e}")
            return False
    
    @staticmethod
    def start_xvfb_service() -> bool:
        """启动 Xvfb 服务"""
        print("  正在启动 Xvfb 服务...")
        try:
            subprocess.run(['systemctl', 'daemon-reload'], check=True)
            subprocess.run(['systemctl', 'enable', XServiceHelper.XVFB_SERVICE_NAME], check=True)
            subprocess.run(['systemctl', 'start', XServiceHelper.XVFB_SERVICE_NAME], check=True)
            time.sleep(2)
            
            result = subprocess.run(
                ['systemctl', 'is-active', '--quiet', XServiceHelper.XVFB_SERVICE_NAME]
            )
            if result.returncode == 0:
                print("  ✔ Xvfb 服务已启动")
                return True
            print("  ❌ Xvfb 服务启动失败")
            return False
        except Exception as e:
            print(f"  ❌ 服务启动错误: {e}")
            return False
    
    @classmethod
    def setup_xvfb(cls) -> str:
        """完整的 Xvfb 安装流程，返回可用的 DISPLAY"""
        print("  准备安装 Xvfb 虚拟 X 服务...")
        print("  这将：")
        print("    1. 安装 Xvfb 软件包")
        print("    2. 创建 systemd 服务 (开机自启)")
        print(f"    3. 启动虚拟 X 服务 (DISPLAY={cls.XVFB_DISPLAY})")
        print()
        
        response = input("  是否继续安装 Xvfb？[y/N] ").strip().lower()
        if response != 'y':
            print("  用户取消安装")
            return ""
        
        if not cls.check_xvfb_installed():
            if not cls.install_xvfb():
                return ""
        else:
            print("  ✔ Xvfb 已安装")
        
        if not cls.create_xvfb_service():
            return ""
        
        if not cls.start_xvfb_service():
            return ""
        
        if cls.test_display(cls.XVFB_DISPLAY):
            print(f"  ✔ Xvfb 虚拟 X 服务已就绪 (DISPLAY={cls.XVFB_DISPLAY})")
            return cls.XVFB_DISPLAY
        
        print("  ❌ Xvfb 服务验证失败")
        return ""
    
    @classmethod
    def detect_and_setup(cls) -> str:
        """智能检测 X 服务，必要时安装 Xvfb"""
        # 快速检测
        display = cls.quick_detect()
        if display:
            return display
        
        print()
        print("  ⚠️ 未找到可用的系统 X 服务")
        print()
        
        # 询问是否全面扫描
        response = input("  是否进行全面扫描 (检测 :0 到 :99)？[y/N] ").strip().lower()
        if response == 'y':
            display = cls.full_detect()
            if display:
                return display
        
        print()
        print("  仍然没有找到可用的系统 X 服务")
        print()
        
        # 询问是否安装 Xvfb
        return cls.setup_xvfb()


# ==================== 安装器类 ====================

class Installer:
    """一键安装器"""
    
    def __init__(self):
        self.user = None
        self.work_dir = DeployConfig.WORK_DIR
        self.found_display = ""
    
    def run(self):
        """执行安装"""
        print("=" * 50)
        print("NVIDIA GPU 智能温度管理系统 - 一键部署")
        print("版本: V2.1 (智能 X 服务检测)")
        print("=" * 50)
        print()
        
        # 检查 root 权限
        if os.geteuid() != 0:
            print("❌ 错误: 请使用 sudo 运行此脚本")
            print("   正确用法: sudo python3 gpu_fan_control_installer.py")
            sys.exit(1)
        
        # 获取实际用户
        self.user = os.environ.get('SUDO_USER')
        if not self.user:
            print("❌ 错误: 无法获取用户名")
            sys.exit(1)
        print(f"✓ 检测到用户: {self.user}")
        
        # 执行安装步骤
        self.check_environment()
        self.detect_x_service()
        self.create_directories()
        self.generate_main_script()
        self.create_systemd_service()
        self.start_service()
        
        print()
        print("=" * 50)
        print("✅ 安装完成！")
        print("=" * 50)
        self.print_usage()
    
    def check_environment(self):
        """检查系统环境"""
        print("\\n步骤 1/6: 检查系统环境...")
        
        # 检查 Python 版本
        if sys.version_info < (3, 6):
            print("❌ 错误: 需要 Python 3.6 或更高版本")
            sys.exit(1)
        print(f"✓ Python 版本: {sys.version.split()[0]}")
        
        # 检查 nvidia-smi
        if not shutil.which('nvidia-smi'):
            print("❌ 错误: 未检测到 nvidia-smi，请先安装 NVIDIA 驱动")
            sys.exit(1)
        print("✓ NVIDIA 驱动已安装")
        
        # 检查 nvidia-settings
        if not shutil.which('nvidia-settings'):
            print("❌ 错误: 未检测到 nvidia-settings，请先安装")
            sys.exit(1)
        print("✓ nvidia-settings 已安装")
    
    def detect_x_service(self):
        """检测 X 服务"""
        print("\\n步骤 2/6: 检测 X 服务...")
        
        self.found_display = XServiceHelper.detect_and_setup()
        
        if not self.found_display:
            print("❌ 错误: 无法配置 X 服务，安装中止")
            sys.exit(1)
        
        print(f"✓ X 服务已就绪: {self.found_display}")
    
    def create_directories(self):
        """创建工作目录"""
        print("\\n步骤 3/6: 创建工作目录...")
        Path(self.work_dir).mkdir(parents=True, exist_ok=True)
        Path(DeployConfig.LOG_DIR).mkdir(parents=True, exist_ok=True)
        print(f"✓ 工作目录已创建: {self.work_dir}")
    
    def generate_main_script(self):
        """生成主控制脚本"""
        print("\\n步骤 4/6: 生成主控制脚本...")
        
        script_path = Path(self.work_dir) / "gpu_fan_control.py"
        
        # 格式化脚本内容
        script_content = MAIN_SCRIPT_CONTENT.format(
            timestamp=datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
            HIGH_TEMP_THRESHOLD=DeployConfig.HIGH_TEMP_THRESHOLD,
            CRITICAL_TEMP_THRESHOLD=DeployConfig.CRITICAL_TEMP_THRESHOLD,
            LOW_TEMP_THRESHOLD=DeployConfig.LOW_TEMP_THRESHOLD,
            COOL_TEMP_THRESHOLD=DeployConfig.COOL_TEMP_THRESHOLD,
            HIGH_TEMP_DURATION=DeployConfig.HIGH_TEMP_DURATION,
            CRITICAL_TEMP_DURATION=DeployConfig.CRITICAL_TEMP_DURATION,
            LOW_TEMP_DURATION=DeployConfig.LOW_TEMP_DURATION,
            COOL_TEMP_DURATION=DeployConfig.COOL_TEMP_DURATION,
            MANUAL_FAN_SPEED=DeployConfig.MANUAL_FAN_SPEED,
            REDUCED_POWER_PERCENT=DeployConfig.REDUCED_POWER_PERCENT,
            ENABLE_POWER_LIMIT=DeployConfig.ENABLE_POWER_LIMIT,
            CHECK_INTERVAL=DeployConfig.CHECK_INTERVAL,
            STATS_INTERVAL=DeployConfig.STATS_INTERVAL,
            POWER_CHECK_INTERVAL=DeployConfig.POWER_CHECK_INTERVAL,
            FAN_READ_INTERVAL=DeployConfig.FAN_READ_INTERVAL,
            ENABLE_DEEP_SLEEP=DeployConfig.ENABLE_DEEP_SLEEP,
            DEEP_SLEEP_THRESHOLD=DeployConfig.DEEP_SLEEP_THRESHOLD,
            DEEP_SLEEP_MULTIPLIER=DeployConfig.DEEP_SLEEP_MULTIPLIER,
            HEARTBEAT_OUTPUT_INTERVAL=DeployConfig.HEARTBEAT_OUTPUT_INTERVAL,
            DEEP_SLEEP_OUTPUT_INTERVAL=DeployConfig.DEEP_SLEEP_OUTPUT_INTERVAL,
            HEARTBEAT_VERBOSE_OUTPUT=DeployConfig.HEARTBEAT_VERBOSE_OUTPUT,
            LOG_FILE=DeployConfig.LOG_FILE,
            LOG_DIR=DeployConfig.LOG_DIR
        )
        
        # 写入文件
        script_path.write_text(script_content)
        script_path.chmod(0o755)
        
        print(f"✓ 主控制脚本已生成: {script_path}")
    
    def create_systemd_service(self):
        """创建 systemd 服务"""
        print("\\n步骤 5/6: 配置 systemd 服务...")
        
        # 获取用户的 home 目录
        user_home = Path(f"/home/{self.user}")
        systemd_dir = user_home / ".config/systemd/user"
        systemd_dir.mkdir(parents=True, exist_ok=True)
        
        service_content = f"""[Unit]
Description=NVIDIA GPU Auto Fan Control Service (Python v23)
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 {self.work_dir}/gpu_fan_control.py
Restart=on-failure
RestartSec=10s
StandardOutput=file:{DeployConfig.LOG_FILE}
StandardError=file:{DeployConfig.LOG_FILE}

[Install]
WantedBy=default.target
"""
        
        service_path = systemd_dir / "gpu-fan-control.service"
        service_path.write_text(service_content)
        
        # 修改所有权为实际用户
        import pwd
        uid = pwd.getpwnam(self.user).pw_uid
        gid = pwd.getpwnam(self.user).pw_gid
        
        for path in [systemd_dir, service_path]:
            os.chown(path, uid, gid)
        
        print("✓ systemd 服务配置已创建")
    
    def start_service(self):
        """启动服务"""
        print("\\n步骤 6/6: 启动服务...")
        
        # 以用户身份执行 systemctl 命令
        def run_as_user(cmd):
            return subprocess.run(
                ['sudo', '-u', self.user] + cmd,
                capture_output=True,
                text=True
            )
        
        # 重新加载 systemd
        run_as_user(['systemctl', '--user', 'daemon-reload'])
        
        # 启用服务
        run_as_user(['systemctl', '--user', 'enable', 'gpu-fan-control.service'])
        print("✓ 服务已启用（开机自启）")
        
        # 启用 lingering
        subprocess.run(['loginctl', 'enable-linger', self.user], capture_output=True)
        print("✓ 用户 lingering 已启用")
        
        # 启动服务
        run_as_user(['systemctl', '--user', 'start', 'gpu-fan-control.service'])
        
        # 等待服务启动
        time.sleep(2)
        
        # 检查服务状态
        result = run_as_user(['systemctl', '--user', 'is-active', 'gpu-fan-control.service'])
        if result.stdout.strip() == 'active':
            print("✓ 服务已成功启动")
        else:
            print("⚠️  警告: 服务可能未正常启动，请检查日志")
    
    def print_usage(self):
        """打印使用说明"""
        print()
        print("查看实时日志:")
        print(f"  tail -f {DeployConfig.LOG_FILE}")
        print()
        print("管理服务 (以用户身份运行):")
        print("  systemctl --user start gpu-fan-control.service    # 启动")
        print("  systemctl --user stop gpu-fan-control.service     # 停止")
        print("  systemctl --user restart gpu-fan-control.service  # 重启")
        print("  systemctl --user status gpu-fan-control.service   # 状态")
        print()
        print("修改配置:")
        print(f"  编辑 {self.work_dir}/gpu_fan_control.py 中的 Config 类")
        print("  修改后重启服务: systemctl --user restart gpu-fan-control.service")
        print()
        print("深度休眠功能:")
        print("  - 温度稳定 15 分钟后自动进入")
        print("  - 检测间隔从 5 秒延长到 50 秒")
        print("  - 温度变化 > 2°C 立即唤醒")
        print()


# ==================== 主入口 ====================

if __name__ == "__main__":
    installer = Installer()
    installer.run()
