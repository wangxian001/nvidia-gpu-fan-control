# NVIDIA GPU 智能温度管理系统

## 概述

本系统用于自动控制 NVIDIA GPU 风扇转速和功率策略，通过持续监测 GPU 温度，自动在**自动风扇模式**和**手动风扇模式**之间切换，并在温度过高时自动降低功率，实现温度与噪音/功耗之间的平衡。

### 适用场景

- 多 GPU 工作站/服务器（Ubuntu + NVIDIA + Xorg + LightDM 自动登录）
- GPU 长期满载运行，需要自动化散热管理
- 需要控制风扇噪音（手动模式比自动模式更安静）
- **不适用于**：无头服务器（没有 X Display）、Wayland 显示服务器、非 Ubuntu 发行版（需适配）

### 核心机制

```
┌─────────────────────────────────────────────────────────┐
│                   温度监测循环 (每 5 秒)                   │
│                                                         │
│  低温 (< 65°C) ──────→ 自动风扇模式 (GPU 自行管理)         │
│  高温 (> 70°C, 持续3秒) → 手动风扇模式 (75% 转速)         │
│  临界 (> 75°C, 持续6秒) → 手动风扇 + 降低功率到 75%        │
│  冷却 (< 45°C, 持续15秒) → 恢复默认功率                    │
│                                                         │
│  温度稳定时 → 仅输出心跳"." → 15分钟后 → 深度休眠          │
│                                                         │
│  每分钟 → 功率自救检查 (功率意外降低时自动恢复)              │
│  每5分钟 → 输出统计信息 (最高温/切换次数/错误数)            │
└─────────────────────────────────────────────────────────┘
```

---

## 文件构成

| 文件 | 路径 | 说明 |
|------|------|------|
| `fan_control.sh` | `/home/fan_control/fan_control.sh` | 主控脚本（核心逻辑、状态机、温度监测循环） |
| `nvidia-fan-helper` | `/usr/local/bin/nvidia-fan-helper` | 辅助包装脚本（DISPLAY 检测、风扇控制、功率控制） |
| `fan-control.service` | `~/.config/systemd/user/fan-control.service` | systemd user 服务单元 |
| `xdiag/xdiag.sh` | `/home/fan_control/xdiag/xdiag.sh` | X Display 环境诊断脚本（故障排查用） |
| `xdiag/xdiag.service` | `/etc/systemd/system/xdiag.service` | X Display 诊断 systemd 服务（已禁用） |

---

## 程序原理详解

### 1. X Display 认证链

NVIDIA 风扇控制依赖 `nvidia-settings` 命令，该命令必须连接 X server。X server 的访问控制是风扇控制能否成功的关键。

**认证流程：**

```
lightdm 启动 Xorg :0
    ↓
lightdm 写入 /var/run/lightdm/root/:0 (root 的 cookie 文件)
    ↓
lightdm 自动登录 wangxian
    ↓
gnome-session 启动
    ↓ (约 4 秒后)
gnome-session 将 DISPLAY=:0, XAUTHORITY=... 注入 systemd --user 环境
    ↓
fan-control.service (在 ExecStartPre sleep 120 后才 fork 主进程)
    ↓
fan_control.sh 从父进程继承到 DISPLAY/XAUTHORITY
    ↓
nvidia-settings 连接 X server :0 —— 认证通过！
```

**关键发现：** 进程的环境变量在 `fork()` 那一刻凝固。systemd --user 启动初期的 DISPLAY 环境变量为空，此后 gnome-session 注入的变量仅影响后续新进程。这就是为什么 fan-control.service 必须延迟 120 秒再启动——在 fork 之前等环境就绪。

### 2. DISPLAY 遍历检测

`nvidia-fan-helper` 中的 `detect_display()` 函数采用两级检测：

```
路径1: $DISPLAY 非空 且 nvidia-settings -q 成功 → 直接用
        （开机后的正常路径，睡眠 120s 后几乎 100% 命中）

路径2: 遍历候选列表 :0 :1 :2 :8 :9 :99 :98
        依次尝试 DISPLAY=$d nvidia-settings -q
        （应对 DISPLAY 编号漂移的情况）
```

**DISPLAY 漂移说明：** 当系统连接多个显示器或切换显示输出时，X server 的编号可能从 `:0` 变为 `:1`。这就是为什么要用遍历而不是硬编码 `:0`。

### 3. X 认证机制

本系统的认证机制基于 **SI:localuser:wangxian**（Server Interpreted: local user）。当 wangxian 用户直接从本地连接 X server（不经过 SSH），X server 会通过该机制自动放行认证，无需 `.Xauthority` 文件。

```
wangxian 身份 → 本机进程 → X server → SI:localuser:wangxian = 放行
root 身份     → sudo 后进程 → X server → SI:localuser:wangxian = 拒绝！
                             （root ≠ wangxian, SI 列表不匹配）
```

这就是为什么 `nvidia-fan-helper` 的部分操作**去掉 `sudo`** 后反而能正常工作——`sudo` 会把进程身份变成 `root`，而 `root` 不在 X server 的 SI 信任列表中。

**但注意：** `set_power_limit` 仍然需要 `sudo`，因为它调用的是 `nvidia-smi -pl`，该命令需 root 权限且不依赖 X Display。

### 4. 状态机

每块 GPU 独立运行以下状态机：

```
         温度 > 70°C (持续 3 秒)
  AUTO ─────────────────────────→ MANUAL
   ↑                                  │
   │                                  │ 温度 < 65°C (持续 10 秒)
   └──────────────────────────────────┘

  MANUAL 状态下:
    温度 > 75°C (持续 6 秒) → 同时启动功率限制
    温度 < 45°C (持续 15 秒) → 恢复默认功率
```

### 5. 心跳与深度休眠

当 GPU 温度长时间稳定且处于 AUTO 模式时，系统进入**心跳模式**，仅每 60 秒输出一次完整信息，其余周期仅打点 `.`。如果心跳持续超过 15 分钟，自动进入**深度休眠模式**，检测间隔从 5 秒延长到 50 秒，每 10 分钟输出一次"深度休眠 N 分钟"。

深度休眠在**所有 GPU 都满足条件时**才全局激活；任一 GPU 温度波动即唤醒所有 GPU。

---

## 配置参数详解

所有配置参数位于 `fan_control.sh` 顶部的"用户配置区"（约第 29-124 行）。

### 温度阈值

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `HIGH_TEMP_THRESHOLD` | 70°C | 超过此值启动手动风扇 |
| `CRITICAL_TEMP_THRESHOLD` | 75°C | 超过此值启动功率限制 |
| `LOW_TEMP_THRESHOLD` | 65°C | 低于此值恢复自动风扇 |
| `COOL_TEMP_THRESHOLD` | 45°C | 低于此值恢复默认功率 |

### 持续时间

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `HIGH_TEMP_DURATION` | 3秒 | 温度超阈值持续多久后启用手动风扇 |
| `CRITICAL_TEMP_DURATION` | 6秒 | 温度超临界值持续多久后降低功率 |
| `LOW_TEMP_DURATION` | 10秒 | 温度低于阈值持续多久后恢复自动风扇 |
| `COOL_TEMP_DURATION` | 15秒 | 温度低于冷却阈值持续多久后恢复功率 |

### 风扇控制

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `MANUAL_FAN_SPEED` | 75% | 手动模式下的风扇转速 |

### 功率限制

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `REDUCED_POWER_PERCENT` | 75% | 功率限制到默认功率的百分比 |
| `ENABLE_POWER_LIMIT` | 1 | 功率限制总开关（1=启用 / 0=禁用） |

### 系统参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `CHECK_INTERVAL` | 5秒 | 主循环检查间隔 |
| `STATS_INTERVAL` | 300秒 | 统计信息输出间隔 |
| `POWER_CHECK_INTERVAL` | 60秒 | 功率自救检查间隔 |
| `HEARTBEAT_OUTPUT_INTERVAL` | 60秒 | 心跳模式下完整输出的间隔 |

### 深度休眠

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `ENABLE_DEEP_SLEEP` | 1 | 深度休眠开关（1=启用 / 0=禁用） |
| `DEEP_SLEEP_THRESHOLD` | 900秒 | 进入深度休眠所需心跳持续时间 |
| `DEEP_SLEEP_MULTIPLIER` | 10倍 | 深度休眠时检测间隔扩大倍数 |

---

## 部署说明

### 前置要求

- Ubuntu 服务器（已安装 **LightDM** 并配置自动登录）
- NVIDIA 驱动已安装（`nvidia-smi` 和 `nvidia-settings` 可用）
- 用户已登录桌面（`systemctl --user` 可用）
- SSH 密钥已配置（免密码登录）

> 如果使用 GDM 替代 LightDM，`XAUTHORITY` 文件路径不同，可能需要相应调整。

### 快速部署

#### 方法一：使用部署脚本（推荐）

在本地工作目录执行：

```bash
cd nvidia-gpu-fan-control
chmod +x deploy.sh
./deploy.sh 192.168.2.167 wangxian
```

部署脚本自动完成：
1. 检查 SSH 连接
2. 上传所有文件到服务器
3. 自动备份旧文件 → 安装新文件
4. 注册并启动 systemd 服务
5. 验证服务状态

#### 方法二：手动部署

```bash
# 1. 在服务器创建目录结构
ssh wangxian@192.168.2.167 "sudo mkdir -p /home/fan_control/xdiag /home/wangxian/.config/systemd/user"

# 2. 上传文件（nvidia-fan-helper 放到 /tmp 再用 sudo 移入）
scp fan_control.sh         wangxian@192.168.2.167:/tmp/
scp nvidia-fan-helper      wangxian@192.168.2.167:/tmp/
scp fan-control.service    wangxian@192.168.2.167:/tmp/
scp xdiag/xdiag.sh         wangxian@192.168.2.167:/tmp/

# 3. SSH 登录后安装
ssh wangxian@192.168.2.167
sudo cp /tmp/nvidia-fan-helper /usr/local/bin/nvidia-fan-helper
sudo chmod 755 /usr/local/bin/nvidia-fan-helper
sudo chown root:root /usr/local/bin/nvidia-fan-helper

sudo cp /tmp/fan_control.sh /home/fan_control/fan_control.sh
sudo chmod 755 /home/fan_control/fan_control.sh
sudo chown wangxian:wangxian /home/fan_control/fan_control.sh

cp /tmp/xdiag.sh /home/fan_control/xdiag/xdiag.sh
chmod 755 /home/fan_control/xdiag/xdiag.sh

cp /tmp/fan-control.service /home/wangxian/.config/systemd/user/fan-control.service

rm -f /tmp/fan_control.sh /tmp/nvidia-fan-helper /tmp/fan-control.service /tmp/xdiag.sh

# 4. 注册并启动服务
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user enable fan-control.service
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start fan-control.service

# 5. 验证
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status fan-control.service
tail -f /home/fan_control/fan_control.log
```

### 首次部署后的验证

1. **立即验证：** 查看日志确认 DISPLAY 检测成功
   ```bash
   tail -20 /home/fan_control/fan_control.log
   # 应看到: ✔ 当前环境 DISPLAY=:0 可用
   #         ✔ 找到可用 X DISPLAY=:0
   ```

2. **重启验证：** 重启服务器，等待 2 分钟后检查
   ```bash
   sudo reboot
   # 2 分钟后重新 SSH 登录
   tail -20 /home/fan_control/fan_control.log
   ```

---

## 部署注意事项

### ⚠️ 关键点

1. **延迟 120 秒是必须的**
   - `ExecStartPre=/bin/sleep 120` 是解决开机找不到 DISPLAY 的唯一关键
   - 不能把 sleep 放到脚本内部——脚本 start 时进程已 fork，环境已凝固
   - 风扇控制通过 `nvidia-settings` 依赖 X Display（黑白屏 N 卡不支持通过 nvidia-smi 设置风扇）

2. **`nvidia-fan-helper` 必须在 sudoers 中配置 NOPASSWD**
   ```bash
   sudo visudo -f /etc/sudoers.d/nvidia-fan-helper
   # 添加一行:
   wangxian ALL=(ALL) NOPASSWD: /usr/local/bin/nvidia-fan-helper
   ```
   - fan_control.sh 中第 300 行的 `set_power_limit` 调用 `sudo helper set_power_limit`，需要无密码 sudo
   - 如果未配置，`set_power_limit` 会因等待密码而阻塞，导致服务卡死

3. **XDG_RUNTIME_DIR 环境**
   - systemd --user 命令需要 `XDG_RUNTIME_DIR=/run/user/1000`
   - 建议在系统 `.bashrc` 中加入:
     ```bash
     export XDG_RUNTIME_DIR=/run/user/1000
     ```

4. **X server 必须保持运行**
   - 本系统依赖 X server（lightdm 自动登录），如果切换到 Wayland 或关闭桌面，风扇控制会失效
   - 无头服务器（不接显示器）需要显卡欺骗器（如 NVIDIA 的 `AllowEmptyInitialConfiguration` 或虚拟显示器）

5. **DISPLAY 漂移**
   - 代码通过遍历 `:0 :1 :2 :8 :9 :99 :98` 应对 DISPLAY 编号变化
   - 接多台显示器或多显卡时可能发生漂移，遍历机制保障了兼容性

### 日志管理

- 日志文件：`/home/fan_control/fan_control.log`
- 每次启动时，旧日志自动归档到 `/home/fan_control/log/` 子目录
- 日志命名格式：`fan_control_YYYYMMDD_HHMMSS.log`
- 建议定期清理归档日志，或配置 logrotate

---

## 日常使用

```bash
# 查看服务状态
systemctl --user status fan-control.service

# 实时查看日志
tail -f /home/fan_control/fan_control.log

# 重启服务（修改配置后）
systemctl --user restart fan-control.service

# 停止服务
systemctl --user stop fan-control.service

# 开机自启管理
systemctl --user enable fan-control.service    # 启用
systemctl --user disable fan-control.service   # 禁用

# 查看完整日志最后 50 行
tail -50 /home/fan_control/fan_control.log
```

---

## 故障排查

### 症状: 开机后风扇不转或全速

1. 检查服务是否运行:
   ```bash
   systemctl --user status fan-control.service
   ```

2. 检查日志是否有错误:
   ```bash
   grep "错误" /home/fan_control/fan_control.log
   ```

3. 检查 DISPLAY 检测状态:
   ```bash
   grep "DISPLAY" /home/fan_control/fan_control.log
   # 应看到 ✔ 开头
   ```

### 症状: 日志中出现大量错误

```bash
# 统计错误次数
grep -c "错误" /home/fan_control/fan_control.log

# 查看详细错误
grep "错误" /home/fan_control/fan_control.log | tail -20
```

### 症状: nvidia-settings 返回错误

手动测试 DISPLAY 检测:
```bash
/usr/local/bin/nvidia-fan-helper get_display_v
```

### 诊断工具

本系统附带 X Display 环境诊断脚本：
```bash
# 启用诊断（开机跑 5 分钟，采集 300 次采样）
sudo systemctl enable xdiag.service
sudo reboot

# 诊断完成后查看结果
cat /home/fan_control/xdiag.log | grep -E "TEST_|DISPLAY=:"

# 用完记得关闭（避免每次开机都跑 5 分钟）
sudo systemctl disable xdiag.service
```

诊断脚本会每 1 秒采样一次，持续 5 分钟，记录：
- `.Xauthority` 文件的生成时序
- X server 的启动状态
- SI:localuser 和 xhost 访问控制列表
- systemd --user 环境变量的注入时序
- 四种不同的 DISPLAY 检测方式的效果对比

---

## 版本历史

| 版本 | 日期 | 说明 |
|------|------|------|
| V2.1 Beta | 2026-01-20 | 原始版本，包含完整状态机和风扇控制 |
| V3 | 2026-06-30 | **修复开机找不到 DISPLAY 问题**，优化认证机制 |

### V3 修复的核心问题

**问题现象：** 每次服务器重启后，fan_control.sh 报 736+ 次错误，找不到 X Display，需要手动重启服务才能恢复。

**根因：** fan-control.service（user systemd 单元）在 `graphical-session.target` 就绪后立即启动，但此时 gnome-session 尚未将 DISPLAY/XAUTHORITY 注入 systemd --user 环境（实测存在约 4 秒窗口期）。进程 fork 时环境变量为空，`detect_display()` 路径 1 跳过（`$DISPLAY` 为空），路径 2 遍历所有候选 DISPLAY 也会因周围环境的 XAUTHORITY 缺失而认证失败——且进程一旦 fork，环境变量永不更新。

**修复方案：**
1. **`ExecStartPre=/bin/sleep 120`**（唯一必需的修复）—— 延迟 120 秒后才 fork 主进程，届时桌面环境完全就绪
2. **去掉 `get_display_v` 和 `reset_auto_d` 的 `sudo`**（非必需，但增加了鲁棒性）—— 去掉后 helper 以 wangxian 身份运行，可走 SI:localuser 机制通过 X 认证

**验证结果：** 经过 3 次重启验证，日志显示 `✔ 当前环境 DISPLAY=:0 可用`，零错误。

---

## 许可证

采用 **MIT 许可证**。详见仓库中的 [LICENSE](./LICENSE) 文件。
