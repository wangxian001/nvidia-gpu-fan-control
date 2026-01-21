# NVIDIA GPU 智能温度管理系统 - Bash 版本

## 📦 版本信息

- **版本**: V2.1
- **发布日期**: 2026-01-21
- **核心特性**: 智能 X 服务检测 + 深度休眠模式

---

## 🚀 快速安装

### 步骤 1：下载

```bash
# 方式 A：Git 克隆（推荐）
git clone https://github.com/wangxian001/nvidia-gpu-fan-control.git
cd nvidia-gpu-fan-control/1-bash-version

# 方式 B：SCP 上传（如无法访问 GitHub）
scp -r 1-bash-version/ user@server:/tmp/
cd /tmp/1-bash-version
```

### 步骤 2：安装

```bash
bash install.sh
```

**安装流程（7步）：**
1. ✅ 检查系统环境（NVIDIA 驱动、nvidia-settings）
2. ✅ **🆕 检测 X 服务**（自动解决 X 服务问题）
3. ✅ 创建工作目录 `/home/fan_control`
4. ✅ 安装脚本文件
5. ✅ 配置 sudo 免密
6. ✅ 配置 systemd 用户服务
7. ✅ 启动服务

---

## 📂 文件说明

| 文件 | 说明 |
|------|------|
| `fan_control.sh` | 主控制脚本 (51 KB) |
| `nvidia-fan-helper` | 包装脚本，封装 nvidia-settings 调用 |
| `install.sh` | 安装脚本 |
| `x_service_helper.sh` | 🆕 X 服务智能检测工具 |

---

## 🔧 X 服务智能检测工具

当安装过程中检测不到可用 X 服务时，会自动调用此工具。

### 功能特性

- **快速检测**: 检测常用 DISPLAY (:0, :1, :2, :8, :9, :99, :98)
- **全面扫描**: 遍历 :0 到 :99
- **Xvfb 自动安装**: 支持 apt/yum/dnf/pacman
- **服务持久化**: 创建 systemd 服务开机自启
- **环境诊断**: 输出详细诊断报告

### 独立使用

```bash
# 交互式安装向导
sudo bash x_service_helper.sh

# 查看诊断报告
sudo bash x_service_helper.sh --diagnose

# 快速检测
sudo bash x_service_helper.sh --quick

# 全面扫描
sudo bash x_service_helper.sh --full

# 直接安装 Xvfb
sudo bash x_service_helper.sh --install-xvfb
```

---

## ⚙️ 配置参数

编辑 `/home/fan_control/fan_control.sh` 顶部的配置区：

```bash
# 温度阈值 (°C)
HIGH_TEMP_THRESHOLD=70      # 启动手动风扇
CRITICAL_TEMP_THRESHOLD=75  # 启动功率限制
LOW_TEMP_THRESHOLD=65       # 恢复自动风扇
COOL_TEMP_THRESHOLD=45      # 恢复默认功率

# 风扇设置
MANUAL_FAN_SPEED=75         # 手动风扇转速 (0-100)

# 功率限制
ENABLE_POWER_LIMIT=1        # 1=启用, 0=禁用
REDUCED_POWER_PERCENT=75    # 降低功率百分比

# 深度休眠
ENABLE_DEEP_SLEEP=1         # 1=启用, 0=禁用
DEEP_SLEEP_THRESHOLD=900    # 15分钟后进入
DEEP_SLEEP_MULTIPLIER=10    # 间隔延长10倍

# 日志控制
HEARTBEAT_VERBOSE_OUTPUT=0  # 0=简洁打点, 1=详细输出
```

修改后重启服务：
```bash
systemctl --user restart fan-control.service
```

---

## 🔄 服务管理

```bash
# 启动
systemctl --user start fan-control.service

# 停止
systemctl --user stop fan-control.service

# 重启
systemctl --user restart fan-control.service

# 查看状态
systemctl --user status fan-control.service

# 查看实时日志
tail -f /home/fan_control/fan_control.log

# 查看服务日志
journalctl --user -u fan-control.service -f
```

---

## 🐛 常见问题

### Q: 安装时提示 "未找到可用的系统 X 服务"

安装脚本会自动调用 `x_service_helper.sh`，按提示操作即可。

### Q: 服务启动失败

1. 检查 X 服务：`sudo bash x_service_helper.sh --diagnose`
2. 检查日志：`tail -50 /home/fan_control/fan_control.log`

### Q: 如何卸载

```bash
systemctl --user stop fan-control.service
systemctl --user disable fan-control.service
rm -rf /home/fan_control
rm ~/.config/systemd/user/fan-control.service
sudo rm /usr/local/bin/nvidia-fan-helper
sudo rm /etc/sudoers.d/nvidia-fan-control
```

---

## 📊 日志位置

```
/home/fan_control/
├── fan_control.log        # 当前日志
└── log/                   # 历史日志归档
    ├── fan_control_20260120_100000.log
    └── ...
```

---

**版本**: V2.1  
**发布日期**: 2026-01-21
