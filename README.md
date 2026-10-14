# Auto Suspend

> Linux 下基于空闲检测的自动休眠（suspend）工具 + Web 管理控制台。

<!-- 徽章（badge）占位：正式开源时替换为真实地址 -->
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux%20%2F%20systemd-blue)]()
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25)]()
[![Web](https://img.shields.io/badge/Web-Flask%20%2B%20Vanilla%20JS-green)]()

---

## 项目简介

auto-suspend 是一款运行在 Linux（systemd 环境）上的自动挂起工具。它通过周期性的
空闲检测，综合 **SSH/Web 用户会话、CPU 负载、物理网卡流量、机械硬盘/固态硬盘 IO**
等多个维度判断系统是否真正空闲，在满足「连续空闲时长 + 允许休眠窗口 + 非唤醒冷却期」
条件后自动执行 `systemctl suspend`，并在唤醒后自动恢复机械硬盘起转与挂载。适用于
**服务器节能、NAS 低功耗运行、家庭自动化**等长时间无人值守的场景。

核心价值在于**「安全」与「省心」**：

- **Fail-safe**：任何异常都不会误触发休眠；连续快速唤醒（异常唤醒）会自动禁用脚本，
  避免设备反复开关机。
- **免手动调参**：各 IO/流量阈值基于历史采样 **P90 自动学习**并叠加安全因子，
  能自适应不同负载特征。
- **可观测、可管理**：所有状态迁移与忙碌原因写入 journald，并提供 Web 控制台查看
  状态、历史图表、日志与在线调整配置。

---

## 功能特性

- **状态机驱动的自动休眠**：显式管理 `ACTIVE → IDLE → SUSPENDING → COOLDOWN` 四态，
  状态原子持久化，异常重启可恢复。
- **多维度空闲判定**：SSH 会话、Web 访问、CPU 5 分钟负载、物理网卡流量、HDD/SSD IO；
  高优先级指标（用户/Web/CPU）优先判定，IO 指标仅在真实空闲时采样。
- **阈值自动学习（P90）**：基于时间戳采样自动计算 P90 阈值并叠加安全因子，无需手动调参。
- **允许休眠窗口**：按 `hour_start / hour_end` 限定可休眠时段，支持全天、当天、跨天窗口。
- **休眠前准备**：停转机械硬盘（卸载 → sync → `hdparm -y`）、停用蓝牙、禁用 USB 唤醒、
  开启网卡 WOL（ACPI + Magic Packet 双层）。
- **唤醒自动恢复**：systemd 钩子独立重扫 `/etc/fstab`，按物理盘去重后串行起转 HDD、
  恢复挂载、延迟恢复 NCQ（防启动大电流、防误唤醒）。
- **异常唤醒保护**：休眠时长 < 60s 计失败，连续 2 次自动创建禁用标记（`/run/auto-suspend/disable`），
  可在 Web 上一键解除。
- **配置热加载**：脚本每次运行重新读取 `config.json`，修改配置无需重启服务。
- **日志记录**：状态迁移、忙碌原因、休眠/唤醒时长均写入 `journalctl -t auto-suspend`。
- **Web 管理控制台**（Flask + 原生 JS，深色主题）：
  - 总览：当前状态、休眠开关、休眠时长、连续运行、状态变更横幅、系统信息；
  - 图表：各盘/网络吞吐量卡片 + 历史采样柱状图（时间戳横轴、忙期斜纹、P90 曲线、时间范围切换，采样点稀疏时柱宽自动限制，避免与忙区重叠）；
  - 配置：可视化编辑全部参数（开关/滑块/联动提示/默认值/差异高亮）；
  - 日志：实时读取 journalctl 日志。

---

## 系统要求

- **操作系统**：Linux，使用 systemd（systemd-timer + systemd-sleep）
- **内核**：现代主流发行版内核即可（无需特定版本；依赖 `/sys`、`/proc` 接口）
- **Shell**：Bash 4+（含 `declare -g`、`nameref`、进程替换等特性）
- **依赖软件**：
  - 主脚本：`jq`（JSON 配置解析，缺失时回退内置默认值）、`systemd-cat`、
    `hdparm`、`ethtool`、`udevadm`、`findmnt`、`lsblk`、`blockdev`、`loginctl`
  - Web UI：Python 3 + Flask
- **权限要求**：`root`（执行 `systemctl suspend`、卸载/挂载磁盘、写 `/run/auto-suspend`）
- **其他**：机械硬盘的 `/etc/fstab` 源列建议使用 `UUID=` / `LABEL=` 形式（唤醒钩子
  依赖 `findfs` 解析）

---

## 安装步骤

### 1. 获取源码

```bash
git clone <仓库地址> auto-suspend
cd auto-suspend
```

### 2. 依赖安装（Debian/Ubuntu 示例）

```bash
# 主脚本依赖
sudo apt-get update
sudo apt-get install -y jq hdparm ethtool util-linux udev

# Web UI 依赖
sudo apt-get install -y python3 python3-pip
sudo pip3 install flask
```

> `systemd-cat`、`findmnt`、`lsblk`、`loginctl`、`blockdev` 通常随 systemd / util-linux 自带。

### 3. 配置文件初始化

- `config/default.json`：默认配置，随包分发，**不要直接修改**。
- `config/config.json`：用户覆盖配置，仅保存与默认不同的项。仓库中初始为 `{}`，
  首次部署无需手动创建；通过 Web UI「配置」选项卡保存时自动生成。

### 4. systemd 服务部署

```bash
# 一键安装（拷贝文件、渲染 systemd 单元、启用并启动服务）
sudo ./auto-suspend-install.sh install

# 查看安装后的服务状态
systemctl status auto-suspend.timer auto-suspend-web.service
```

安装脚本会部署：

| 单元 | 作用 |
|---|---|
| `auto-suspend.timer` | 周期触发（默认开机 10min 后、之后每 5min） |
| `auto-suspend.service` | 执行主脚本（oneshot） |
| `auto-suspend-web.service` | Web UI（Flask）常驻服务 |

> - 安装默认 Web 端口 `5005`（`auto-suspend-install.sh` 中 `WEB_PORT` 可改）。
> - 升级安装会**保留**已有 `config/config.json`。
> - 部署后主脚本与 Web UI **共用同一份配置**：`/usr/local/share/auto-suspend/web/config/`
>   （`auto-suspend.service` 通过 `AUTO_SUSPEND_CONFIG_DIR` 指向该目录）。因此在 Web 上
>   修改的 `config.json` 会被主脚本直接读取生效，无需手动同步。

---

## 配置说明

配置优先级：`default.json` → `config.json`（覆盖）→ 脚本内置 fallback。示例
（`config/default.json` 节选）：

```jsonc
{
  "general": {
    "suspend_enabled": { "value": true },          // 总开关
    "allow_hdd_standby": { "value": true }         // 休眠前停转机械硬盘
  },
  "suspend_window": {
    "hour_start": { "value": 0 },                  // 允许休眠窗口开始小时
    "hour_end":   { "value": 24 }                  // 结束小时（0/24=全天）
  },
  "idle_detection": {
    "idle_minutes_required": { "value": 60 },      // 连续空闲分钟数
    "resume_cooldown_minutes": { "value": 300 }    // 唤醒冷却分钟数
  },
  "learning_parameters": {
    "learn_window": { "value": 60 },               // 学习窗口（采样点数）
    "safety_factor": { "value": 120 }              // 安全因子（%）= 阈值上浮 20%
  },
  "network_thresholds": {
    "min_net": { "value": 409600 },                // 网络阈值下界（字节/5min）
    "max_net": { "value": 20971520 }               // 网络阈值上界
  }
}
```

关键配置项：

| 分组 | 参数 | 默认 | 说明 |
|---|---|---|---|
| general | `suspend_enabled` | true | 总开关，false 时脚本直接退出 |
| general | `allow_hdd_standby` | true | 休眠前是否停转 HDD |
| general | `disable_bluetooth` | true | 休眠前是否停用蓝牙模块 |
| general | `disable_usb_wakeup` | true | 休眠前是否禁用 USB 唤醒 |
| suspend_window | `hour_start` / `hour_end` | 0 / 24 | 允许休眠窗口（0-24；0/24=全天；`start>end` 为跨天窗口） |
| check_interval | `minutes` / `seconds` | 5 / 300 | 监测周期（**需与 systemd timer 的 `OnUnitActiveSec` 同步**） |
| idle_detection | `idle_minutes_required` | 60 | 连续空闲所需分钟数 |
| idle_detection | `resume_cooldown_minutes` | 300 | 唤醒后保护冷却分钟数 |
| learning_parameters | `learn_window` | 60 | 阈值学习窗口（采样点数） |
| learning_parameters | `safety_factor` | 120 | 安全因子（%），120=学得阈值上浮 20% |
| network_thresholds | `min_net` / `max_net` / `net_activity_floor` | 409600 / 20971520 / 5242880 | 网络阈值下界/上界/硬性下限（字节/5min） |
| hdd_thresholds | `min_hdd` / `max_hdd` | 128 / 4096 | 每盘 HDD 扇区阈值 |
| ssd_thresholds | `min_ssd` / `max_ssd` | 2048 / 20480 | SSD 合计扇区阈值 |
| cpu_thresholds | `cpu_load_max` | 0.8 | CPU 5 分钟平均负载上限 |
| web_access | `web_access_log` | /usr/trim/nginx/logs/access.log | Nginx 访问日志路径 |
| web_access | `web_active_window` | 1800 | Web 活跃检测时间窗口（秒） |

> 建议通过 Web UI「配置」选项卡修改；配置每次运行自动热加载，无需重启服务。
> 完整维护说明见 [docs/AUTO_SUSPEND_MAINTENANCE.md](docs/AUTO_SUSPEND_MAINTENANCE.md)。

---

## 使用指南

### 启动 / 停止 / 重启

```bash
# 启动（含开机自启）
sudo systemctl enable --now auto-suspend.timer auto-suspend-web.service

# 停止 / 禁用
sudo systemctl stop auto-suspend.timer auto-suspend-web.service
sudo systemctl disable auto-suspend.timer auto-suspend-web.service

# 重启 Web 服务（主脚本为 oneshot，无需常驻）
sudo systemctl restart auto-suspend-web.service
```

### 查看状态

```bash
systemctl status auto-suspend.timer auto-suspend.service auto-suspend-web.service
cat /run/auto-suspend/state        # 当前状态机（ACTIVE/IDLE/SUSPENDING/COOLDOWN）
```

### 查看日志

```bash
journalctl -t auto-suspend -n 50     # 最近 50 条
journalctl -t auto-suspend -f        # 实时跟踪
```

### 手动触发挂起

```bash
sudo systemctl suspend               # 立即挂起
```

或通过 Web 控制台「总览」页关闭/开启自动休眠开关（`POST /api/toggle-suspend`）。

---

## 常见问题（FAQ）

**Q1：系统从不休眠，怎么办？**

先看忙碌原因与窗口判断：

```bash
journalctl -t auto-suspend -n 50
```

若日志持续出现 `BUSY` 类型迁移，说明有指标判定为忙碌（SSH/Web/CPU/网络/磁盘 IO）；
若提示「非休眠窗口期」，则当前不在允许休眠时段。同时确认 `suspend_enabled=true`、
不存在 `/run/auto-suspend/disable` 禁用标记。

**Q2：休眠后立刻被唤醒？**

多为异常唤醒源（USB 设备、WOL 误触发等）。确认 `disable_usb_wakeup=true`、
`try_enable_wol` 是否把不需要的网卡也开启了；并检查 `systemctl suspend` 的返回与
`journalctl` 中唤醒钩子日志。

**Q3：脚本被自动禁用（出现 `disable` 文件）？**

连续 2 次「休眠→唤醒 < 60s」会触发保护性禁用。排查异常唤醒源后，可在 Web 总览页点
「手动移除禁用限制」，或执行 `rm /run/auto-suspend/disable` 恢复。

**Q4：唤醒后机械硬盘未挂载？**

确认哨兵 `/run/auto-suspend/disk/SAFE_TO_RESUME` 存在、`/etc/fstab` 机械盘源列为
`UUID=`/`LABEL=` 形式，并查看 `journalctl -t auto-suspend` 中 `hdd-resume-post` 相关
日志。可手动 `lsblk` 核对物理盘名是否变化。

**Q5：阈值偏低/偏高，休眠判断不准？**

检查 `safety_factor`（默认 120）；如需重新学习，可清空对应采样文件后重启监测：

```bash
rm /run/auto-suspend/*.samples
sudo systemctl restart auto-suspend.timer
```

**Q6：Web 日志显示「日志暂不可用」？**

Web 服务需有权调用 `journalctl`（生产环境通常以 root 运行）。执行
`systemctl status auto-suspend-web` 确认服务正常，并检查 `User=` 配置。

---

## 贡献指南

- **报告问题**：请在 GitHub Issues 中描述环境（发行版/内核版本）、复现步骤、
  `journalctl -t auto-suspend` 输出与配置（注意脱敏）。
- **提交 PR**：
  1. Fork 本仓库并基于 `main` 分支新建功能分支（如 `feat/xxx`、`fix/xxx`）；
  2. 代码风格与现有代码保持一致：Bash 使用 `set -u` + `set -o pipefail`、局部变量
     `local`、关键逻辑加中文注释；Python 遵循 PEP 8，函数/变量为蛇形命名；
  3. 涉及脚本改动请在真实 Linux 环境自测后再提交；
  4. 提交信息使用约定式提交（如 `fix(hdd): 修正卸载失败时的日志引用`）。
- **行为准则**：友好、尊重，聚焦技术。

---

## 许可证

本项目默认采用 [MIT License](LICENSE)。仓库中暂未附带 `LICENSE` 文件，正式开源发布
前请补充。涉及系统休眠与磁盘操作，请在测试环境充分验证后再部署。
