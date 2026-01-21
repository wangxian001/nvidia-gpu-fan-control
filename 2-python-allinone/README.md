# NVIDIA GPU 智能温度管理系统 - Python 一键安装版

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
cd nvidia-gpu-fan-control/2-python-allinone

# 方式 B：SCP 上传（如无法访问 GitHub）
scp gpu_fan_control_installer.py user@server:/tmp/
cd /tmp
```

### 步骤 2：安装

```bash
sudo python3 gpu_fan_control_installer.py
```

**安装流程（6步）：**
1. ✅ 检查系统环境（Python 版本、NVIDIA 驱动）
2. ✅ **🆕 检测 X 服务**（自动解决 X 服务问题）
3. ✅ 创建工作目录 `/home/fan_control`
4. ✅ 生成主控制脚本
5. ✅ 配置 systemd 用户服务
6. ✅ 启动服务

---

## 🔧 X 服务智能检测

安装过程中会自动进行 X 服务检测：

1. **快速检测**：检测常用 DISPLAY (:0, :1, :2, :8, :9, :99, :98)
2. **全面扫描**：如果快速检测失败，提示是否扫描 :0 到 :99
3. **Xvfb 自动安装**：如果仍未找到，提示安装 Xvfb 虚拟显示
4. **服务持久化**：Xvfb 作为 systemd 服务开机自启

---

## ⚙️ 配置修改

安装前可修改 `DeployConfig` 类中的参数：

```python
class DeployConfig:
    # 温度阈值 (°C)
    HIGH_TEMP_THRESHOLD = 70      # 启动手动风扇
    CRITICAL_TEMP_THRESHOLD = 75  # 启动功率限制
    LOW_TEMP_THRESHOLD = 65       # 恢复自动风扇
    COOL_TEMP_THRESHOLD = 45      # 恢复默认功率
    
    # 风扇设置
    MANUAL_FAN_SPEED = 75         # 手动风扇转速 (0-100)
    
    # 功率限制
    ENABLE_POWER_LIMIT = True     # True=启用, False=禁用
    REDUCED_POWER_PERCENT = 75    # 降低功率百分比
    
    # 深度休眠
    ENABLE_DEEP_SLEEP = True      # True=启用, False=禁用
    DEEP_SLEEP_THRESHOLD = 900    # 15分钟后进入
    DEEP_SLEEP_MULTIPLIER = 10    # 间隔延长10倍
```

---

## 🔄 服务管理

```bash
# 启动
systemctl --user start gpu-fan-control.service

# 停止
systemctl --user stop gpu-fan-control.service

# 重启
systemctl --user restart gpu-fan-control.service

# 查看状态
systemctl --user status gpu-fan-control.service

# 查看实时日志
tail -f /home/fan_control/fan_control.log
```

---

## 📂 生成的文件

```
/home/fan_control/
├── gpu_fan_control.py     # 生成的主控制脚本
├── fan_control.log        # 当前日志
└── log/                   # 历史日志归档

~/.config/systemd/user/
└── gpu-fan-control.service  # 用户服务配置
```

---

## 🐛 常见问题

### Q: 安装时提示 "未找到可用的系统 X 服务"

按照提示选择：
1. 输入 `y` 进行全面扫描 (:0 到 :99)
2. 如果仍未找到，输入 `y` 安装 Xvfb

### Q: 需要 root 权限但不想用 sudo

安装程序需要 root 权限来安装 Xvfb 和配置 systemd 服务。

### Q: 如何卸载

```bash
systemctl --user stop gpu-fan-control.service
systemctl --user disable gpu-fan-control.service
rm -rf /home/fan_control
rm ~/.config/systemd/user/gpu-fan-control.service
```

---

## 📋 系统要求

| 项目 | 要求 |
|------|------|
| Python | 3.6+ |
| 操作系统 | Linux (支持 systemd) |
| NVIDIA 驱动 | nvidia-smi, nvidia-settings |
| X 服务器 | Xorg, Xvfb, 或 BMC 虚拟显示器 |

---

## 🆚 与 Bash 版本对比

| 项目 | Python 版本 | Bash 版本 |
|------|-------------|-----------|
| 文件数 | 1 个 | 4 个 |
| 安装方式 | `sudo python3 installer.py` | `bash install.sh` |
| X 服务检测 | ✅ 内置 | ✅ 外挂工具 |
| 深度休眠 | ✅ 支持 | ✅ 支持 |
| 适合场景 | 快速部署 | 生产环境 |

---

**版本**: V2.1  
**发布日期**: 2026-01-21
